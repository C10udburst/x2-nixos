#!/usr/bin/env python3
"""
Dashboard status and management API for GMKtec EVO-X2.
GMKtec EVO-X2 (AMD Ryzen AI Max+ 395 128GB Unified Memory).

Dual-domain workload model: the GPU (RDNA 3.5) and NPU (XDNA 2) domains hold at most one
workload each and are switched, locked and unloaded independently.

Provides:
- /api/status: System RAM, GPU VRAM & GTT allocations, CPU load, defined services and the
  active workload of each domain. It deliberately does NOT serialize the model registry:
  the gateway serves that as static JSON on /v1/models (see modules/dash/default.nix) and
  the dashboard fetches it once on page load. "Is this model loaded?" is answered on the
  client by comparing the registry id against active_gpu_model / active_npu_model.
- /api/switch: Manually switch the active model of that model's own domain
- /api/stop: Stop workloads of one domain ({"device": "gpu"|"npu"}) or both (default "all")
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
CONFIG = {
    "models": {},
    "default_model": None,
    "services": [],
    "gpu_exclusive_units": [],
    "npu_exclusive_units": [],
    "all_exclusive_units": [],
    "lock_files": {},
    "state_files": {},
}

if os.path.exists(CONFIG_PATH):
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            CONFIG.update(json.load(f))
    except Exception as e:
        sys.stderr.write(f"Failed to load config: {e}\n")

MODELS = CONFIG.get("models", {})
SERVICES = CONFIG.get("services", [])
SYSTEMCTL = os.environ.get("SYSTEMCTL", "systemctl")

DEVICES = ("gpu", "npu")
DEFAULT_LOCK_FILES = {"gpu": "/run/model-lock/gpu.lock", "npu": "/run/model-lock/npu.lock"}
DEFAULT_STATE_FILES = {"gpu": "/run/model-lock/active_gpu", "npu": "/run/model-lock/active_npu"}
LOCK_FILES = {**DEFAULT_LOCK_FILES, **(CONFIG.get("lock_files") or {})}
STATE_FILES = {**DEFAULT_STATE_FILES, **(CONFIG.get("state_files") or {})}


def unit_list_for(device):
    """Exclusive units of one domain, or of both domains for device='all'."""
    if device == "all":
        return list(CONFIG.get("all_exclusive_units") or [])
    if device == "npu":
        return list(CONFIG.get("npu_exclusive_units") or [])
    return list(CONFIG.get("gpu_exclusive_units") or [])


def model_device(name):
    return (MODELS.get(name) or {}).get("device", "gpu")


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


def run_systemctl(*args):
    cmd = [SYSTEMCTL] + list(args)
    if os.geteuid() != 0:
        sudo_bin = "/run/wrappers/bin/sudo" if os.path.exists("/run/wrappers/bin/sudo") else "sudo"
        cmd = [sudo_bin, "-n"] + cmd
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
        return proc.returncode == 0, proc.stdout.strip(), proc.stderr.strip()
    except Exception as e:
        return False, "", str(e)


def unit_states(units):
    """ActiveState of many units in ONE systemctl round-trip -> {unit: state}.

    The status endpoint is polled every few seconds, and deciding "which workload is
    resident" means looking at every exclusive unit of both domains. Shelling out
    `systemctl is-active` per unit is the single most expensive thing this CGI does, so the
    whole set is queried in one call. An empty result means the batch query was unusable
    (old systemd, permission oddities) and callers fall back to per-unit checks.
    """
    units = [u for u in units if u]
    if not units:
        return {}

    _, out, _ = run_systemctl("show", "--no-pager", "-p", "Id", "-p", "ActiveState", *units)
    states = {}
    current = None
    for line in (out or "").splitlines():
        key, sep, value = line.partition("=")
        if not sep:
            continue
        if key == "Id":
            current = value or None
            if current:
                states.setdefault(current, "inactive")
        elif key == "ActiveState" and current:
            states[current] = value
    return states


def listed_service_units():
    """Every systemd unit the services list references (backends *and* listener sockets)."""
    units = []
    for svc in SERVICES:
        for key in ("unit", "socket_unit"):
            unit = svc.get(key)
            if unit and unit not in units:
                units.append(unit)
    return units


def is_unit_active(unit, states=None):
    """Batch lookup when a caller pre-fetched `states`, otherwise ask systemd directly."""
    if states is not None:
        return states.get(unit) == "active"
    ok, out, _ = run_systemctl("is-active", unit)
    return ok and out == "active"


def get_active_workload(device="gpu", states=None):
    """Active workload id of one hardware domain ("" when that domain is idle)."""
    state_file = STATE_FILES.get(device)

    # 1. Check the domain state file first
    if state_file and os.path.exists(state_file):
        try:
            with open(state_file, "r", encoding="utf-8") as f:
                name = f.read().strip()
                if name:
                    return name
        except Exception:
            pass

    # 2. Check standalone / on-demand heavy services of this domain (never the gateway)
    domain_units = set(unit_list_for(device))
    for svc in SERVICES:
        if svc.get("type") != "on-demand":
            continue
        unit = svc.get("unit")
        if not unit or unit not in domain_units:
            continue
        if is_unit_active(unit, states):
            return svc.get("id")

    # 3. Check registered models of this domain
    for name, mcfg in MODELS.items():
        if mcfg.get("device", "gpu") != device:
            continue
        unit = mcfg.get("service_name", f"model-{name}.service")
        if is_unit_active(unit, states):
            return name

    return None


def get_cpu_busy_percent(load_avg):
    stat_file = "/dev/shm/evo_cpu_stat"
    try:
        with open("/proc/stat", "r") as f:
            fields = [int(x) for x in f.readline().split()[1:]]
        idle = fields[3] + (fields[4] if len(fields) > 4 else 0)
        total = sum(fields)
    except Exception:
        total, idle = None, None

    if total is not None:
        prev_total, prev_idle = None, None
        if os.path.exists(stat_file):
            try:
                with open(stat_file, "r") as f:
                    parts = f.read().split()
                    if len(parts) >= 2:
                        prev_total, prev_idle = int(parts[0]), int(parts[1])
            except Exception:
                pass
        try:
            with open(stat_file, "w") as f:
                f.write(f"{total} {idle}\n")
        except Exception:
            pass

        if prev_total is not None and prev_idle is not None:
            diff_total = total - prev_total
            diff_idle = idle - prev_idle
            if diff_total > 0:
                pct = 100.0 * (diff_total - diff_idle) / diff_total
                return max(0.0, min(100.0, round(pct, 1)))

    try:
        cpu_count = os.cpu_count() or 1
        return max(0.0, min(100.0, round((load_avg[0] / cpu_count) * 100, 1)))
    except Exception:
        return 0.0


def get_temperatures():
    cpu_temp = None
    gpu_temp = None

    for hwmon in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        name_path = os.path.join(hwmon, "name")
        if not os.path.exists(name_path):
            continue
        try:
            with open(name_path, "r") as f:
                name = f.read().strip().lower()
        except Exception:
            continue

        if name in ("k10temp", "zenpower", "coretemp"):
            for tf in ("temp1_input", "temp2_input"):
                tp = os.path.join(hwmon, tf)
                if os.path.exists(tp):
                    try:
                        with open(tp, "r") as f:
                            val = int(f.read().strip())
                            if val > 0:
                                cpu_temp = round(val / 1000.0, 1)
                                break
                    except Exception:
                        pass

        if name in ("amdgpu", "radeon"):
            for tf in ("temp1_input", "temp2_input"):
                tp = os.path.join(hwmon, tf)
                if os.path.exists(tp):
                    try:
                        with open(tp, "r") as f:
                            val = int(f.read().strip())
                            if val > 0:
                                gpu_temp = round(val / 1000.0, 1)
                                break
                    except Exception:
                        pass

    # Fallback for CPU temperature from thermal zones if not found
    if cpu_temp is None:
        for tz in sorted(glob.glob("/sys/class/thermal/thermal_zone*")):
            type_path = os.path.join(tz, "type")
            temp_path = os.path.join(tz, "temp")
            if os.path.exists(type_path) and os.path.exists(temp_path):
                try:
                    with open(type_path, "r") as f:
                        tz_type = f.read().strip().lower()
                    if any(k in tz_type for k in ("x86_pkg_temp", "k10temp", "cpu", "soc", "acpitz")):
                        with open(temp_path, "r") as f:
                            val = int(f.read().strip())
                            if val > 0:
                                cpu_temp = round(val / 1000.0, 1)
                                break
                except Exception:
                    pass

    # Fallback for GPU temperature from drm card hwmon
    if gpu_temp is None:
        for tp in sorted(glob.glob("/sys/class/drm/card[0-9]/device/hwmon/hwmon*/temp*_input")):
            try:
                with open(tp, "r") as f:
                    val = int(f.read().strip())
                    if val > 0:
                        gpu_temp = round(val / 1000.0, 1)
                        break
            except Exception:
                pass

    return cpu_temp, gpu_temp


def get_npu_busy_percent():
    stat_file = "/dev/shm/evo_npu_stat"
    for accel in sorted(glob.glob("/sys/class/accel/accel[0-9]/device")):
        for cand in ("npu_busy_percent", "busy_percent", "utilization", "load"):
            p = os.path.join(accel, cand)
            if os.path.exists(p):
                try:
                    with open(p, "r") as f:
                        return float(f.read().strip())
                except Exception:
                    pass
        act_p = os.path.join(accel, "power/runtime_active_time")
        sus_p = os.path.join(accel, "power/runtime_suspended_time")
        if os.path.exists(act_p) and os.path.exists(sus_p):
            try:
                with open(act_p, "r") as f:
                    act = int(f.read().strip())
                with open(sus_p, "r") as f:
                    sus = int(f.read().strip())
                prev_act, prev_sus = None, None
                if os.path.exists(stat_file):
                    try:
                        with open(stat_file, "r") as f:
                            parts = f.read().split()
                            if len(parts) >= 2:
                                prev_act, prev_sus = int(parts[0]), int(parts[1])
                    except Exception:
                        pass
                try:
                    with open(stat_file, "w") as f:
                        f.write(f"{act} {sus}\n")
                except Exception:
                    pass
                if prev_act is not None and prev_sus is not None:
                    d_act = act - prev_act
                    d_sus = sus - prev_sus
                    d_tot = d_act + d_sus
                    if d_tot > 0:
                        pct = round(100.0 * d_act / d_tot, 1)
                        return max(0.0, min(100.0, pct))
                status_p = os.path.join(accel, "power/runtime_status")
                if os.path.exists(status_p):
                    try:
                        with open(status_p, "r") as f:
                            if f.read().strip() == "active":
                                return 100.0
                    except Exception:
                        pass
            except Exception:
                pass
    return 0.0


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

    cpu_temp, gpu_temp = get_temperatures()
    cpu_busy = get_cpu_busy_percent(load_avg)
    npu_busy = get_npu_busy_percent()

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
            "temp_c": gpu_temp,
            "vram_used_mb": round(vram_used_b / (1024 * 1024), 1),
            "vram_total_mb": round(vram_total_b / (1024 * 1024), 1),
            "gtt_used_mb": round(gtt_used_b / (1024 * 1024), 1),
            "gtt_total_mb": round(gtt_total_b / (1024 * 1024), 1),
        },
        "npu": {
            "device": "AMD XDNA NPU (Ryzen AI Max+ 395)",
            "busy_percent": npu_busy,
        },
        "cpu": {
            "busy_percent": cpu_busy,
            "temp_c": cpu_temp,
            "load_avg": load_avg,
        },
        "temperatures": {
            "cpu_c": cpu_temp,
            "gpu_c": gpu_temp,
        },
        "load_avg": load_avg,
    }


def status_probe_units():
    """Every unit the status handler inspects, deduplicated.

    The exclusive-unit lists come from the generated registry file; the model units are added
    from the registry as well, so a stale or older config can never leave a loaded model out
    of the batch (anything missing from the map would read as "not active").
    """
    candidates = (
        unit_list_for("all")
        + [mcfg.get("service_name") for mcfg in MODELS.values()]
        + listed_service_units()
    )
    units = []
    for unit in candidates:
        if unit and unit not in units:
            units.append(unit)
    return units


def handle_status():
    # One `systemctl show` for every unit this handler touches (both exclusive workload
    # sets plus the gateway / on-demand service and socket units), then pure dict lookups.
    states = unit_states(status_probe_units()) or None

    active_gpu = get_active_workload("gpu", states)
    active_npu = get_active_workload("npu", states)
    # Backward-compatible alias: the GPU domain is the historical "the" workload.
    active = active_gpu or active_npu
    stats = get_system_stats()

    # Query status of defined subsystems and services
    services_status = []
    for s in SERVICES:
        unit = s.get("unit")
        socket_unit = s.get("socket_unit")

        unit_active = is_unit_active(unit, states) if unit else False
        socket_active = is_unit_active(socket_unit, states) if socket_unit else False

        if unit_active:
            status = "active"
        elif socket_active:
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

    # No `models` key: the registry is static config and belongs to /v1/models, which the
    # dashboard loads once. Only the two live workload ids are reported here.
    payload = {
        "status": "ok",
        "active_model": active,
        "active_workload": active,
        "active_gpu_model": active_gpu,
        "active_npu_model": active_npu,
        "services": services_status,
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


def acquire_lock(path):
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o666)
    except PermissionError:
        fd = os.open(path, os.O_RDONLY)
    try:
        os.chmod(path, 0o666)
    except Exception:
        pass
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def release_lock(fd):
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except Exception:
        pass
    try:
        os.close(fd)
    except Exception:
        pass


def set_state_file(path, content):
    """Safely write state file, handling existing file ownership and cross-user permissions."""
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        try:
            os.chmod(path, 0o666)
        except Exception:
            pass
        return
    except PermissionError:
        pass
    except Exception as e:
        sys.stderr.write(f"Direct write to {path} failed: {e}\n")

    # In 0777 directory, if writing to an existing 0644 foreign-owned file failed,
    # unlinking and recreating succeeds cleanly
    try:
        if os.path.exists(path):
            os.remove(path)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        try:
            os.chmod(path, 0o666)
        except Exception:
            pass
    except Exception as e:
        sys.stderr.write(f"Recreation of {path} failed: {e}\n")


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

    # The target model decides the domain: switching an NPU model never touches the GPU
    # workload, and switching a GPU model leaves a warm NPU model alone.
    device = model_device(target)
    mcfg = MODELS[target]
    model_dir = mcfg.get("model_dir") or ""
    if model_dir and not os.path.isdir(model_dir):
        send_headers(status="503 Service Unavailable")
        sys.stdout.buffer.write(
            json.dumps({"error": f"Model '{target}' is not downloaded: {model_dir} is missing"}).encode("utf-8")
        )
        sys.stdout.buffer.flush()
        return

    lock_fd = acquire_lock(LOCK_FILES[device])
    try:
        target_unit = mcfg.get("service_name", f"model-{target}.service")
        target_url = mcfg.get("url", "http://127.0.0.1:8081")

        # Stop the other exclusive workloads OF THIS DOMAIN calculated at eval time
        for unit in unit_list_for(device):
            if unit != target_unit:
                run_systemctl("stop", unit)

        ok, out, err = run_systemctl("start", target_unit)
        if not ok:
            send_headers(status="500 Internal Server Error")
            sys.stdout.buffer.write(json.dumps({"error": err or out}).encode("utf-8"))
            sys.stdout.buffer.flush()
            return

        deadline = time.time() + 180
        ready = False
        while time.time() < deadline:
            if check_url_health(target_url):
                ready = True
                break
            time.sleep(0.2)

        if ready:
            set_state_file(STATE_FILES[device], target)
            send_headers()
            sys.stdout.buffer.write(
                json.dumps({"status": "switched", "active_model": target, "device": device}).encode("utf-8")
            )
        else:
            send_headers(status="504 Gateway Timeout")
            sys.stdout.buffer.write(json.dumps({"error": "Model startup timed out"}).encode("utf-8"))
        sys.stdout.buffer.flush()
    finally:
        release_lock(lock_fd)


def parse_device(body):
    """Device selector for /api/stop: 'gpu', 'npu' or 'all' (default)."""
    device = "all"
    if body:
        text = body.decode("utf-8", errors="ignore")
        try:
            device = (json.loads(text).get("device") or "all").lower()
        except Exception:
            qs = parse_qs(text)
            if "device" in qs:
                device = qs["device"][0].lower()
    if device not in ("gpu", "npu", "all"):
        return None
    return device


def handle_stop(body):
    device = parse_device(body)
    if device is None:
        send_headers(status="400 Bad Request")
        sys.stdout.buffer.write(json.dumps({"error": "device must be one of gpu, npu, all"}).encode("utf-8"))
        sys.stdout.buffer.flush()
        return

    # Always take the locks in DEVICES order, so a "both domains" unload can never
    # deadlock against a concurrent single-domain switch.
    lock_fds = []
    try:
        for domain in DEVICES if device == "all" else (device,):
            lock_fds.append(acquire_lock(LOCK_FILES[domain]))
            for unit in unit_list_for(domain):
                run_systemctl("stop", unit)
            state_file = STATE_FILES.get(domain)
            if state_file and os.path.exists(state_file):
                try:
                    os.remove(state_file)
                except Exception:
                    pass

        send_headers()
        sys.stdout.buffer.write(json.dumps({"status": "stopped", "device": device}).encode("utf-8"))
        sys.stdout.buffer.flush()
    finally:
        for fd in reversed(lock_fds):
            release_lock(fd)


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

    try:
        if clean_path in ("/api/status", "/status"):
            handle_status()
        elif clean_path in ("/api/switch", "/switch") and method == "POST":
            handle_switch(body)
        elif clean_path in ("/api/stop", "/stop") and method == "POST":
            handle_stop(body)
        else:
            send_headers(status="404 Not Found")
            sys.stdout.buffer.write(json.dumps({"error": f"API endpoint '{clean_path}' not found"}).encode("utf-8"))
            sys.stdout.buffer.flush()
    except Exception as e:
        sys.stderr.write(f"API Error in {clean_path}: {e}\n")
        send_headers(status="500 Internal Server Error")
        sys.stdout.buffer.write(json.dumps({"error": str(e)}).encode("utf-8"))
        sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
