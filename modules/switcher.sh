#!/usr/bin/env bash
set -euo pipefail

# Ultra-fast FastCGI model switcher for Gufo inference hot path (/v1/*).
# GMKtec EVO-X2 (AMD Ryzen AI Max+ 395 128GB).

BACKEND_HOST="127.0.0.1"
BACKEND_PORT="${GUFO_BACKEND_PORT:-8081}"
STATE_FILE="/run/gufo/active_model"
LOCK_FILE="/run/gufo/switch.lock"

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

ACTIVE_MODEL=""
if [ -f "$STATE_FILE" ]; then
  ACTIVE_MODEL=$(cat "$STATE_FILE" 2>/dev/null || true)
fi

# 4. Dynamic model switching if model changed
if [ -n "$REQ_MODEL" ] && [ "$REQ_MODEL" != "$ACTIVE_MODEL" ]; then
  TARGET_UNIT="gufo-${REQ_MODEL}.service"

  mkdir -p /run/gufo
  exec 9>"$LOCK_FILE"
  flock -x 9

  # Re-check under lock
  ACTIVE_MODEL=$(cat "$STATE_FILE" 2>/dev/null || true)
  if [ "$REQ_MODEL" != "$ACTIVE_MODEL" ]; then
    # Start target service; systemd Conflicts directive stops any other active model
    if sudo -n systemctl start "$TARGET_UNIT" 2>/dev/null; then
      DEADLINE=$(( $(date +%s) + 90 ))
      while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        if curl -s -f "http://${BACKEND_HOST}:${BACKEND_PORT}/health" >/dev/null 2>&1 || \
           curl -s -f "http://${BACKEND_HOST}:${BACKEND_PORT}/v1/models" >/dev/null 2>&1; then
          echo "$REQ_MODEL" > "$STATE_FILE"
          break
        fi
        sleep 0.1
      done
    else
      flock -u 9
      printf "Status: 500 Internal Server Error\r\n"
      printf "Content-Type: application/json\r\n\r\n"
      printf '{"error":{"message":"Failed to start model service %s","type":"server_error"}}\n' "$TARGET_UNIT"
      exit 0
    fi
  fi
  flock -u 9
fi

# 5. Verify backend is reachable
if ! curl -s -f "http://${BACKEND_HOST}:${BACKEND_PORT}/health" >/dev/null 2>&1 && \
   ! curl -s -f "http://${BACKEND_HOST}:${BACKEND_PORT}/v1/models" >/dev/null 2>&1; then
  printf "Status: 503 Service Unavailable\r\n"
  printf "Content-Type: application/json\r\n"
  printf "Access-Control-Allow-Origin: *\r\n\r\n"
  printf '{"error":{"message":"No model is currently active or backend is still loading.","type":"service_unavailable"}}\n'
  exit 0
fi

# 6. Stream request directly to Gufo backend using curl
CURL_ARGS=(
  -s
  -N
  -i
  -X "$REQUEST_METHOD"
  "http://${BACKEND_HOST}:${BACKEND_PORT}${REQUEST_URI:-/v1/chat/completions}"
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
