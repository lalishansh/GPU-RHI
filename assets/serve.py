#!/usr/bin/env python3
"""Serve the Native web build (.bin).

  # Prefer this if you're inside the Jai nix shell (clears LD_LIBRARY_PATH):
  ./assets/serve.sh

  # Or:
  LD_LIBRARY_PATH= python3 assets/serve.py
  open http://localhost:8000/
"""

from __future__ import annotations

import argparse
import mimetypes
import os
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 8000
SCRIPT_DIR = Path(__file__).resolve().parent
# Script lives in assets/ at source, or is copied into .bin/ for web builds.
WEB_ROOT = SCRIPT_DIR.parent / ".bin" if SCRIPT_DIR.name == "assets" else SCRIPT_DIR

HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>GPU-RHI Native</title>
  <style>
    :root { color-scheme: dark; }
    html, body { margin: 0; height: 100%; background: #111; color: #ccc;
      font: 14px/1.4 ui-sans-serif, system-ui, sans-serif; }
    #wrap { min-height: 100%; display: grid; place-items: center; gap: 0.75rem; }
    canvas { display: block; background: #000; border: 1px solid #333;
      max-width: 100%; image-rendering: pixelated; }
    #status { opacity: 0.7; }
  </style>
</head>
<body>
  <div id="wrap">
    <canvas id="app" width="600" height="400"></canvas>
    <div id="status">loading…</div>
  </div>
  <script src="webgpu.js"></script>
  <script src="runtime.js"></script>
</body>
</html>
"""


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/", "/index.html"):
            body = HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def end_headers(self):
        # Required for shared / Memory64 WASM in Chromium.
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=PORT)
    args = parser.parse_args()

    if not WEB_ROOT.is_dir():
        raise SystemExit(f"Web root missing: {WEB_ROOT} (build with: jai build.jai - web)")
    if not (WEB_ROOT / "main.wasm").is_file():
        raise SystemExit(f"main.wasm not found in {WEB_ROOT} (build with: jai build.jai - web)")

    mimetypes.add_type("application/wasm", ".wasm")
    os.chdir(WEB_ROOT)
    server = ThreadingHTTPServer(("localhost", args.port), Handler)
    print(f"Serving {WEB_ROOT} at http://localhost:{args.port}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
