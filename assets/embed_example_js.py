#!/usr/bin/env python3
"""Pack webgpu.js + runtime boot + embedded wasm into one <example>.js."""

from __future__ import annotations

import argparse
import base64
from pathlib import Path


BOOT_TEMPLATE = r'''
// --- embedded boot (from runtime.js, wasm inlined) ---
const __NATIVE_WASM_B64 = "%WASM_B64%";

let wasm_exports;
const status_el = () => document.getElementById("status");

const base_imports = {
  wasm_write_string: (s_count, s_data, to_standard_error) => {
    const str = js_string_from_jai_string(s_data, s_count);
    write_to_console_log(str, to_standard_error);
  },
  jsPerformanceNowMs: () => performance.now(),
};

let last_present_ms = 0;

async function jsWaitForFrameImpl(fps) {
  const target_ms = fps > 0 ? 1000 / Number(fps) : 0;
  await new Promise((resolve) => requestAnimationFrame(resolve));
  if (target_ms > 0 && last_present_ms > 0) {
    while (performance.now() - last_present_ms < target_ms) {
      await new Promise((resolve) => requestAnimationFrame(resolve));
    }
  }
  last_present_ms = performance.now();
}

function b64_to_u8(b64) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function boot() {
  if (!navigator.gpu) {
    const msg = "WebGPU not available — open in Chrome/Edge";
    if (status_el()) status_el().textContent = msg;
    throw new Error(msg);
  }
  if (typeof WebAssembly.Suspending !== "function" || typeof WebAssembly.promising !== "function") {
    const msg = "JSPI required (WebAssembly.Suspending / promising)";
    if (status_el()) status_el().textContent = msg;
    throw new Error(msg);
  }

  let adapter = await navigator.gpu.requestAdapter();
  if (!adapter) {
    adapter = await navigator.gpu.requestAdapter({ forceFallbackAdapter: true });
  }
  if (!adapter) {
    const msg = "No WebGPU adapter";
    if (status_el()) status_el().textContent = msg;
    throw new Error(msg);
  }

  const device = await adapter.requestDevice();
  globalThis.__native_set_gpu(adapter, device, device.queue);

  const w = globalThis.native_webgpu_imports || {};
  const env = Object.assign({}, base_imports, w, {
    wasm_debug_break: w.wasm_debug_break || (() => { debugger; }),
    jsWaitForFrame: new WebAssembly.Suspending(w.jsWaitForFrame || jsWaitForFrameImpl),
  });

  const wasm_bytes = b64_to_u8(__NATIVE_WASM_B64);
  const result = await WebAssembly.instantiate(wasm_bytes, { env });
  wasm_exports = result.instance.exports;
  globalThis.__native_webgpu.set_memory(wasm_exports.memory);

  const jai_context = wasm_exports.__jai_runtime_init(0, 0n);
  if (status_el()) status_el().textContent = "running";

  const main = WebAssembly.promising(wasm_exports.main);
  await main(jai_context);
}

const text_decoder = new TextDecoder();
function js_string_from_jai_string(pointer, length) {
  const mem = wasm_exports.memory;
  const u8 = new Uint8Array(mem.buffer);
  const bytes = u8.subarray(Number(pointer), Number(pointer) + Number(length));
  return text_decoder.decode(bytes);
}

let console_buffer = "";
let console_buffer_is_standard_error;
let console_timeout;
const FLUSH_CONSOLE_AFTER_MS = 3;

function write_to_console_log(str, to_standard_error) {
  if (console_buffer && console_buffer_is_standard_error != to_standard_error) flush_buffer();
  console_buffer_is_standard_error = to_standard_error;
  const lines = str.split("\n");
  for (let i = 0; i < lines.length - 1; i++) {
    console_buffer += lines[i];
    flush_buffer();
  }
  console_buffer += lines[lines.length - 1];
  clearTimeout(console_timeout);
  if (console_buffer) {
    console_timeout = setTimeout(flush_buffer, FLUSH_CONSOLE_AFTER_MS);
  }
  function flush_buffer() {
    if (!console_buffer) return;
    if (console_buffer_is_standard_error) console.error(console_buffer);
    else console.log(console_buffer);
    console_buffer = "";
  }
}

boot().catch((err) => {
  console.error(err);
  if (status_el()) status_el().textContent = String(err);
});
'''


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--webgpu", type=Path, required=True)
    p.add_argument("--wasm", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--name", default="")
    args = p.parse_args()

    webgpu = args.webgpu.read_text(encoding="utf-8")
    wasm_b64 = base64.b64encode(args.wasm.read_bytes()).decode("ascii")
    boot = BOOT_TEMPLATE.replace("%WASM_B64%", wasm_b64)
    header = f"// Auto-generated self-contained example: {args.name or args.out.name}\n"
    args.out.write_text(header + webgpu + "\n" + boot, encoding="utf-8")
    print(f"wrote {args.out} ({args.out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
