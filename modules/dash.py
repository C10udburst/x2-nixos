#!/usr/bin/env python3
"""
Dashboard status and management API for GMKtec EVO-X2.
GMKtec EVO-X2 (AMD Ryzen AI Max+ 395 128GB Unified Memory).

Provides:
- /api/status: System RAM, GPU VRAM & GTT allocations, CPU load, and model list
- /api/switch: Manually switch active model
- /api/stop: Stop active model to free GPU memory
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

CONFIG_PATH = os.environ.get("GUFO_CONFIG_PATH", "/etc/gufo/models.json")
CONFIG = {"backend_port": 8081, "models": {}}

if os.path.exists(CONFIG_PATH):
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            CONFIG.update(json.load(f))
    except Exception as e:
        sys.stderr.write(f"Failed to load config: {e}\n")

BACKEND_HOST = "127.0.0.1"
BACKEND_PORT = CONFIG.get("backend_port", 8081)
MODELS = CONFIG.get("models", {})
SYSTEMCTL = os.environ.get("SYSTEMCTL", "systemctl")
STATE_FILE = "/run/gufo/active_model"
LOCK_FILE = "/run/gufo/switch.lock"


def send_headers(status="200 OK", content_type="application/json; charset=utf-8"):
    headers = [
        f"Status: {status}",
        f"Content-Type: {content_type}",
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: GET, POST, OPTIONS",
        "Access-Control-Allow-Headers: Content-Type, Authorization",
        "X-Accel-Buffering: no",
        "Cache-Control: no-cache, no-store, must-revalidate\r\n\r\n",
    ]
    sys.stdout.buffer.write("\r\n".join(headers).encode("utf-8"))
    sys.stdout.buffer.flush()


def run_systemctl(action, unit):
    cmd = [SYSTEMCTL, action, unit]
    if os.geteuid() != 0:
        cmd = ["sudo", "-n"] + cmd
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
        return proc.returncode == 0, proc.stdout.strip(), proc.stderr.strip()
    except Exception as e:
        return False, "", str(e)


def get_active_model():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                name = f.read().strip()
                if name:
                    return name
        except Exception:
            pass

    for name, mcfg in MODELS.items():
        unit = mcfg.get("systemd_unit", f"gufo-{name}.service")
        ok, out, _ = run_systemctl("is-active", unit)
        if ok and out == "active":
            return name
    return None


def get_system_stats():
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

    gpu_busy = 0
    vram_used_b = 0
    vram_total_b = 0
    gtt_used_b = 0
    gtt_total_b = 0

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
        load_avg = [round(x, 2) for x in os.getloadavg()]
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
            "device": "AMD Radeon Graphics (Ryzen AI Max+ 395)",
            "busy_percent": gpu_busy,
            "vram_used_mb": round(vram_used_b / (1024 * 1024), 1),
            "vram_total_mb": round(vram_total_b / (1024 * 1024), 1),
            "gtt_used_mb": round(gtt_used_b / (1024 * 1024), 1),
            "gtt_total_mb": round(gtt_total_b / (1024 * 1024), 1),
        },
        "load_avg": load_avg,
    }


def handle_status():
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
            "active": (name == active),
        })

    payload = {"status": "ok", "active_model": active, "models": model_list, **stats}
    send_headers()
    sys.stdout.buffer.write(json.dumps(payload, indent=2).encode("utf-8"))
    sys.stdout.buffer.flush()


def handle_switch(body):
    target = None
    if body:
        try:
            data = json.loads(body.decode("utf-8"))
            target = data.get("model")
        except Exception:
            qs = parse_qs(body.decode("utf-8", errors="ignore"))
            if "model" in qs:
                target = qs["model"][0]

    if not target or target not in MODELS:
        send_headers(status="400 Bad Request")
        sys.stdout.buffer.write(json.dumps({"error": f"Invalid model '{target}'"}).encode("utf-8"))
        sys.stdout.buffer.flush()
        return

    os.makedirs("/run/gufo", exist_ok=True)
    with open(LOCK_FILE, "w") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            unit = MODELS[target].get("systemd_unit", f"gufo-{target}.service")
            ok, out, err = run_systemctl("start", unit)
            if not ok:
                send_headers(status="500 Internal Server Error")
                sys.stdout.buffer.write(json.dumps({"error": err or out}).encode("utf-8"))
                sys.stdout.buffer.flush()
                return

            deadline = time.time() + 90
            ready = False
            while time.time() < deadline:
                try:
                    conn = http.client.HTTPConnection(BACKEND_HOST, BACKEND_PORT, timeout=1)
                    conn.request("GET", "/health")
                    res = conn.getresponse()
                    if res.status in (200, 204):
                        ready = True
                        conn.close()
                        break
                    conn.close()
                except Exception:
                    pass
                time.sleep(0.2)

            if ready:
                with open(STATE_FILE, "w", encoding="utf-8") as f:
                    f.write(target)
                send_headers()
                sys.stdout.buffer.write(json.dumps({"status": "switched", "active_model": target}).encode("utf-8"))
            else:
                send_headers(status="504 Gateway Timeout")
                sys.stdout.buffer.write(json.dumps({"error": "Model startup timed out"}).encode("utf-8"))
            sys.stdout.buffer.flush()
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def handle_stop():
    active = get_active_model()
    if active and active in MODELS:
        unit = MODELS[active].get("systemd_unit", f"gufo-{active}.service")
        run_systemctl("stop", unit)
    if os.path.exists(STATE_FILE):
        try:
            os.remove(STATE_FILE)
        except Exception:
            pass
    send_headers()
    sys.stdout.buffer.write(json.dumps({"status": "stopped"}).encode("utf-8"))
    sys.stdout.buffer.flush()


def main():
    method = os.environ.get("REQUEST_METHOD", "GET")
    if method == "OPTIONS":
        send_headers(status="204 No Content")
        return

    raw_uri = os.environ.get("REQUEST_URI", "/")
    path = os.environ.get("PATH_INFO") or raw_uri.split("?")[0]
    clean_path = path.rstrip("/") or "/"

    content_length = int(os.environ.get("CONTENT_LENGTH", 0) or 0)
    body = sys.stdin.buffer.read(content_length) if content_length > 0 else b""

    if clean_path in ("/api/status", "/status"):
        handle_status()
    elif clean_path in ("/api/switch", "/switch") and method == "POST":
        handle_switch(body)
    elif clean_path in ("/api/stop", "/stop") and method == "POST":
        handle_stop()
    else:
        send_headers(status="404 Not Found")
        sys.stdout.buffer.write(json.dumps({"error": f"API endpoint '{clean_path}' not found"}).encode("utf-8"))
        sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
