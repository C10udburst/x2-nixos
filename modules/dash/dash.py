#!/usr/bin/env python3
"""
Dashboard status and management API for GMKtec EVO-X2.
GMKtec EVO-X2 (AMD Ryzen AI Max+ 395 128GB Unified Memory).

Provides:
- /api/status: System RAM, GPU VRAM & GTT allocations, CPU load, defined services & model registry
- /api/switch: Manually switch active LLM model
- /api/stop: Stop active model or workload to free GPU memory
"""

import fcntl
import glob
import http.client
import json
import os
import subprocess
import sys
import time
from urllib.parse import parse_qs, urlparse

CONFIG_PATH = os.environ.get("MODELS_CONFIG_PATH", os.environ.get("GUFO_CONFIG_PATH", "/etc/models.json"))
CONFIG = {"models": {}, "default_model": None, "services": [], "all_exclusive_units": []}

if os.path.exists(CONFIG_PATH):
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            CONFIG.update(json.load(f))
    except Exception as e:
        sys.stderr.write(f"Failed to load config: {e}\n")

MODELS = CONFIG.get("models", {})
SERVICES = CONFIG.get("services", [])
ALL_EXCLUSIVE_UNITS = CONFIG.get("all_exclusive_units", [])
SYSTEMCTL = os.environ.get("SYSTEMCTL", "systemctl")
LOCK_FILE = CONFIG.get("lock_file", "/run/model-lock/model.lock")
STATE_FILE = CONFIG.get("state_file", "/run/model-lock/active_model")


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
        sudo_bin = "/run/wrappers/bin/sudo" if os.path.exists("/run/wrappers/bin/sudo") else "sudo"
        cmd = [sudo_bin, "-n"] + cmd
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
        return proc.returncode == 0, proc.stdout.strip(), proc.stderr.strip()
    except Exception as e:
        return False, "", str(e)


def get_active_workload():
    # 1. Check state file first
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                name = f.read().strip()
                if name:
                    return name
        except Exception:
            pass

    # 2. Check standalone / on-demand registered services
    for svc in SERVICES:
        unit = svc.get("unit")
        if unit:
            ok, out, _ = run_systemctl("is-active", unit)
            if ok and out == "active":
                return svc.get("id")

    # 3. Check registered models
    for name, mcfg in MODELS.items():
        unit = mcfg.get("service_name", f"model-{name}.service")
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
    active = get_active_workload()
    stats = get_system_stats()

    # Query status of defined subsystems and services
    services_status = []
    for s in SERVICES:
        unit = s.get("unit")
        socket_unit = s.get("socket_unit")

        is_unit_active = False
        if unit:
            ok, out, _ = run_systemctl("is-active", unit)
            is_unit_active = (ok and out == "active")

        is_socket_active = False
        if socket_unit:
            ok, out, _ = run_systemctl("is-active", socket_unit)
            is_socket_active = (ok and out == "active")

        if is_unit_active:
            status = "active"
        elif is_socket_active:
            status = "standby"
        elif s.get("type") == "gateway":
            status = "active"
        else:
            status = "inactive"

        services_status.append({
            "id": s.get("id"),
            "name": s.get("name"),
            "port": s.get("port"),
            "backend_port": s.get("backend_port"),
            "type": s.get("type"),
            "status": status,
            "description": s.get("description", ""),
        })

    model_list = []
    for name, mcfg in MODELS.items():
        model_list.append({
            "name": name,
            "alias": mcfg.get("remapped_model", name),
            "description": mcfg.get("description", ""),
            "backend_type": mcfg.get("type", "unknown"),
            "active": (name == active),
        })

    payload = {
        "status": "ok",
        "active_model": active,
        "active_workload": active,
        "services": services_status,
        "models": model_list,
        **stats,
    }
    send_headers()
    sys.stdout.buffer.write(json.dumps(payload, indent=2).encode("utf-8"))
    sys.stdout.buffer.flush()


def check_url_health(url_str, timeout=1.0):
    parsed = urlparse(url_str)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 80
    paths = ["/health", "/v1/models", "/"]
    for p in paths:
        try:
            conn = http.client.HTTPConnection(host, port, timeout=timeout)
            conn.request("GET", p)
            res = conn.getresponse()
            if res.status < 500:
                conn.close()
                return True
            conn.close()
        except Exception:
            pass
    return False


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

    with open(LOCK_FILE, "w") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            mcfg = MODELS[target]
            target_unit = mcfg.get("service_name", f"model-{target}.service")
            target_url = mcfg.get("url", "http://127.0.0.1:8081")

            # Stop all other exclusive heavy workloads calculated at eval time
            for unit in ALL_EXCLUSIVE_UNITS:
                if unit != target_unit:
                    run_systemctl("stop", unit)

            ok, out, err = run_systemctl("start", target_unit)
            if not ok:
                send_headers(status="500 Internal Server Error")
                sys.stdout.buffer.write(json.dumps({"error": err or out}).encode("utf-8"))
                sys.stdout.buffer.flush()
                return

            deadline = time.time() + 90
            ready = False
            while time.time() < deadline:
                if check_url_health(target_url):
                    ready = True
                    break
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
    with open(LOCK_FILE, "w") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            # Stop all exclusive heavy workloads calculated at eval time
            for unit in ALL_EXCLUSIVE_UNITS:
                run_systemctl("stop", unit)

            if os.path.exists(STATE_FILE):
                try:
                    os.remove(STATE_FILE)
                except Exception:
                    pass
            send_headers()
            sys.stdout.buffer.write(json.dumps({"status": "stopped"}).encode("utf-8"))
            sys.stdout.buffer.flush()
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


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
