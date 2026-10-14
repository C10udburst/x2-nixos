{
  pkgs,
  lib,
}: {
  workloadId,
  serviceName,
  backendPort,
  healthCheckCmd,
  timeoutSec ? 60,
  description ? serviceName,
  stopScript,
}:
pkgs.writeShellScript "wake-netcat-${workloadId}" ''
  set -euo pipefail

  export PATH="/run/wrappers/bin:${lib.makeBinPath [
    pkgs.util-linux
    pkgs.coreutils
    pkgs.systemd
    pkgs.netcat-openbsd
  ]}:$PATH"

  LOCK_FILE="/run/model-lock/model.lock"
  STATE_FILE="/run/model-lock/active_model"
  BACKEND_PORT="${toString backendPort}"

  # 1. Acquire independent workload lock
  exec 9>"$LOCK_FILE"
  chmod 666 "$LOCK_FILE" 2>/dev/null || true
  flock -x 9

  # 2. Check if already the active workload
  ACTIVE=$(cat "$STATE_FILE" 2>/dev/null || true)
  if [ "$ACTIVE" != "${workloadId}" ]; then
    # Stop any other active workload using eval-time generated stop script
    ${stopScript} "${serviceName}"

    # Start target backend service
    sudo -n ${pkgs.systemd}/bin/systemctl start "${serviceName}"

    # Wait for backend to become responsive
    DEADLINE=$(( $(date +%s) + ${toString timeoutSec} ))
    READY=0
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      if ${healthCheckCmd}; then
        READY=1
        echo "${workloadId}" > "$STATE_FILE"
        chmod 666 "$STATE_FILE" 2>/dev/null || true
        break
      fi
      sleep 0.2
    done

    if [ "$READY" -eq 0 ]; then
      flock -u 9
      printf "HTTP/1.1 504 Gateway Timeout\r\n"
      printf "Content-Type: text/plain\r\n"
      printf "Connection: close\r\n\r\n"
      printf "${description} startup timed out\n"
      exit 0
    fi
  fi
  flock -u 9

  # 3. Transparently forward incoming connection to backend using netcat
  exec ${pkgs.netcat-openbsd}/bin/nc -N 127.0.0.1 "$BACKEND_PORT"
''
