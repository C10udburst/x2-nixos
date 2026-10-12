#!/usr/bin/env bash
set -euo pipefail

# Ultra-fast FastCGI model switcher for unified AI inference hot path (/v1/*).
# GMKtec EVO-X2 (AMD Ryzen AI Max+ 395 128GB Unified Memory).

CONFIG_FILE="${MODELS_CONFIG_PATH:-/etc/models.json}"
LOCK_FILE="/run/model-lock/model.lock"
STATE_FILE="/run/model-lock/active_model"

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
  REQ_MODEL=$(echo "$BODY" | jq -r '.model // empty' 2>/dev/null || true)
fi

# Fallback to default_model or currently active model
if [ -z "$REQ_MODEL" ] && [ -f "$CONFIG_FILE" ]; then
  REQ_MODEL=$(jq -r '.default_model // empty' "$CONFIG_FILE" 2>/dev/null || true)
fi
if [ -z "$REQ_MODEL" ] && [ -f "$STATE_FILE" ]; then
  REQ_MODEL=$(cat "$STATE_FILE" 2>/dev/null || true)
fi

# 4. Lookup model in configuration registry
MODEL_ENTRY=""
if [ -n "$REQ_MODEL" ] && [ -f "$CONFIG_FILE" ]; then
  MODEL_ENTRY=$(jq -c --arg m "$REQ_MODEL" '.models[$m] // empty' "$CONFIG_FILE" 2>/dev/null || true)
fi

if [ -z "$MODEL_ENTRY" ]; then
  printf "Status: 404 Not Found\r\n"
  printf "Content-Type: application/json\r\n"
  printf "Access-Control-Allow-Origin: *\r\n\r\n"
  printf '{"error":{"message":"Model not found in registry","type":"invalid_request_error"}}\n'
  exit 0
fi

TARGET_SERVICE=$(echo "$MODEL_ENTRY" | jq -r '.service_name')
REMAPPED_MODEL=$(echo "$MODEL_ENTRY" | jq -r '.remapped_model // empty')
TARGET_URL=$(echo "$MODEL_ENTRY" | jq -r '.url')

ACTIVE_MODEL=""
if [ -f "$STATE_FILE" ]; then
  ACTIVE_MODEL=$(cat "$STATE_FILE" 2>/dev/null || true)
fi

exec 9>"$LOCK_FILE"

# 5. Check if service is active; dynamic switch if needed
SERVICE_ACTIVE=0
if sudo -n systemctl is-active --quiet "$TARGET_SERVICE" 2>/dev/null; then
  SERVICE_ACTIVE=1
fi

if [ "$REQ_MODEL" != "$ACTIVE_MODEL" ] || [ "$SERVICE_ACTIVE" -eq 0 ]; then
  flock -x 9

  # Re-check under lock
  ACTIVE_MODEL=$(cat "$STATE_FILE" 2>/dev/null || true)
  if sudo -n systemctl is-active --quiet "$TARGET_SERVICE" 2>/dev/null; then
    SERVICE_ACTIVE=1
  else
    SERVICE_ACTIVE=0
  fi

  if [ "$REQ_MODEL" != "$ACTIVE_MODEL" ] || [ "$SERVICE_ACTIVE" -eq 0 ]; then
    # Stop Immich ML if it was running
    if sudo -n systemctl is-active --quiet immich-machine-learning.service 2>/dev/null; then
      sudo -n systemctl stop immich-machine-learning.service 2>/dev/null || true
    fi

    # Start target service (systemd Conflicts automatically stops other models)
    if sudo -n systemctl start "$TARGET_SERVICE" 2>/dev/null; then
      DEADLINE=$(( $(date +%s) + 90 ))
      READY=0
      while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        if curl -s -f "${TARGET_URL}/health" >/dev/null 2>&1 || \
           curl -s -f "${TARGET_URL}/v1/models" >/dev/null 2>&1 || \
           curl -s -f "${TARGET_URL}/" >/dev/null 2>&1; then
          echo "$REQ_MODEL" > "$STATE_FILE"
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
if [ -n "$BODY" ] && [ -n "$REMAPPED_MODEL" ]; then
  BODY=$(echo "$BODY" | jq -c --arg m "$REMAPPED_MODEL" 'if has("model") then .model = $m else . end' 2>/dev/null || echo "$BODY")
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
if [ -n "$BODY" ]; then
  CURL_ARGS+=(--data-binary "$BODY")
fi

# Transform first HTTP header into FastCGI Status line, inject CORS + no-buffer, and stream
exec curl "${CURL_ARGS[@]}" \
  | sed -u \
      -e '1s|^HTTP/[0-9.]* |Status: |' \
      -e '1a Access-Control-Allow-Origin: *\
X-Accel-Buffering: no'
