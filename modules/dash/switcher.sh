#!/usr/bin/env bash
set -euo pipefail

# Ultra-fast FastCGI model switcher for unified AI inference hot path (/v1/*).
# GMKtec EVO-X2 (AMD Ryzen AI Max+ 395 128GB Unified Memory).
#
# Dual-domain locking (Rule 1 is enforced PER DOMAIN):
#   gpu -> /run/model-lock/gpu.lock + active_gpu   (RDNA 3.5 iGPU)
#   npu -> /run/model-lock/npu.lock + active_npu   (Ryzen AI XDNA 2)
# Acquiring one domain never stops a workload of the other domain.

CONFIG_FILE="${MODELS_CONFIG_PATH:-/etc/models.json}"

# 1. CORS Preflight
if [ "${REQUEST_METHOD:-GET}" = "OPTIONS" ]; then
  printf "Status: 204 No Content\r\n"
  printf "Access-Control-Allow-Origin: *\r\n"
  printf "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
  printf "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
  printf "X-Accel-Buffering: no\r\n\r\n"
  exit 0
fi

# 2. Read request body if present
BODY=""
CONTENT_LEN="${CONTENT_LENGTH:-0}"
if [ "$CONTENT_LEN" -gt 0 ] 2>/dev/null; then
  BODY=$(cat)
fi

# 3. Model detection using jq (hot path)
REQ_MODEL=""
if [ -n "$BODY" ]; then
  REQ_MODEL=$(printf '%s' "$BODY" | jq -r '.model // empty' 2>/dev/null || true)
fi

if [ -z "$REQ_MODEL" ] && [ -n "${QUERY_STRING:-}" ]; then
  REQ_MODEL=$(printf '%s' "$QUERY_STRING" | grep -oP '(^|&)model=\K[^&]+' 2>/dev/null || true)
fi
if [ -z "$REQ_MODEL" ] && [ -n "${HTTP_X_MODEL:-}" ]; then
  REQ_MODEL="$HTTP_X_MODEL"
fi

# Fallback to default_model, then to whichever domain is warm (GPU first, then NPU)
if [ -z "$REQ_MODEL" ] && [ -f "$CONFIG_FILE" ]; then
  REQ_MODEL=$(jq -r '.default_model // empty' "$CONFIG_FILE" 2>/dev/null || true)
fi
if [ -z "$REQ_MODEL" ]; then
  for fallback_state in /run/model-lock/active_gpu /run/model-lock/active_npu; do
    if [ -f "$fallback_state" ]; then
      REQ_MODEL=$(cat "$fallback_state" 2>/dev/null || true)
      [ -n "$REQ_MODEL" ] && break
    fi
  done
fi

# 4. Lookup model in configuration registry - one jq call for the whole entry
ENTRY_VARS=""
if [ -n "$REQ_MODEL" ] && [ -f "$CONFIG_FILE" ]; then
  ENTRY_VARS=$(jq -r --arg m "$REQ_MODEL" '
    .models[$m] // null
    | if . == null then "" else
        "DEVICE=\((.device // "gpu") | @sh)\n" +
        "TARGET_SERVICE=\(.service_name | @sh)\n" +
        "REMAPPED_MODEL=\((.remapped_model // "") | @sh)\n" +
        "TARGET_URL=\(.url | @sh)\n" +
        "MODEL_DIR=\((.model_dir // "") | @sh)"
      end' "$CONFIG_FILE" 2>/dev/null || true)
fi

if [ -z "$ENTRY_VARS" ]; then
  printf "Status: 404 Not Found\r\n"
  printf "Content-Type: application/json\r\n"
  printf "Access-Control-Allow-Origin: *\r\n\r\n"
  printf '{"error":{"message":"Model not found in registry","type":"invalid_request_error"}}\n'
  exit 0
fi

# shellcheck disable=SC2046 $(eval) of jq @sh-quoted assignments
eval "$ENTRY_VARS"

if [ -z "${TARGET_SERVICE:-}" ] || [ -z "${TARGET_URL:-}" ]; then
  printf "Status: 500 Internal Server Error\r\n"
  printf "Content-Type: application/json\r\n\r\n"
  printf '{"error":{"message":"Registry entry is missing service_name or url","type":"server_error"}}\n'
  exit 0
fi

# Domain routing: lock + state file of the requested model's domain only
LOCK_FILE="/run/model-lock/${DEVICE}.lock"
STATE_FILE="/run/model-lock/active_${DEVICE}"

# Fail fast (and without touching the domain) when the weights were never downloaded
if [ -n "$MODEL_DIR" ] && [ ! -d "$MODEL_DIR" ]; then
  printf "Status: 503 Service Unavailable\r\n"
  printf "Content-Type: application/json\r\n"
  printf "Access-Control-Allow-Origin: *\r\n\r\n"
  printf '{"error":{"message":"Model %s is not downloaded: %s is missing","type":"service_unavailable"}}\n' \
    "$REQ_MODEL" "$MODEL_DIR"
  exit 0
fi

ACTIVE_MODEL=""
if [ -f "$STATE_FILE" ]; then
  ACTIVE_MODEL=$(cat "$STATE_FILE" 2>/dev/null || true)
fi

# 5. Check if service is active; dynamic switch within the domain if needed
SERVICE_ACTIVE=0
if sudo -n "${SYSTEMCTL:-systemctl}" is-active --quiet "$TARGET_SERVICE" 2>/dev/null; then
  SERVICE_ACTIVE=1
fi

if [ "$REQ_MODEL" != "$ACTIVE_MODEL" ] || [ "$SERVICE_ACTIVE" -eq 0 ]; then
  exec 9>"$LOCK_FILE"
  chmod 666 "$LOCK_FILE" 2>/dev/null || true
  flock -x 9

  # Re-check under lock
  ACTIVE_MODEL=$(cat "$STATE_FILE" 2>/dev/null || true)
  if sudo -n "${SYSTEMCTL:-systemctl}" is-active --quiet "$TARGET_SERVICE" 2>/dev/null; then
    SERVICE_ACTIVE=1
  else
    SERVICE_ACTIVE=0
  fi

  if [ "$REQ_MODEL" != "$ACTIVE_MODEL" ] || [ "$SERVICE_ACTIVE" -eq 0 ]; then
    # Stop any other active workload OF THIS DOMAIN ONLY (eval-time generated stop script)
    if [ -n "${STOP_OTHER_WORKLOADS:-}" ] && [ -x "${STOP_OTHER_WORKLOADS:-}" ]; then
      "$STOP_OTHER_WORKLOADS" "$DEVICE" "$TARGET_SERVICE"
    fi

    # Start target service (systemd Conflicts handles intra-domain exclusion)
    if sudo -n "${SYSTEMCTL:-systemctl}" start "$TARGET_SERVICE" 2>/dev/null; then
      DEADLINE=$(( $(date +%s) + 180 ))
      READY=0
      while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        if curl -s -f "${TARGET_URL}/health" >/dev/null 2>&1 || \
           curl -s -f "${TARGET_URL}/v1/models" >/dev/null 2>&1 || \
           curl -s -f "${TARGET_URL}/" >/dev/null 2>&1; then
          echo "$REQ_MODEL" > "$STATE_FILE"
          chmod 666 "$STATE_FILE" 2>/dev/null || true
          READY=1
          break
        fi
        sleep 0.1
      done

      if [ "$READY" -eq 0 ]; then
        flock -u 9
        printf "Status: 504 Gateway Timeout\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"error":{"message":"Target model service failed to become responsive in time","type":"gateway_timeout"}}\n'
        exit 0
      fi
    else
      flock -u 9
      printf "Status: 500 Internal Server Error\r\n"
      printf "Content-Type: application/json\r\n\r\n"
      printf '{"error":{"message":"Failed to start model service %s","type":"server_error"}}\n' "$TARGET_SERVICE"
      exit 0
    fi
  fi
  flock -u 9
fi

# 6. Verify backend is responsive
if ! curl -s -f "${TARGET_URL}/health" >/dev/null 2>&1 && \
   ! curl -s -f "${TARGET_URL}/v1/models" >/dev/null 2>&1 && \
   ! curl -s -f "${TARGET_URL}/" >/dev/null 2>&1; then
  printf "Status: 503 Service Unavailable\r\n"
  printf "Content-Type: application/json\r\n"
  printf "Access-Control-Allow-Origin: *\r\n\r\n"
  printf '{"error":{"message":"Model service is not reachable","type":"service_unavailable"}}\n'
  exit 0
fi

# 7. Remap model ID in request body before forwarding (Rule 2)
if [ -n "$BODY" ] && [ -n "$REMAPPED_MODEL" ] && [ "$REMAPPED_MODEL" != "$REQ_MODEL" ]; then
  BODY=$(printf '%s' "$BODY" | jq -c --arg m "$REMAPPED_MODEL" 'if has("model") then .model = $m else . end' 2>/dev/null || printf '%s' "$BODY")
fi

# 8. Stream request directly to target backend URL using curl
CURL_ARGS=(
  -s
  -N
  -i
  -X "$REQUEST_METHOD"
  "${TARGET_URL}${REQUEST_URI:-/v1/chat/completions}"
)

if [ -n "${CONTENT_TYPE:-}" ]; then
  CURL_ARGS+=(-H "Content-Type: $CONTENT_TYPE")
fi
if [ -n "${HTTP_AUTHORIZATION:-}" ]; then
  CURL_ARGS+=(-H "Authorization: $HTTP_AUTHORIZATION")
fi

# Transform first HTTP header into FastCGI Status line, inject CORS + no-buffer, and stream
if [ -n "$BODY" ]; then
  CURL_ARGS+=(--data-binary @-)
  printf '%s' "$BODY" | curl "${CURL_ARGS[@]}" \
    | sed -u \
        -e '1s|^HTTP/[0-9.]* |Status: |' \
        -e '1a Access-Control-Allow-Origin: *\
X-Accel-Buffering: no'
else
  curl "${CURL_ARGS[@]}" \
    | sed -u \
        -e '1s|^HTTP/[0-9.]* |Status: |' \
        -e '1a Access-Control-Allow-Origin: *\
X-Accel-Buffering: no'
fi
