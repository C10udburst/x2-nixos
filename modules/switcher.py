#!/usr/bin/env python3
"""
Ultra-minimal FastCGI Gateway and Dynamic Model Switcher for Gufo LLM Inference.
GMKtec EVO-X2 (AMD Ryzen AI Max+ 395 128GB Unified Memory).

Features:
- Dispatches /v1/* requests to the active Gufo backend.
- Automatically stops previous model and starts the requested model if "model" changed.
- Streams SSE tokens directly without server-side buffering (X-Accel-Buffering: no).
- Provides /api/status, /api/switch, /api/stop for the client-side rendered dashboard.
- Serves the static HTML dashboard at / and /index.html.
- Reads hardware metrics from Linux kernel sysfs (/sys/class/drm and /proc/meminfo).
- Designed for zero memory overhead when idle (< 1MB) under fcgiwrap.
"""

import fcntl
import glob
import http.client
import json
import os
import subprocess
import sys
import time
from urllib.parse import parse_qs

# Load configuration
CONFIG_PATH = os.environ.get("GUFO_CONFIG_PATH", "/etc/gufo/models.json")
BACKEND_HOST = "127.0.0.1"
DEFAULT_BACKEND_PORT = 8081

CONFIG = {
    "backend_port": DEFAULT_BACKEND_PORT,
    "default_model": None,
    "models": {}
}

if os.path.exists(CONFIG_PATH):
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            CONFIG.update(json.load(f))
    except Exception as e:
        sys.stderr.write(f"Failed to load config from {CONFIG_PATH}: {e}\n")
elif "GUFO_CONFIG" in os.environ:
    try:
        CONFIG.update(json.loads(os.environ["GUFO_CONFIG"]))
    except Exception as e:
        sys.stderr.write(f"Failed to load config from GUFO_CONFIG env: {e}\n")

BACKEND_PORT = CONFIG.get("backend_port", DEFAULT_BACKEND_PORT)
MODELS = CONFIG.get("models", {})
DEFAULT_MODEL = CONFIG.get("default_model") or (list(MODELS.keys())[0] if MODELS else None)

SYSTEMCTL = os.environ.get("SYSTEMCTL", "/run/current-system/sw/bin/systemctl")
if not os.path.exists(SYSTEMCTL):
    SYSTEMCTL = "systemctl"

RUN_DIR = "/run/gufo"
ACTIVE_MODEL_FILE = os.path.join(RUN_DIR, "active_model")
LOCK_FILE = os.path.join(RUN_DIR, "switch.lock")


def send_headers(status="200 OK", content_type="application/json; charset=utf-8", extra_headers=None):
    """Write FastCGI/CGI response headers to stdout."""
    headers = [
        f"Status: {status}",
        f"Content-Type: {content_type}",
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: GET, POST, OPTIONS",
        "Access-Control-Allow-Headers: Content-Type, Authorization",
        "X-Accel-Buffering: no",
        "Cache-Control: no-cache, no-store, must-revalidate",
    ]
    if extra_headers:
        for k, v in extra_headers.items():
            headers.append(f"{k}: {v}")
    headers.append("\r\n")
    sys.stdout.buffer.write("\r\n".join(headers).encode("utf-8"))
    sys.stdout.buffer.flush()


def run_systemctl(action, unit):
    """Execute a systemctl command with sudo if needed."""
    cmd = [SYSTEMCTL, action, unit]
    if os.geteuid() != 0:
        cmd = ["sudo", "-n"] + cmd
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
        return proc.returncode == 0, proc.stdout.strip(), proc.stderr.strip()
    except Exception as e:
        return False, "", str(e)


def get_active_model():
    """Identify which model is currently running."""
    # 1. Fast path: check state file
    if os.path.exists(ACTIVE_MODEL_FILE):
        try:
            with open(ACTIVE_MODEL_FILE, "r", encoding="utf-8") as f:
                name = f.read().strip()
                if name in MODELS:
                    # Verify unit is genuinely active
                    unit = MODELS[name].get("systemd_unit", f"gufo-{name}.service")
                    ok, out, _ = run_systemctl("is-active", unit)
                    if ok and out == "active":
                        return name
        except Exception:
            pass

    # 2. Check all configured models in systemd
    for name, mcfg in MODELS.items():
        unit = mcfg.get("systemd_unit", f"gufo-{name}.service")
        ok, out, _ = run_systemctl("is-active", unit)
        if ok and out == "active":
            try:
                os.makedirs(RUN_DIR, exist_ok=True)
                with open(ACTIVE_MODEL_FILE, "w", encoding="utf-8") as f:
                    f.write(name)
            except Exception:
                pass
            return name

    return None


def wait_for_backend(timeout_sec=60):
    """Poll backend until HTTP endpoint returns 200 OK."""
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        try:
            conn = http.client.HTTPConnection(BACKEND_HOST, BACKEND_PORT, timeout=1.5)
            # Gufo responds on /health or /v1/models
            conn.request("GET", "/health")
            resp = conn.getresponse()
            if resp.status in (200, 204):
                conn.close()
                return True
            conn.close()
        except Exception:
            try:
                conn = http.client.HTTPConnection(BACKEND_HOST, BACKEND_PORT, timeout=1.5)
                conn.request("GET", "/v1/models")
                resp = conn.getresponse()
                if resp.status == 200:
                    conn.close()
                    return True
                conn.close()
            except Exception:
                pass
        time.sleep(0.3)
    return False


def switch_to_model(target_name):
    """Stop running model and start target model."""
    if target_name not in MODELS:
        return False, f"Unknown model '{target_name}'"

    os.makedirs(RUN_DIR, exist_ok=True)
    with open(LOCK_FILE, "w") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            current = get_active_model()
            if current == target_name:
                return True, "Already active"

            target_unit = MODELS[target_name].get("systemd_unit", f"gufo-{target_name}.service")

            # Starting the target unit will automatically stop the current one
            # because of systemd's Conflicts directive.
            ok, out, err = run_systemctl("start", target_unit)
            if not ok:
                return False, f"Failed to start {target_unit}: {err or out}"

            # Wait for backend to be ready
            ready = wait_for_backend(timeout_sec=90)
            if not ready:
                return False, f"Model service {target_unit} started, but backend did not respond in time."

            try:
                with open(ACTIVE_MODEL_FILE, "w", encoding="utf-8") as f:
                    f.write(target_name)
            except Exception:
                pass

            return True, "Switched successfully"
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def stop_all_models():
    """Stop currently active model service."""
    os.makedirs(RUN_DIR, exist_ok=True)
    with open(LOCK_FILE, "w") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            current = get_active_model()
            if not current:
                return True, "No model currently active"
            unit = MODELS[current].get("systemd_unit", f"gufo-{current}.service")
            ok, out, err = run_systemctl("stop", unit)
            try:
                if os.path.exists(ACTIVE_MODEL_FILE):
                    os.remove(ACTIVE_MODEL_FILE)
            except Exception:
                pass
            return ok, err or out
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def get_system_stats():
    """Read RAM, CPU and AMDGPU VRAM/GTT stats from kernel sysfs."""
    # 1. RAM from /proc/meminfo
    mem_total_kb = 0
    mem_avail_kb = 0
    mem_free_kb = 0
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    mem_total_kb = int(line.split()[1])
                elif line.startswith("MemAvailable:"):
                    mem_avail_kb = int(line.split()[1])
                elif line.startswith("MemFree:"):
                    mem_free_kb = int(line.split()[1])
    except Exception:
        pass

    mem_used_kb = max(0, mem_total_kb - mem_avail_kb)
    mem_used_pct = round((mem_used_kb / mem_total_kb * 100), 1) if mem_total_kb else 0

    # 2. GPU metrics from /sys/class/drm
    gpu_busy = 0
    vram_used_b = 0
    vram_total_b = 0
    gtt_used_b = 0
    gtt_total_b = 0
    device_name = "AMD Radeon Graphics (Ryzen AI Max+ 395)"

    for card in sorted(glob.glob("/sys/class/drm/card[0-9]/device")):
        busy_path = os.path.join(card, "gpu_busy_percent")
        if os.path.exists(busy_path):
            try:
                with open(busy_path, "r") as f:
                    gpu_busy = int(f.read().strip())
            except Exception:
                pass

        vram_u_path = os.path.join(card, "mem_info_vram_used")
        vram_t_path = os.path.join(card, "mem_info_vram_total")
        if os.path.exists(vram_u_path):
            try:
                with open(vram_u_path, "r") as f:
                    vram_used_b = int(f.read().strip())
                with open(vram_t_path, "r") as f:
                    vram_total_b = int(f.read().strip())
            except Exception:
                pass

        gtt_u_path = os.path.join(card, "mem_info_gtt_used")
        gtt_t_path = os.path.join(card, "mem_info_gtt_total")
        if os.path.exists(gtt_u_path):
            try:
                with open(gtt_u_path, "r") as f:
                    gtt_used_b = int(f.read().strip())
                with open(gtt_t_path, "r") as f:
                    gtt_total_b = int(f.read().strip())
            except Exception:
                pass
            break

    try:
        load_avg = list(os.getloadavg())
    except Exception:
        load_avg = [0.0, 0.0, 0.0]

    return {
        "memory": {
            "total_mb": round(mem_total_kb / 1024, 1),
            "available_mb": round(mem_avail_kb / 1024, 1),
            "used_mb": round(mem_used_kb / 1024, 1),
            "percent_used": mem_used_pct,
        },
        "gpu": {
            "device": device_name,
            "busy_percent": gpu_busy,
            "vram_used_mb": round(vram_used_b / (1024 * 1024), 1),
            "vram_total_mb": round(vram_total_b / (1024 * 1024), 1),
            "gtt_used_mb": round(gtt_used_b / (1024 * 1024), 1),
            "gtt_total_mb": round(gtt_total_b / (1024 * 1024), 1),
        },
        "load_avg": [round(x, 2) for x in load_avg],
    }


def resolve_model_name(req_name):
    """Match request name against model names and aliases."""
    if not req_name:
        return None
    req_clean = req_name.strip()
    if req_clean in MODELS:
        return req_clean
    for name, mcfg in MODELS.items():
        if mcfg.get("alias") == req_clean:
            return name
    return None


def handle_dashboard():
    """Serve client-side dashboard HTML."""
    html_path = os.environ.get("GUFO_DASHBOARD_HTML", "/etc/gufo/dashboard.html")
    if not os.path.exists(html_path):
        # Fallback relative to script
        html_path = os.path.join(os.path.dirname(__file__), "dashboard.html")

    if os.path.exists(html_path):
        with open(html_path, "rb") as f:
            content = f.read()
        send_headers(status="200 OK", content_type="text/html; charset=utf-8")
        sys.stdout.buffer.write(content)
        sys.stdout.buffer.flush()
    else:
        send_headers(status="200 OK", content_type="text/plain; charset=utf-8")
        sys.stdout.buffer.write(b"GMKtec EVO-X2 Gufo Gateway is running. Dashboard HTML not found.")
        sys.stdout.buffer.flush()


def handle_status():
    """Serve status API JSON."""
    active = get_active_model()
    stats = get_system_stats()

    model_list = []
    for name, mcfg in MODELS.items():
        model_list.append({
            "name": name,
            "alias": mcfg.get("alias", name),
            "description": mcfg.get("description", ""),
            "context": mcfg.get("context", 65536),
            "speculative": mcfg.get("speculative"),
            "active": (name == active)
        })

    payload = {
        "status": "ok",
        "active_model": active,
        "models": model_list,
        **stats
    }
    send_headers()
    sys.stdout.buffer.write(json.dumps(payload, indent=2).encode("utf-8"))
    sys.stdout.buffer.flush()


def handle_switch(body):
    """Switch active model via API."""
    target = None
    if body:
        try:
            data = json.loads(body.decode("utf-8"))
            target = data.get("model")
        except Exception:
            qs = parse_qs(body.decode("utf-8", errors="ignore"))
            if "model" in qs:
                target = qs["model"][0]

    resolved = resolve_model_name(target)
    if not resolved:
        send_headers(status="400 Bad Request")
        sys.stdout.buffer.write(json.dumps({
            "error": f"Invalid model '{target}'. Available: {list(MODELS.keys())}"
        }).encode("utf-8"))
        sys.stdout.buffer.flush()
        return

    ok, msg = switch_to_model(resolved)
    if ok:
        send_headers(status="200 OK")
        sys.stdout.buffer.write(json.dumps({
            "status": "switched",
            "active_model": resolved,
            "message": msg
        }).encode("utf-8"))
    else:
        send_headers(status="500 Internal Server Error")
        sys.stdout.buffer.write(json.dumps({
            "status": "error",
            "message": msg
        }).encode("utf-8"))
    sys.stdout.buffer.flush()


def handle_stop():
    """Stop active model to free GPU memory."""
    ok, msg = stop_all_models()
    send_headers(status="200 OK" if ok else "500 Internal Server Error")
    sys.stdout.buffer.write(json.dumps({
        "status": "stopped" if ok else "error",
        "message": msg
    }).encode("utf-8"))
    sys.stdout.buffer.flush()


def handle_v1_models():
    """OpenAI compatible GET /v1/models response."""
    data = []
    now = int(time.time())
    for name, mcfg in MODELS.items():
        data.append({
            "id": mcfg.get("alias", name),
            "object": "model",
            "created": now,
            "owned_by": "gufo"
        })
    send_headers()
    sys.stdout.buffer.write(json.dumps({"object": "list", "data": data}).encode("utf-8"))
    sys.stdout.buffer.flush()


def handle_proxy(method, path, query_string, body):
    """Proxy OpenAI requests (/v1/chat/completions, etc.) and auto-switch if needed."""
    # 1. Inspect model from JSON body
    target_model = None
    if body and method == "POST":
        try:
            data = json.loads(body.decode("utf-8"))
            if "model" in data:
                target_model = resolve_model_name(data["model"])
        except Exception:
            pass

    # If no model specified in body, try to use active model or default model
    if not target_model:
        target_model = get_active_model() or DEFAULT_MODEL

    if not target_model:
        send_headers(status="503 Service Unavailable")
        sys.stdout.buffer.write(json.dumps({
            "error": {"message": "No model active and no default model configured.", "type": "server_error"}
        }).encode("utf-8"))
        sys.stdout.buffer.flush()
        return

    # Auto-switch if target model is not currently running
    active = get_active_model()
    if active != target_model:
        ok, msg = switch_to_model(target_model)
        if not ok:
            send_headers(status="500 Internal Server Error")
            sys.stdout.buffer.write(json.dumps({
                "error": {"message": f"Failed to activate model {target_model}: {msg}", "type": "server_error"}
            }).encode("utf-8"))
            sys.stdout.buffer.flush()
            return

    # Connect to backend
    full_path = path + (f"?{query_string}" if query_string else "")
    try:
        conn = http.client.HTTPConnection(BACKEND_HOST, BACKEND_PORT, timeout=600)
        headers = {}
        for k, v in os.environ.items():
            if k.startswith("HTTP_"):
                header_name = k[5:].replace("_", "-").title()
                if header_name.lower() not in ("host", "content-length"):
                    headers[header_name] = v
        if "CONTENT_TYPE" in os.environ and os.environ["CONTENT_TYPE"]:
            headers["Content-Type"] = os.environ["CONTENT_TYPE"]

        conn.request(method, full_path, body=body if body else None, headers=headers)
        resp = conn.getresponse()

        # Output FastCGI status and headers
        out_headers = {
            "Access-Control-Allow-Origin": "*",
            "X-Accel-Buffering": "no"
        }
        for h, v in resp.getheaders():
            if h.lower() not in ("transfer-encoding", "connection", "server", "date"):
                out_headers[h] = v

        send_headers(
            status=f"{resp.status} {resp.reason}",
            content_type=out_headers.pop("Content-Type", "application/json"),
            extra_headers=out_headers
        )

        # Stream response directly to client without buffering
        while True:
            chunk = resp.read(4096)
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()

        conn.close()
    except Exception as e:
        send_headers(status="502 Bad Gateway")
        sys.stdout.buffer.write(json.dumps({
            "error": {"message": f"Backend connection failed: {e}", "type": "bad_gateway"}
        }).encode("utf-8"))
        sys.stdout.buffer.flush()


def main():
    method = os.environ.get("REQUEST_METHOD", "GET")

    # Handle CORS preflight
    if method == "OPTIONS":
        send_headers(status="204 No Content")
        return

    raw_uri = os.environ.get("REQUEST_URI", "/")
    path = os.environ.get("PATH_INFO") or raw_uri.split("?")[0]
    query_string = os.environ.get("QUERY_STRING", "")

    # Read body if present
    content_length = int(os.environ.get("CONTENT_LENGTH", 0) or 0)
    body = sys.stdin.buffer.read(content_length) if content_length > 0 else b""

    # Route matching
    clean_path = path.rstrip("/") or "/"

    if clean_path in ("/", "/index.html", "/dashboard"):
        handle_dashboard()
    elif clean_path == "/api/status":
        handle_status()
    elif clean_path == "/api/switch" and method == "POST":
        handle_switch(body)
    elif clean_path == "/api/stop" and method == "POST":
        handle_stop()
    elif clean_path == "/v1/models" and method == "GET":
        handle_v1_models()
    elif clean_path.startswith("/v1/"):
        handle_proxy(method, clean_path, query_string, body)
    else:
        # Fallback 404
        send_headers(status="404 Not Found")
        sys.stdout.buffer.write(json.dumps({"error": f"Path '{clean_path}' not found"}).encode("utf-8"))
        sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
