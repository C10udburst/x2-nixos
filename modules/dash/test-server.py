#!/usr/bin/env python3
"""
Development HTTP + CGI server for EVO-X2 dashboard preview.
Serves static frontend from modules/dash/frontend/dist and dispatches
/api/reservations* to reservations.py and /api/* to dash.py.
"""

import argparse
import http.server
import mimetypes
import os
import socketserver
import subprocess
import sys


class DashboardDevHandler(http.server.BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS, DELETE")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def do_DELETE(self):
        self.handle_request()

    def handle_request(self):
        clean_path = self.path.split("?")[0].rstrip("/") or "/"

        # 1. Route API requests through CGI scripts
        if clean_path.startswith("/api/reservations"):
            self.execute_cgi(self.server.reservations_script)
            return
        elif clean_path.startswith("/api/"):
            self.execute_cgi(self.server.dash_script)
            return

        # 2. Serve static frontend files
        dist_dir = self.server.dist_dir
        if clean_path in ("/", "/index.html"):
            self.serve_file(os.path.join(dist_dir, "index.html"), "text/html; charset=utf-8")
        elif clean_path in ("/reserve", "/reserve.html"):
            self.serve_file(os.path.join(dist_dir, "reserve.html"), "text/html; charset=utf-8")
        elif clean_path.startswith("/assets/"):
            rel_path = clean_path.lstrip("/")
            file_path = os.path.join(dist_dir, rel_path)
            self.serve_file(file_path, cache_forever=True)
        else:
            rel_path = clean_path.lstrip("/")
            file_path = os.path.join(dist_dir, rel_path)
            if os.path.isfile(file_path):
                self.serve_file(file_path)
            else:
                self.send_error(404, f"File '{clean_path}' not found")

    def serve_file(self, file_path, content_type=None, cache_forever=False):
        if not os.path.isfile(file_path):
            self.send_error(404, f"File '{file_path}' not found")
            return

        try:
            with open(file_path, "rb") as f:
                content = f.read()

            self.send_response(200)
            guessed_type = content_type or mimetypes.guess_type(file_path)[0] or "application/octet-stream"
            self.send_header("Content-Type", guessed_type)
            self.send_header("Content-Length", str(len(content)))
            if cache_forever:
                self.send_header("Cache-Control", "public, max-age=31536000, immutable")
            else:
                self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(content)
        except Exception as e:
            self.send_error(500, f"Error reading file: {e}")

    def execute_cgi(self, script_path):
        if not os.path.isfile(script_path):
            self.send_error(500, f"CGI script '{script_path}' not found")
            return

        content_length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(content_length) if content_length > 0 else b""

        # Build CGI Environment
        env = os.environ.copy()
        env["REQUEST_METHOD"] = self.command
        env["REQUEST_URI"] = self.path
        env["PATH_INFO"] = self.path.split("?")[0]
        env["QUERY_STRING"] = self.path.split("?")[1] if "?" in self.path else ""
        env["REMOTE_ADDR"] = self.client_address[0]
        env["CONTENT_LENGTH"] = str(content_length)
        if "Content-Type" in self.headers:
            env["CONTENT_TYPE"] = self.headers["Content-Type"]
        for header, val in self.headers.items():
            cgi_var = f"HTTP_{header.upper().replace('-', '_')}"
            env[cgi_var] = val

        try:
            proc = subprocess.Popen(
                [sys.executable, script_path],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
            )
            stdout_data, stderr_data = proc.communicate(input=body)

            if stderr_data:
                sys.stderr.write(stderr_data.decode("utf-8", errors="replace"))

            # Parse CGI Output (Headers + Body)
            # Find boundary between headers and body
            header_end = stdout_data.find(b"\r\n\r\n")
            delimiter_len = 4
            if header_end == -1:
                header_end = stdout_data.find(b"\n\n")
                delimiter_len = 2

            if header_end != -1:
                header_block = stdout_data[:header_end].decode("utf-8", errors="replace")
                response_body = stdout_data[header_end + delimiter_len :]
            else:
                header_block = ""
                response_body = stdout_data

            status_code = 200
            headers_to_send = []

            for line in header_block.splitlines():
                if not line.strip():
                    continue
                if line.lower().startswith("status:"):
                    parts = line.split(":", 1)[1].strip().split(" ", 1)
                    try:
                        status_code = int(parts[0])
                    except ValueError:
                        pass
                else:
                    if ":" in line:
                        k, v = line.split(":", 1)
                        headers_to_send.append((k.strip(), v.strip()))

            self.send_response(status_code)
            for k, v in headers_to_send:
                self.send_header(k, v)
            if not any(k.lower() == "content-length" for k, _ in headers_to_send):
                self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)

        except Exception as e:
            self.send_error(500, f"CGI Execution Failed: {e}")


class ThreadedTCPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(description="EVO-X2 Dashboard Development Server")
    parser.add_argument("--port", type=int, default=8080, help="Port to listen on (default: 8080)")
    parser.add_argument("--host", type=str, default="127.0.0.1", help="Host interface (default: 127.0.0.1)")
    args = parser.parse_args()

    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    dist_dir = os.path.join(project_root, "modules", "dash", "frontend", "dist")
    reservations_script = os.path.join(project_root, "modules", "dash", "reservations.py")
    dash_script = os.path.join(project_root, "modules", "dash", "dash.py")

    if not os.path.isdir(dist_dir):
        print(f"Warning: dist directory '{dist_dir}' not found. Run 'npm run build' first.", file=sys.stderr)

    server = ThreadedTCPServer((args.host, args.port), DashboardDevHandler)
    server.dist_dir = dist_dir
    server.reservations_script = reservations_script
    server.dash_script = dash_script

    print("=" * 64)
    print("  GMKtec EVO-X2 Dashboard Local Preview Server")
    print("=" * 64)
    print(f"  Server listening on: http://{args.host}:{args.port}")
    print(f"  - Main Dashboard:   http://{args.host}:{args.port}/")
    print(f"  - LLM Reservation:  http://{args.host}:{args.port}/reserve.html")
    print(f"  - Reservations API: http://{args.host}:{args.port}/api/reservations")
    print(f"  - Status API:       http://{args.host}:{args.port}/api/status")
    print("=" * 64)
    print("Press Ctrl+C to stop.")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping development server...")
        server.server_close()


if __name__ == "__main__":
    main()
