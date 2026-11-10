#!/usr/bin/env python3
"""Serve a self-contained WebGPU example from .bin/

  LD_LIBRARY_PATH= python3 assets/serve.py --example 02_surface
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

DEFAULT_EXAMPLE = "02_surface"

HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>GPU-RHI — {example}</title>
  <style>
    :root {{ color-scheme: dark; }}
    html, body {{ margin: 0; height: 100%; background: #111; color: #ccc;
      font: 14px/1.4 ui-sans-serif, system-ui, sans-serif; }}
    #wrap {{ height: 100%; display: flex; flex-direction: column; gap: 0.5rem;
      padding: 0.5rem; box-sizing: border-box; }}
    #canvases {{ flex: 1 1 auto; min-height: 0; display: flex; flex-wrap: wrap;
      gap: 0.5rem; align-content: stretch; }}
    canvas {{ display: block; flex: 1 1 auto; width: 100%; height: 100%;
      min-height: 0; background: #000; image-rendering: pixelated;
      border: 1px solid #333; }}
    #status {{ opacity: 0.7; padding: 0.15rem 0.25rem; flex: 0 0 auto; }}
  </style>
</head>
<body>
  <div id="wrap">
    <!-- <div id="canvases">
      <canvas id="app" width="800" height="600"></canvas>
    </div> -->
    <div id="status">loading {example}…</div>
  </div>
  <script src="{example}.js"></script>
</body>
</html>
"""


def make_handler(example: str):
    html = HTML.format(example=example).encode("utf-8")

    class Handler(SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.path in ("/", "/index.html"):
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(html)))
                self.end_headers()
                self.wfile.write(html)
                return
            super().do_GET()

        def end_headers(self):
            # Required for shared / Memory64 WASM in Chromium.
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.send_header("Cross-Origin-Resource-Policy", "same-origin")
            self.send_header("Cache-Control", "no-cache")
            super().end_headers()

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--example", default=DEFAULT_EXAMPLE,
                        help="Example name (loads .bin/<example>.js)")
    args = parser.parse_args()

    if not WEB_ROOT.is_dir():
        raise SystemExit(f"Web root missing: {WEB_ROOT} (build with: jai build.jai - web)")

    js_path = WEB_ROOT / f"{args.example}.js"
    if not js_path.is_file():
        raise SystemExit(
            f"{js_path.name} not found in {WEB_ROOT} "
            f"(build with: jai build.jai - web {args.example})"
        )

    mimetypes.add_type("application/wasm", ".wasm")
    mimetypes.add_type("text/javascript", ".js")
    os.chdir(WEB_ROOT)
    server = ThreadingHTTPServer(("localhost", args.port), make_handler(args.example))
    print(f"Serving {js_path.name} from {WEB_ROOT} at http://localhost:{args.port}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
