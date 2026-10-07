#!/usr/bin/env python3
"""Serve the display page and accept RGBA frames (600x400) on port 4321.

  GET  /        → embedded HTML viewer
  GET  /frame   → latest RGBA bytes (or 204 if none yet)
  POST /frame   → body = raw RGBA (600*400*4), from the Jai app
"""

from __future__ import annotations

import argparse
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WIDTH = 600
HEIGHT = 400
FRAME_BYTES = WIDTH * HEIGHT * 4
DEFAULT_PORT = 4321

_lock = threading.Lock()
_latest: bytes | None = None

HTML = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>GPU-RHI Display</title>
  <style>
    :root {{ color-scheme: dark; }}
    body {{
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background: #111;
      color: #ccc;
      font: 14px/1.4 ui-sans-serif, system-ui, sans-serif;
    }}
    .wrap {{ text-align: center; }}
    canvas {{
      display: block;
      width: {WIDTH}px;
      height: {HEIGHT}px;
      image-rendering: pixelated;
      background: #000;
      border: 1px solid #333;
    }}
    #status {{ margin-top: 0.75rem; opacity: 0.7; }}
  </style>
</head>
<body>
  <div class="wrap">
    <canvas id="c" width="{WIDTH}" height="{HEIGHT}"></canvas>
    <div id="status">connecting…</div>
  </div>
  <script>
    const W = {WIDTH}, H = {HEIGHT}, FRAME = W * H * 4;
    const canvas = document.getElementById("c");
    const ctx = canvas.getContext("2d");
    const status = document.getElementById("status");
    const image = ctx.createImageData(W, H);

    let frames = 0;
    let lastFpsAt = performance.now();
    let fps = 0;

    async function pull() {{
      try {{
        const res = await fetch("/frame", {{ cache: "no-store" }});
        if (res.status === 204) {{
          status.textContent = "waiting for frames…";
          return;
        }}
        if (!res.ok) throw new Error("HTTP " + res.status);
        const buf = await res.arrayBuffer();
        if (buf.byteLength !== FRAME) {{
          status.textContent = `bad frame size ${{buf.byteLength}} (want ${{FRAME}})`;
          return;
        }}
        image.data.set(new Uint8Array(buf));
        ctx.putImageData(image, 0, 0);
        frames += 1;
        const now = performance.now();
        if (now - lastFpsAt >= 1000) {{
          fps = frames;
          frames = 0;
          lastFpsAt = now;
        }}
        status.textContent = `${{fps}} fps · ${{FRAME}} bytes RGBA`;
      }} catch (e) {{
        status.textContent = "error: " + e.message;
      }}
    }}

    async function loop() {{
      while (true) {{
        const t0 = performance.now();
        await pull();
        const wait = Math.max(0, 16 - (performance.now() - t0));
        await new Promise((r) => setTimeout(r, wait));
      }}
    }}
    loop();
  </script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        if self.command == "POST" or int(args[1]) >= 400:
            super().log_message(fmt, *args)

    def do_GET(self) -> None:
        if self.path in ("/", "/index.html", "/display.html"):
            self._send(200, "text/html; charset=utf-8", HTML.encode())
            return
        if self.path.startswith("/frame"):
            with _lock:
                frame = _latest
            if frame is None:
                self.send_response(204)
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                return
            self._send(200, "application/octet-stream", frame)
            return
        self.send_error(404)

    def do_POST(self) -> None:
        if not self.path.startswith("/frame"):
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if len(body) != FRAME_BYTES:
            msg = f"expected {FRAME_BYTES} bytes, got {len(body)}".encode()
            self._send(400, "text/plain; charset=utf-8", msg)
            return
        with _lock:
            global _latest
            _latest = body
        self._send(204, "text/plain; charset=utf-8", b"")

    def _send(self, code: int, content_type: str, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = ap.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"display server on http://{args.host}:{args.port}/")
    print(f"POST RGBA frames ({FRAME_BYTES} bytes) to /frame")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
