// High-level WebGPU bridge for Native WASM (object-handle map).
// Canvas surfaces are looked up by element id (supports app, app_1, app_2, …).

const object_map = [null]; // 1-based handles
let gpu_device = null;
let gpu_queue = null;
let gpu_adapter = null;

globalThis.__native_set_gpu = (adapter, device, queue) => {
  gpu_adapter = adapter;
  gpu_device = device;
  gpu_queue = queue;
};

function add_object(obj) {
  object_map.push(obj);
  // Handles are u64 / i64 in the WASM64 ABI — Firefox requires BigInt.
  return BigInt(object_map.length - 1);
}

function get_object(handle) {
  const h = Number(handle);
  if (h <= 0 || h >= object_map.length) return null;
  return object_map[h];
}

function read_str(ptr, len) {
  const bytes = new Uint8Array(wasm_memory.buffer, Number(ptr), Number(len));
  return new TextDecoder().decode(bytes);
}

function read_f32_array(ptr, count) {
  return new Float32Array(wasm_memory.buffer, Number(ptr), Number(count));
}

function read_u8_array(ptr, count) {
  return new Uint8Array(wasm_memory.buffer, Number(ptr), Number(count));
}

function write_u8_array(ptr, src) {
  new Uint8Array(wasm_memory.buffer, Number(ptr), src.byteLength).set(src);
}

let wasm_memory = null;
// kind: 0 window, 1 mouse, 2 keyboard, 3 touch
let pending_events = [];

window.__native_webgpu = {
  set_memory(mem) { wasm_memory = mem; },
  push_resize(canvas_id, w, h) {
    pending_events.push({ kind: 0, type: 1, i0: w | 0, i1: h | 0, i2: 0, f: 0, canvas_id });
  },
};

function bind_canvas_input(canvas) {
  if (canvas.__input_bound) return;
  canvas.__input_bound = true;
  canvas.tabIndex = 0;

  const local_xy = (e) => {
    const r = canvas.getBoundingClientRect();
    const sx = canvas.width / (r.width || 1);
    const sy = canvas.height / (r.height || 1);
    return [
      Math.round((e.clientX - r.left) * sx),
      Math.round((e.clientY - r.top) * sy),
    ];
  };

  canvas.addEventListener("pointerdown", (e) => {
    const [x, y] = local_xy(e);
    if (e.pointerType === "touch") {
      pending_events.push({ kind: 3, type: 0, i0: e.pointerId | 0, i1: x, i2: y, f: e.pressure || 1 });
    } else {
      pending_events.push({ kind: 1, type: 0, i0: e.button | 0, i1: 0, i2: 0, f: 0 });
    }
  });
  canvas.addEventListener("pointerup", (e) => {
    const [x, y] = local_xy(e);
    if (e.pointerType === "touch") {
      pending_events.push({ kind: 3, type: 1, i0: e.pointerId | 0, i1: x, i2: y, f: 0 });
    } else {
      pending_events.push({ kind: 1, type: 1, i0: e.button | 0, i1: 0, i2: 0, f: 0 });
    }
  });
  canvas.addEventListener("pointercancel", (e) => {
    if (e.pointerType !== "touch") return;
    const [x, y] = local_xy(e);
    pending_events.push({ kind: 3, type: 3, i0: e.pointerId | 0, i1: x, i2: y, f: 0 });
  });
  canvas.addEventListener("pointermove", (e) => {
    const [x, y] = local_xy(e);
    if (e.pointerType === "touch") {
      pending_events.push({ kind: 3, type: 2, i0: e.pointerId | 0, i1: x, i2: y, f: e.pressure || 1 });
    } else {
      pending_events.push({ kind: 1, type: 2, i0: x, i1: y, i2: 0, f: 0 });
    }
  });
  canvas.addEventListener("wheel", (e) => {
    pending_events.push({
      kind: 1, type: 3,
      i0: Math.round(e.deltaX) | 0,
      i1: Math.round(e.deltaY) | 0,
      i2: 0, f: 0,
    });
  }, { passive: true });

  canvas.addEventListener("keydown", (e) => {
    const type = e.repeat ? 3 : 0;
    pending_events.push({ kind: 2, type, i0: e.keyCode | 0, i1: 0, i2: 0, f: 0 });
    if (e.key && e.key.length === 1) {
      pending_events.push({ kind: 2, type: 2, i0: e.key.codePointAt(0) | 0, i1: 0, i2: 0, f: 0 });
    }
  });
  canvas.addEventListener("keyup", (e) => {
    pending_events.push({ kind: 2, type: 1, i0: e.keyCode | 0, i1: 0, i2: 0, f: 0 });
  });
}

const webgpu_imports = {
  jsEnsureCanvas: (id_ptr, id_len, w, h) => {
    const id = read_str(id_ptr, id_len);
    let canvas = document.getElementById(id);
    if (!canvas) {
      canvas = document.createElement("canvas");
      canvas.id = id;
      const wrap = document.getElementById("wrap") || document.body;
      wrap.insertBefore(canvas, wrap.firstChild);
    }
    canvas.width = Number(w);
    canvas.height = Number(h);
    canvas.style.width = `${Number(w)}px`;
    canvas.style.height = `${Number(h)}px`;
    bind_canvas_input(canvas);
  },

  jsPollInputEvent: (out_kind, out_type, out_i0, out_i1, out_i2, out_f) => {
    if (!pending_events.length) return 0;
    const ev = pending_events.shift();
    const mem = new DataView(wasm_memory.buffer);
    mem.setInt32(Number(out_kind), ev.kind | 0, true);
    mem.setInt32(Number(out_type), ev.type | 0, true);
    mem.setInt32(Number(out_i0), ev.i0 | 0, true);
    mem.setInt32(Number(out_i1), ev.i1 | 0, true);
    mem.setInt32(Number(out_i2), ev.i2 | 0, true);
    mem.setFloat32(Number(out_f), ev.f || 0, true);
    return 1;
  },

  jsWebGpuRequestDevice: async () => {
    if (!navigator.gpu) throw new Error("WebGPU not available");
    gpu_adapter = await navigator.gpu.requestAdapter();
    if (!gpu_adapter) throw new Error("No GPU adapter");
    gpu_device = await gpu_adapter.requestDevice();
    gpu_queue = gpu_device.queue;
    return 1;
  },

  // Sync wrappers used when JSPI Suspending is available; runtime.js may replace these.
  jsWebGpuHasDevice: () => (gpu_device ? 1 : 0),

  jsCreateBuffer: (usage, size, data_ptr, data_len) => {
    // usage is already GPUBufferUsage bitflags from webgpu.jai
    let u = Number(usage);
    if (!(u & GPUBufferUsage.VERTEX) && !(u & GPUBufferUsage.INDEX) && !(u & GPUBufferUsage.UNIFORM)) {
      // Defensive: never create a buffer with only COPY_* bits.
      u |= GPUBufferUsage.VERTEX;
    }
    u |= GPUBufferUsage.COPY_DST;
    const buf = gpu_device.createBuffer({
      size: Number(size),
      usage: u,
      mappedAtCreation: Number(data_len) > 0,
    });
    if (Number(data_len) > 0) {
      new Uint8Array(buf.getMappedRange()).set(read_u8_array(data_ptr, data_len));
      buf.unmap();
    }
    return add_object(buf);
  },

  jsCreateTexture: (width, height, usage, format) => {
    // format 0 = rgba8unorm, 1 = depth24plus
    const fmt = Number(format) === 1 ? "depth24plus" : "rgba8unorm";
    const tex = gpu_device.createTexture({
      size: { width: Number(width), height: Number(height) },
      format: fmt,
      usage: Number(usage),
    });
    return add_object(tex);
  },

  jsCreateShaderModule: (code_ptr, code_len) => {
    const code = read_str(code_ptr, code_len);
    return add_object(gpu_device.createShaderModule({ code }));
  },

  jsCreateUniformBuffer: (size) => {
    const buf = gpu_device.createBuffer({
      size: Number(size),
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });
    return add_object(buf);
  },

  jsWriteBuffer: (buf_handle, offset, data_ptr, data_len) => {
    const buf = get_object(buf_handle);
    gpu_queue.writeBuffer(buf, Number(offset), read_u8_array(data_ptr, data_len));
  },

  jsCreateRenderPipeline: (
    vs_mod, vs_entry_ptr, vs_entry_len,
    fs_mod, fs_entry_ptr, fs_entry_len,
    stride, has_color_attr,
    topology, depth_enabled,
    bind_group_layout_handle,
  ) => {
    const vsEntry = read_str(vs_entry_ptr, vs_entry_len);
    const fsEntry = read_str(fs_entry_ptr, fs_entry_len);
    const buffers = [{
      arrayStride: Number(stride),
      attributes: [
        { shaderLocation: 0, offset: 0, format: "float32x3" },
        ...(Number(has_color_attr) ? [{ shaderLocation: 1, offset: 12, format: "float32x3" }] : []),
      ],
    }];
    const layout = Number(bind_group_layout_handle)
      ? gpu_device.createPipelineLayout({
          bindGroupLayouts: [get_object(bind_group_layout_handle)],
        })
      : "auto";
    const desc = {
      layout,
      vertex: {
        module: get_object(vs_mod),
        entryPoint: vsEntry,
        buffers,
      },
      fragment: {
        module: get_object(fs_mod),
        entryPoint: fsEntry,
        targets: [{ format: "rgba8unorm" }],
      },
      primitive: { topology: Number(topology) === 0 ? "triangle-list" : "triangle-list", cullMode: "none" },
    };
    if (Number(depth_enabled)) {
      desc.depthStencil = {
        format: "depth24plus",
        depthWriteEnabled: true,
        depthCompare: "less-equal",
      };
    }
    return add_object(gpu_device.createRenderPipeline(desc));
  },

  jsCreatePresentPipeline: (vs_mod, fs_mod, sample_layout_handle, swap_format_ptr, swap_format_len) => {
    const swapFormat = read_str(swap_format_ptr, swap_format_len) || navigator.gpu.getPreferredCanvasFormat();
    const layout = gpu_device.createPipelineLayout({
      bindGroupLayouts: [get_object(sample_layout_handle)],
    });
    return add_object(gpu_device.createRenderPipeline({
      layout,
      vertex: { module: get_object(vs_mod), entryPoint: "vs_fullscreen" },
      fragment: {
        module: get_object(fs_mod),
        entryPoint: "fs_fullscreen",
        targets: [{ format: swapFormat }],
      },
      primitive: { topology: "triangle-list" },
    }));
  },

  jsCreateBindGroupLayoutUniform: () => {
    return add_object(gpu_device.createBindGroupLayout({
      entries: [{
        binding: 0,
        visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
        buffer: { type: "uniform" },
      }],
    }));
  },

  jsCreateBindGroupLayoutSampled: () => {
    return add_object(gpu_device.createBindGroupLayout({
      entries: [
        { binding: 0, visibility: GPUShaderStage.FRAGMENT, sampler: { type: "filtering" } },
        { binding: 1, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: "float" } },
      ],
    }));
  },

  jsCreateBindGroupUniform: (layout_handle, buffer_handle) => {
    return add_object(gpu_device.createBindGroup({
      layout: get_object(layout_handle),
      entries: [{ binding: 0, resource: { buffer: get_object(buffer_handle) } }],
    }));
  },

  jsCreateBindGroupSampled: (layout_handle, sampler_handle, tex_handle) => {
    const tex = get_object(tex_handle);
    return add_object(gpu_device.createBindGroup({
      layout: get_object(layout_handle),
      entries: [
        { binding: 0, resource: get_object(sampler_handle) },
        { binding: 1, resource: tex.createView() },
      ],
    }));
  },

  jsCreateSampler: () => {
    return add_object(gpu_device.createSampler({ magFilter: "linear", minFilter: "linear" }));
  },

  jsCreateSurface: (id_ptr, id_len) => {
    const id = read_str(id_ptr, id_len);
    const canvas = document.getElementById(id);
    if (!canvas) throw new Error(`canvas #${id} not found`);
    return add_object(canvas);
  },

  jsConfigureSurface: (surface_handle, width, height) => {
    const canvas = get_object(surface_handle);
    const format = navigator.gpu.getPreferredCanvasFormat();
    canvas.width = Number(width);
    canvas.height = Number(height);
    const ctx = canvas.getContext("webgpu");
    ctx.configure({
      device: gpu_device,
      format,
      alphaMode: "opaque",
      usage: GPUTextureUsage.RENDER_ATTACHMENT,
    });
    // stash context on canvas
    canvas.__gpu_ctx = ctx;
    canvas.__gpu_format = format;
    return add_object(ctx);
  },

  jsGetPreferredSwapFormat: (out_ptr, out_cap) => {
    const format = navigator.gpu.getPreferredCanvasFormat();
    const bytes = new TextEncoder().encode(format);
    const n = Math.min(bytes.length, Number(out_cap));
    new Uint8Array(wasm_memory.buffer, Number(out_ptr), n).set(bytes.subarray(0, n));
    return BigInt(n);
  },

  // Command recording (single encoder at a time for simplicity)
  _encoder: null,
  _pass: null,
  _color_view: null,

  jsBeginCommands: () => {
    webgpu_imports._encoder = gpu_device.createCommandEncoder();
    return 1;
  },

  jsBeginRenderPassToTexture: (color_tex, depth_tex, r, g, b, a) => {
    const color = get_object(color_tex);
    const depth = depth_tex ? get_object(depth_tex) : null;
    webgpu_imports._color_view = color.createView();
    const desc = {
      colorAttachments: [{
        view: webgpu_imports._color_view,
        clearValue: { r: Number(r), g: Number(g), b: Number(b), a: Number(a) },
        loadOp: "clear",
        storeOp: "store",
      }],
    };
    if (depth) {
      desc.depthStencilAttachment = {
        view: depth.createView(),
        depthClearValue: 1.0,
        depthLoadOp: "clear",
        depthStoreOp: "store",
      };
    }
    webgpu_imports._pass = webgpu_imports._encoder.beginRenderPass(desc);
  },

  jsBeginRenderPassToSurface: (surface_handle, r, g, b, a) => {
    const canvas = get_object(surface_handle);
    const view = canvas.__gpu_ctx.getCurrentTexture().createView();
    webgpu_imports._pass = webgpu_imports._encoder.beginRenderPass({
      colorAttachments: [{
        view,
        clearValue: { r: Number(r), g: Number(g), b: Number(b), a: Number(a) },
        loadOp: "clear",
        storeOp: "store",
      }],
    });
  },

  jsSetPipeline: (pipe_handle) => {
    webgpu_imports._pass.setPipeline(get_object(pipe_handle));
  },

  jsSetVertexBuffer: (slot, buf_handle) => {
    webgpu_imports._pass.setVertexBuffer(Number(slot), get_object(buf_handle));
  },

  jsSetIndexBuffer: (buf_handle) => {
    webgpu_imports._pass.setIndexBuffer(get_object(buf_handle), "uint32");
  },

  jsSetIndexBufferU16: (buf_handle) => {
    webgpu_imports._pass.setIndexBuffer(get_object(buf_handle), "uint16");
  },

  jsSetScissor: (x, y, w, h) => {
    webgpu_imports._pass.setScissorRect(Number(x), Number(y), Number(w), Number(h));
  },

  jsDrawIndexedRange: (index_count, first_index, base_vertex) => {
    webgpu_imports._pass.drawIndexed(
      Number(index_count), 1, Number(first_index), Number(base_vertex), 0,
    );
  },

  jsCreateRGBATexture: (width, height, pixels, byte_count) => {
    const w = Number(width);
    const h = Number(height);
    const tex = gpu_device.createTexture({
      size: { width: w, height: h },
      format: "rgba8unorm",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
    });
    gpu_queue.writeTexture(
      { texture: tex },
      read_u8_array(pixels, byte_count),
      { bytesPerRow: w * 4 },
      { width: w, height: h },
    );
    return add_object(tex);
  },

  jsCreateRawBuffer: (size, usage) => {
    const buf = gpu_device.createBuffer({
      size: Number(size),
      usage: Number(usage) | GPUBufferUsage.COPY_DST,
    });
    return add_object(buf);
  },

  jsCreateImGuiBindGroupLayout: () => {
    return add_object(gpu_device.createBindGroupLayout({
      entries: [
        { binding: 0, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: "float" } },
        { binding: 1, visibility: GPUShaderStage.FRAGMENT, sampler: { type: "filtering" } },
        { binding: 2, visibility: GPUShaderStage.VERTEX, buffer: { type: "uniform" } },
      ],
    }));
  },

  jsCreateImGuiBindGroup: (layout, tex, sampler, uniform) => {
    return add_object(gpu_device.createBindGroup({
      layout: get_object(layout),
      entries: [
        { binding: 0, resource: get_object(tex).createView() },
        { binding: 1, resource: get_object(sampler) },
        { binding: 2, resource: { buffer: get_object(uniform) } },
      ],
    }));
  },

  jsCreateImGuiPipeline: (shader, layout) => {
    return add_object(gpu_device.createRenderPipeline({
      layout: gpu_device.createPipelineLayout({
        bindGroupLayouts: [get_object(layout)],
      }),
      vertex: {
        module: get_object(shader),
        entryPoint: "vs_imgui",
        buffers: [{
          arrayStride: 20,
          attributes: [
            { shaderLocation: 0, offset: 0, format: "float32x2" },
            { shaderLocation: 1, offset: 8, format: "float32x2" },
            { shaderLocation: 2, offset: 16, format: "unorm8x4" },
          ],
        }],
      },
      fragment: {
        module: get_object(shader),
        entryPoint: "fs_imgui",
        targets: [{
          format: "rgba8unorm",
          blend: {
            color: { srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha", operation: "add" },
            alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
          },
        }],
      },
      primitive: { topology: "triangle-list", cullMode: "none" },
      depthStencil: {
        format: "depth24plus",
        depthWriteEnabled: false,
        depthCompare: "always",
      },
    }));
  },

  jsSetBindGroup: (index, bg_handle) => {
    webgpu_imports._pass.setBindGroup(Number(index), get_object(bg_handle));
  },

  jsDrawIndexed: (index_count) => {
    webgpu_imports._pass.drawIndexed(Number(index_count));
  },

  jsDraw: (vertex_count) => {
    webgpu_imports._pass.draw(Number(vertex_count));
  },

  jsEndRenderPass: () => {
    webgpu_imports._pass.end();
    webgpu_imports._pass = null;
  },

  jsSubmit: () => {
    gpu_queue.submit([webgpu_imports._encoder.finish()]);
    webgpu_imports._encoder = null;
  },

  jsCopyTextureToBuffer: (tex_handle, width, height, buf_handle) => {
    const tex = get_object(tex_handle);
    const buf = get_object(buf_handle);
    const encoder = gpu_device.createCommandEncoder();
    const bytesPerRow = Math.ceil((Number(width) * 4) / 256) * 256;
    encoder.copyTextureToBuffer(
      { texture: tex },
      { buffer: buf, bytesPerRow },
      { width: Number(width), height: Number(height) },
    );
    gpu_queue.submit([encoder.finish()]);
  },

  jsMapReadBuffer: async (buf_handle, size, out_ptr) => {
    const buf = get_object(buf_handle);
    await buf.mapAsync(GPUMapMode.READ);
    const src = new Uint8Array(buf.getMappedRange(0, Number(size)));
    write_u8_array(out_ptr, src);
    buf.unmap();
    return Number(size);
  },

  jsDestroyHandle: (handle) => {
    const h = Number(handle);
    const obj = get_object(h);
    if (obj && obj.destroy) obj.destroy();
    object_map[h] = null;
  },

  // libc-style compare used by Jai runtime on WASM64
  memcmp: (a, b, n) => {
    const aa = Number(a), bb = Number(b), nn = Number(n);
    const u8 = new Uint8Array(wasm_memory.buffer);
    for (let i = 0; i < nn; i++) {
      const d = u8[aa + i] - u8[bb + i];
      if (d) return d < 0 ? -1 : 1;
    }
    return 0;
  },

  wasm_debug_break: () => { debugger; },

  // Plain async impl — runtime.js wraps with WebAssembly.Suspending for JSPI.
  jsWaitForFrame: async (fps) => {
    const target_ms = fps > 0 ? 1000 / Number(fps) : 0;
    await new Promise((resolve) => requestAnimationFrame(resolve));
    if (target_ms > 0 && globalThis.__native_last_present_ms > 0) {
      while (performance.now() - globalThis.__native_last_present_ms < target_ms) {
        await new Promise((resolve) => requestAnimationFrame(resolve));
      }
    }
    globalThis.__native_last_present_ms = performance.now();
  },
};

globalThis.__native_last_present_ms = 0;

// Expose for runtime.js merge
globalThis.native_webgpu_imports = webgpu_imports;
