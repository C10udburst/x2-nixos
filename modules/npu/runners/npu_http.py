"""Minimal HTTP layer shared by the NPU runners.

One runner process == one model resident on the NPU, exactly like `gufo-serve` or
`llama-server` are one model on the GPU: the process is loaded once, serves until it is
killed, and workload switching is `systemctl stop` + `systemctl start` (the gateway
switcher already owns routing, model remapping and the /v1/models catalogue - nginx
serves that list statically, so a runner only exposes what inference needs).

A runner therefore serves exactly:
    GET  /health                 200 once the weights are resident (the process only
                                 starts listening after load, so 200 == ready)
    POST <route from the table>  whatever the modality defines

Replies are either buffered (bytes / list of bytes) or streamed as chunked responses
that are flushed per chunk, which is what keeps SSE token streams unbuffered through
nginx -> fcgiwrap -> curl.
"""

import json
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# One session per process. Racing requests must not interleave on it.
SESSION_LOCK = threading.RLock()


def json_body(payload) -> bytes:
    return json.dumps(payload).encode("utf-8")


def sse_event(obj) -> bytes:
    return f"data: {json.dumps(obj, separators=(',', ':'))}\n\n".encode("utf-8")


class ApiError(Exception):
    """Client-fixable failure, rendered as an OpenAI-style error body."""

    def __init__(self, message, status=400, err_type="invalid_request_error"):
        super().__init__(message)
        self.status = status
        self.err_type = err_type


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # Filled in by serve() on the generated handler class.
    ALIAS = "npu-model"
    ROUTES = {}
    HEALTH = lambda: {}

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")

    def _send(self, status, headers, chunks):
        stream = not isinstance(chunks, (bytes, list, tuple)) and chunks is not None
        if stream:
            self.send_response(status)
            self.send_header("Content-Type", headers.get("Content-Type", "text/event-stream"))
            self.send_header("Cache-Control", "no-cache")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Transfer-Encoding", "chunked")
            self._cors()
            self.end_headers()
            try:
                for chunk in chunks:
                    if chunk:
                        self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                        self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                self.close_connection = True
            return

        body = b"" if chunks is None else (chunks if isinstance(chunks, bytes) else b"".join(chunks))
        self.send_response(status)
        self.send_header("Content-Type", headers.get("Content-Type", "application/json"))
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _error(self, status, message, err_type):
        self._send(
            status,
            {"Content-Type": "application/json"},
            json_body({"error": {"message": message, "type": err_type}}),
        )

    def _path(self):
        return self.path.split("?")[0].rstrip("/") or "/"

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if self._path() in ("/health", "/healthz", "/"):
            info = {"status": "ok", "model": self.ALIAS}
            try:
                info.update(self.HEALTH() or {})
            except Exception:
                pass
            self._send(200, {"Content-Type": "application/json"}, json_body(info))
            return
        self._error(404, f"unknown path {self.path}", "not_found_error")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length > 0 else b""
        handler = self.ROUTES.get((self.command, self._path()))
        if handler is None:
            self._error(404, f"unknown path {self.path}", "not_found_error")
            return
        try:
            status, headers, chunks = handler(body)
            self._send(status, headers or {}, chunks)
        except ApiError as exc:
            self._error(exc.status, str(exc), exc.err_type)
        except Exception as exc:
            import traceback

            traceback.print_exc(file=sys.stderr)
            self._error(500, f"{type(exc).__name__}: {exc}", "server_error")

    def log_message(self, fmt, *args):
        sys.stderr.write("[npu] %s\n" % (fmt % args))


def serve(alias, routes, host="127.0.0.1", port=8083, health=None):
    """Block and serve `routes` {(method, path): fn}. Call only after loading the model."""
    handler = type(
        "NpuHandler",
        (_Handler,),
        {"ALIAS": alias, "ROUTES": routes, "HEALTH": health or (lambda: {})},
    )

    httpd = ThreadingHTTPServer((host, port), handler)
    httpd.daemon_threads = True

    def stop(signum, _frame):
        sys.stderr.write(f"[npu] signal {signum}, shutting down\n")
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, stop)

    sys.stderr.write(f"[npu] {alias} ready on http://{host}:{port}\n")
    try:
        httpd.serve_forever()
    finally:
        httpd.server_close()


def parse_json(body):
    if not body:
        return {}
    try:
        data = json.loads(body.decode("utf-8"))
    except Exception as exc:
        raise ApiError(f"request body is not valid JSON: {exc}")
    if not isinstance(data, dict):
        raise ApiError("request body must be a JSON object")
    return data
