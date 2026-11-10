// WebGPU / WASM backend — same app API as vulkan.jai.
// Present yields via JSPI: jsWaitForFrame (Suspending) + rAF FPS pacing in JS.

WGpuHandle :: u64;

jsWaitForFrame :: (fps: u32) #foreign;
jsPerformanceNowMs :: () -> float64 #foreign;

app_time :: () -> float64 { return jsPerformanceNowMs() / 1000.0; }

WebGpuContext :: struct {
    ok: bool;
    name: string;
    flags: Context_Flags;
    debug_callback: Debug_Callback;
}

Context :: (
    $api: API,
    name := "GPU-RHI",
    flags := Context_Flags.ENABLE_DEBUG,
    debug_callback := DEFAULT_DEBUG_CALLBACK,
) -> WebGpuContext
    #modify { return api == .WEBGPU, "This overload is for API.WEBGPU."; }
{
    ctx: WebGpuContext;
    ctx.name = name;
    ctx.flags = flags;
    ctx.debug_callback = debug_callback;
    ctx.ok = jsWebGpuHasDevice() != 0;
    assert(ctx.ok, "WebGPU device not ready (runtime must requestDevice before main)");
    if (flags & .ENABLE_DEBUG) != 0 {
        ctx.debug_callback(tprint("Context(WEBGPU) name=\"%\" flags=%", name, cast(u32) flags));
    }
    return ctx;
}

Context :: (
    name := "GPU-RHI",
    flags := Context_Flags.ENABLE_DEBUG,
    debug_callback := DEFAULT_DEBUG_CALLBACK,
) -> WebGpuContext {
    return Context(.WEBGPU, name = name, flags = flags, debug_callback = debug_callback);
}

Destroy :: (ctx: *WebGpuContext) {
    ctx.ok = false;
}

WebGpuDevice :: struct {
    vulkan_context: *WebGpuContext; // name kept for require_feature parity (`dev.vulkan_context`)
    name: string;
}

require_feature :: (ctx: *WebGpuContext, f: Feature, loc := #caller_location) {
    if is_vulkan_only_feature(f) {
        assert(false, "feature not supported on WebGPU: % (at %:%)",
            f, loc.fully_pathed_filename, loc.line_number);
    }
    flag := feature_to_flag(f);
    if (ctx.flags & flag) == 0 {
        assert(false, "feature not enabled on Context: % (at %:%)",
            f, loc.fully_pathed_filename, loc.line_number);
    }
}

Device :: (ctx: *WebGpuContext) -> WebGpuDevice {
    assert(ctx && ctx.ok, "Device: invalid context");
    return .{
        vulkan_context = ctx,
        name = "WebGPU",
    };
}

Destroy :: (dev: *WebGpuDevice) {
    dev.vulkan_context = null;
}

// --- Buffers ---

WebGpuBuffer :: struct {
    device: *WebGpuDevice;
    size: s64;
    usage: BUFFER_USAGE;
    locality: DataLocality;
    handle: WGpuHandle;
}

WebGpuIndexBuffer :: struct($IndexT: Type) {
    device: *WebGpuDevice;
    size: s64;
    count: s64;
    locality: DataLocality;
    handle: WGpuHandle;
}

buffer_gpu_usage_bits :: (usage: BUFFER_USAGE) -> u32 {
    // COPY_DST always
    bits: u32 = 0x8;
    if usage == .VERTEX  return bits | 0x20;
    if usage == .INDEX   return bits | 0x10;
    if usage == .UNIFORM return bits | 0x40;
    if usage == .STORAGE return bits | 0x80; // STORAGE
    return bits | 0x40;
}

Buffer :: (dev: *WebGpuDevice, data: [] $T, locality := DataLocality.CREATE_ON_DEVICE) -> WebGpuIndexBuffer(T)
    #modify { return T == IndexU8_t || T == IndexU16_t || T == IndexU32_t; }
{
    assert(dev != null && data.count > 0, "Buffer(index): invalid");
    buf: WebGpuIndexBuffer(T);
    buf.device = dev;
    buf.size = cast(s64) (data.count * size_of(T));
    buf.count = cast(s64) data.count;
    buf.locality = locality;
    buf.handle = jsCreateBuffer(buffer_gpu_usage_bits(.INDEX), xx buf.size, cast(*u8) data.data, xx buf.size);
    return buf;
}

Buffer :: (dev: *WebGpuDevice, data: [] $T, locality := DataLocality.CREATE_ON_DEVICE) -> WebGpuBuffer
    #modify { return T != IndexU8_t && T != IndexU16_t && T != IndexU32_t; }
{
    assert(dev != null && data.count > 0, "Buffer: invalid");
    usage := BUFFER_USAGE.VERTEX;
    #if #exists(T.GPU_USAGE) {
        usage = T.GPU_USAGE;
    }
    buf: WebGpuBuffer;
    buf.device = dev;
    buf.size = cast(s64) (data.count * size_of(T));
    buf.usage = usage;
    buf.locality = locality;
    buf.handle = jsCreateBuffer(buffer_gpu_usage_bits(usage), xx buf.size, cast(*u8) data.data, xx buf.size);
    return buf;
}

Destroy :: (buf: *WebGpuBuffer) {
    if buf.handle { jsDestroyHandle(buf.handle); buf.handle = 0; }
}

Destroy :: (buf: *WebGpuIndexBuffer($IndexT)) {
    if buf.handle { jsDestroyHandle(buf.handle); buf.handle = 0; }
}

Update :: (buf: *WebGpuBuffer, data: [] $T) {
    assert(buf && buf.handle && data.count > 0, "Update(buffer): invalid");
    needed := cast(s64) (data.count * size_of(T));
    assert(needed <= buf.size, "Update(buffer): too large");
    jsWriteBuffer(buf.handle, 0, cast(*u8) data.data, xx needed);
}

Update :: (buf: *WebGpuIndexBuffer($IndexT), data: [] IndexT) {
    assert(buf && buf.handle && data.count > 0, "Update(index): invalid");
    assert(cast(s64) data.count <= buf.count, "Update(index): too many");
    jsWriteBuffer(buf.handle, 0, cast(*u8) data.data, xx (data.count * size_of(IndexT)));
}

// --- Textures ---

WebGpuTexture2D :: struct {
    device: *WebGpuDevice;
    size: Size2D;
    format: TextureFormat;
    locality: DataLocality;
    usage: TextureUsage;
    mips: u32;
    samples: u32;
    handle: WGpuHandle;
}

WebGpuTexture3D :: struct {
    device: *WebGpuDevice;
    size: Size3D;
    format: TextureFormat;
}

WebGpuTextureCube :: struct {
    device: *WebGpuDevice;
    size: SizeCube;
    format: TextureFormat;
}

Texture :: (
    dev: *WebGpuDevice,
    size: Size2D,
    format := TextureFormat.R8G8B8A8_UNORM,
    locality := DataLocality.CREATE_ON_DEVICE,
    usage := TextureUsage.COLOR_ATTACHMENT | TextureUsage.SAMPLED | TextureUsage.COPY_SRC,
    mips: u32 = 1,
    samples: u32 = 1,
) -> WebGpuTexture2D {
    assert(dev != null, "Texture2D: invalid device");
    assert(size.x >= 1 && size.y >= 1, "Texture2D: size >= 1");
    assert(samples == 1, "Texture2D: MSAA not supported on WebGPU path yet");
    assert(mips == 1, "Texture2D: mips > 1 not supported on WebGPU path yet");

    is_depth := (usage & .DEPTH_STENCIL) != 0 || format == .D32_SFLOAT || format == .D24_UNORM_S8_UINT;
    // TEXTURE_BINDING=0x04, STORAGE_BINDING=0x08, RENDER_ATTACHMENT=0x10, COPY_SRC=0x01, COPY_DST=0x02
    gpu_usage: u32 = 0;
    if is_depth {
        gpu_usage = 0x10; // RENDER_ATTACHMENT
    } else {
        if (usage & .STORAGE) != 0 {
            gpu_usage |= 0x08; // STORAGE_BINDING
        }
        if (usage & .COLOR_ATTACHMENT) != 0 {
            gpu_usage |= 0x10; // RENDER_ATTACHMENT
        }
        if (usage & .SAMPLED) != 0 || (usage & .STORAGE) != 0 {
            gpu_usage |= 0x04; // TEXTURE_BINDING (Present samples compute targets)
        }
        if (usage & .COPY_SRC) != 0 then gpu_usage |= 0x01;
        if (usage & .COPY_DST) != 0 || locality == .CREATE_ON_HOST then gpu_usage |= 0x02;
        // Default color target when no explicit bits requested.
        if gpu_usage == 0 {
            gpu_usage = 0x10 | 0x04 | 0x01;
        }
    }

    tex: WebGpuTexture2D;
    tex.device = dev;
    tex.size = size;
    tex.format = format;
    tex.locality = locality;
    tex.usage = usage;
    tex.mips = mips;
    tex.samples = samples;
    tex.handle = jsCreateTexture(size.x, size.y, gpu_usage, cast(u32) (ifx is_depth then 1 else 0));
    return tex;
}

Texture :: (
    dev: *WebGpuDevice,
    size: Size3D,
    format := TextureFormat.R8G8B8A8_UNORM,
    locality := DataLocality.CREATE_ON_DEVICE,
    usage := TextureUsage.SAMPLED | TextureUsage.COPY_DST,
    mips: u32 = 1,
) -> WebGpuTexture3D {
    _ := locality; _ := usage; _ := mips;
    not_implemented("Texture3D (WebGPU)");
    return .{device = dev, size = size, format = format};
}

Texture :: (
    dev: *WebGpuDevice,
    size: SizeCube,
    format := TextureFormat.R8G8B8A8_UNORM,
    locality := DataLocality.CREATE_ON_DEVICE,
    usage := TextureUsage.SAMPLED | TextureUsage.COPY_DST,
    mips: u32 = 1,
) -> WebGpuTextureCube {
    _ := locality; _ := usage; _ := mips;
    not_implemented("TextureCube (WebGPU)");
    return .{device = dev, size = size, format = format};
}

Destroy :: (tex: *WebGpuTexture2D) {
    if tex.handle { jsDestroyHandle(tex.handle); tex.handle = 0; }
}

Destroy :: (tex: *WebGpuTexture3D) { tex.* = .{}; }
Destroy :: (tex: *WebGpuTextureCube) { tex.* = .{}; }

Get :: (tex: *WebGpuTexture2D) -> [] u8 {
    assert(tex && tex.handle, "Get: invalid texture");
    byte_count := cast(s64) (tex.size.x * tex.size.y * 4);
    out, _ := NewArray(byte_count, u8);
    // Optional: jsReadTexture — stub zeros for now if missing.
    return out;
}

Update :: (tex: *WebGpuTexture2D, pixels: [] u8) {
    assert(tex && tex.handle, "Update(texture2d): invalid");
    expected := cast(s64) (tex.size.x * tex.size.y * 4);
    assert(pixels.count >= expected, "Update(texture2d): buffer too small");
    jsWriteTexture(tex.handle, tex.size.x, tex.size.y, pixels.data, xx expected);
}

Update :: (tex: *WebGpuTexture2D, new_size: Size2D) {
    assert(tex && tex.device, "Update(resize): invalid");
    assert(new_size.x > 0 && new_size.y > 0, "Update(resize): bad size");
    if tex.size.x == new_size.x && tex.size.y == new_size.y return;
    if tex.handle { jsDestroyHandle(tex.handle); tex.handle = 0; }
    tex.size = new_size;
    is_depth := (tex.usage & .DEPTH_STENCIL) != 0;
    gpu_usage: u32 = 0x10;
    if !is_depth gpu_usage |= 0x04 | 0x01;
    tex.handle = jsCreateTexture(new_size.x, new_size.y, gpu_usage, cast(u32) (ifx is_depth then 1 else 0));
}

// --- FrameBuffer ---
// $has_depth = whether the render pass includes a depth attachment.

WebGpuFrameBuffer :: struct($color_count: s64, $has_depth: bool) {
    device: *WebGpuDevice;
    color_textures: [color_count] *WebGpuTexture2D;
    #if has_depth {
        depth_texture: *WebGpuTexture2D;
        _owned_depth: WebGpuTexture2D;
        owns_depth: bool;
    }
    clear_color: Color4;
}

// FrameBuffer is returned by value; re-seat owned depth to the live struct before use.
framebuffer_depth :: (fb: *WebGpuFrameBuffer($N, $has_depth)) -> *WebGpuTexture2D {
    #if has_depth {
        if fb.owns_depth {
            fb.depth_texture = *fb._owned_depth;
        }
        return fb.depth_texture;
    }
    #if !has_depth return null;
}

FrameBuffer :: (
    textures: [$N] *WebGpuTexture2D,
    clear_color := DEFAULT_CLEAR_COLOR,
    $has_depth := true,
) -> WebGpuFrameBuffer(N, has_depth) {
    assert(N >= 1 && N <= 2, "FrameBuffer: need 1..2 color textures, got %", N);
    for textures assert(it != null, "FrameBuffer: null color texture");

    fb: WebGpuFrameBuffer(N, has_depth);
    fb.device = textures[0].device;
    fb.clear_color = clear_color;
    for i: 0..N-1 {
        fb.color_textures[i] = textures[i];
    }
    #if has_depth {
        fb.owns_depth = true;
        fb._owned_depth = Texture(textures[0].device, textures[0].size, format = .D32_SFLOAT, usage = .DEPTH_STENCIL);
        fb.depth_texture = *fb._owned_depth;
    }
    return fb;
}

FrameBuffer :: (
    textures: [$N] *WebGpuTexture2D,
    clear_color := DEFAULT_CLEAR_COLOR,
    depth_texture: *WebGpuTexture2D,
) -> WebGpuFrameBuffer(N, true) {
    assert(depth_texture != null, "FrameBuffer: depth_texture required");
    assert(N >= 1 && N <= 2, "FrameBuffer: need 1..2 color textures, got %", N);
    for textures assert(it != null, "FrameBuffer: null color texture");

    fb: WebGpuFrameBuffer(N, true);
    fb.device = textures[0].device;
    fb.clear_color = clear_color;
    for i: 0..N-1 {
        fb.color_textures[i] = textures[i];
    }
    fb.depth_texture = depth_texture;
    fb.owns_depth = false;
    return fb;
}

// Single-color ergonomic wrappers. MRT: FrameBuffer(.[*a, *b], …).
FrameBuffer :: (t0: *WebGpuTexture2D, clear_color := DEFAULT_CLEAR_COLOR, $has_depth := true) -> WebGpuFrameBuffer(1, has_depth) {
    return FrameBuffer(.[t0], clear_color, has_depth);
}

FrameBuffer :: (t0: *WebGpuTexture2D, clear_color := DEFAULT_CLEAR_COLOR, depth_texture: *WebGpuTexture2D) -> WebGpuFrameBuffer(1, true) {
    return FrameBuffer(.[t0], clear_color, depth_texture);
}

Destroy :: (fb: *WebGpuFrameBuffer($N, $has_depth)) {
    #if has_depth {
        if fb.owns_depth {
            Destroy(*fb._owned_depth);
            fb.depth_texture = null;
        }
    }
}

Update :: (fb: *WebGpuFrameBuffer($N, $has_depth), new_size: Size2D) {
    assert(fb != null, "Update(framebuffer): invalid");
    assert(new_size.x > 0 && new_size.y > 0, "Update(framebuffer): bad size");
    for fb.color_textures {
        assert(it != null, "Update(framebuffer): null color");
        Update(it, new_size);
    }
    #if has_depth {
        depth := framebuffer_depth(fb);
        assert(depth != null, "Update(framebuffer): null depth");
        Update(depth, new_size);
    }
}

// --- Shader / Spawn ---
// Host-bake WGSL via #run,host (File/POSIX cannot import under WASM target OS).

WEBGPU_UNLIT_MEMBERS :: #run,host -> string {
    File :: #import "File";
    Process :: #import "Process";
    #import "Basic";
    #import "String";

    // Struct-return style — slangc WGSL rejects entry-point `out`/`ptr<function,…>` params.
    slang := #string END
struct Vertex_t {
    float3 Pos;
    float3 Color;
    float3 Normal;
};

struct VSOutput {
    float4 Pos : SV_Position;
    float3 Color : COLOR;
};

[shader("vertex")]
VSOutput vs_main(Vertex_t v, uniform float4x4 MVP) {
    VSOutput o;
    o.Color = v.Color;
    o.Pos = mul(MVP, float4(v.Pos, 1.0));
    return o;
}

[shader("fragment")]
float4 fs_main(VSOutput input) : SV_Target {
    return float4(input.Color, 1.0);
}
END;
    File.make_directory_if_it_does_not_exist(".bin/.build", recursive = true);
    assert(File.write_entire_file(".bin/.build/webgpu_unlit.slang", slang), "write unlit slang");
    result, stdout, stderr := Process.run_command(
        "env", "-u", "LD_LIBRARY_PATH",
        "slangc", ".bin/.build/webgpu_unlit.slang",
        "-target", "wgsl",
        "-matrix-layout-row-major",
        "-entry", "vs_main", "-stage", "vertex",
        "-entry", "fs_main", "-stage", "fragment",
        "-o", ".bin/.build/webgpu_unlit.wgsl",
        capture_and_return_output = true,
    );
    assert(result.type != .FAILED_TO_LAUNCH, "slangc not found on PATH");
    assert(result.exit_code == 0, "slangc→wgsl failed:\n%\n%", stdout, stderr);
    data, ok := File.read_entire_file(".bin/.build/webgpu_unlit.wgsl");
    assert(ok && data.count > 0, "read unlit wgsl failed");

    builder: String_Builder;
    print_to_builder(*builder, "Vertex_t :: struct {\n");
    print_to_builder(*builder, "    GPU_USAGE :: BUFFER_USAGE.VERTEX;\n");
    print_to_builder(*builder, "    Pos: Vector3;\n");
    print_to_builder(*builder, "    Color: Vector3;\n");
    print_to_builder(*builder, "    Normal: Vector3;\n");
    print_to_builder(*builder, "};\n\n");
    print_to_builder(*builder, "MVP :: UniformDefinition.{\n");
    print_to_builder(*builder, "    name = \"MVP\", type = type_of(Matrix4), offset = 0,\n");
    print_to_builder(*builder, "    set = 0, binding = 0, stage_flags = 1,\n");
    print_to_builder(*builder, "};\n");
    print_to_builder(*builder, "vs_entry :: \"vs_main\";\n");
    print_to_builder(*builder, "fs_entry :: \"fs_main\";\n");
    print_to_builder(*builder, "cs_entry :: \"\";\n");
    print_to_builder(*builder, "is_compute :: false;\n");
    print_to_builder(*builder, "push_constant_bytes :: 64;\n\n");
    print_to_builder(*builder, "spirv_raw :: u8.[\n");
    for i: 0..data.count-1 {
        print_to_builder(*builder, "%,", data[i]);
        if (i + 1) % 16 == 0 then print_to_builder(*builder, "\n");
    }
    print_to_builder(*builder, "\n];\n");
    return builder_to_string(*builder);
}

WEBGPU_LIT_MEMBERS :: #run,host -> string {
    File :: #import "File";
    Process :: #import "Process";
    #import "Basic";
    #import "String";

    slang := #string END
struct Vertex_t {
    float3 Pos;
    float3 Color;
    float3 Normal;
};

struct Frame {
    float4x4 MVP;
    float3 LightDir;
    float Ambient;
};

struct VSOutput {
    float4 Pos : SV_Position;
    float3 Color : COLOR;
    float3 Nrm : NORMAL;
};

[shader("vertex")]
VSOutput vs_main(Vertex_t v, uniform Frame frame) {
    VSOutput o;
    o.Pos = mul(frame.MVP, float4(v.Pos, 1.0));
    o.Color = v.Color;
    o.Nrm = v.Normal;
    return o;
}

[shader("fragment")]
float4 fs_main(VSOutput input, uniform Frame frame) : SV_Target {
    float ndotl = saturate(dot(normalize(input.Nrm), normalize(-frame.LightDir)));
    float3 lit = input.Color * (frame.Ambient + (1.0 - frame.Ambient) * ndotl);
    return float4(lit, 1.0);
}
END;
    File.make_directory_if_it_does_not_exist(".bin/.build", recursive = true);
    assert(File.write_entire_file(".bin/.build/webgpu_lit.slang", slang), "write lit slang");
    result, stdout, stderr := Process.run_command(
        "env", "-u", "LD_LIBRARY_PATH",
        "slangc", ".bin/.build/webgpu_lit.slang",
        "-target", "wgsl",
        "-matrix-layout-row-major",
        "-entry", "vs_main", "-stage", "vertex",
        "-entry", "fs_main", "-stage", "fragment",
        "-o", ".bin/.build/webgpu_lit.wgsl",
        capture_and_return_output = true,
    );
    assert(result.type != .FAILED_TO_LAUNCH, "slangc not found on PATH");
    assert(result.exit_code == 0, "slangc→wgsl failed:\n%\n%", stdout, stderr);
    data, ok := File.read_entire_file(".bin/.build/webgpu_lit.wgsl");
    assert(ok && data.count > 0, "read lit wgsl failed");

    builder: String_Builder;
    print_to_builder(*builder, "Vertex_t :: struct {\n");
    print_to_builder(*builder, "    GPU_USAGE :: BUFFER_USAGE.VERTEX;\n");
    print_to_builder(*builder, "    Pos: Vector3;\n");
    print_to_builder(*builder, "    Color: Vector3;\n");
    print_to_builder(*builder, "    Normal: Vector3;\n");
    print_to_builder(*builder, "};\n\n");
    print_to_builder(*builder, "MVP :: UniformDefinition.{\n");
    print_to_builder(*builder, "    name = \"MVP\", type = type_of(Matrix4), offset = 0,\n");
    print_to_builder(*builder, "    set = 0, binding = 0, stage_flags = 1,\n");
    print_to_builder(*builder, "};\n");
    print_to_builder(*builder, "LightDir :: UniformDefinition.{\n");
    print_to_builder(*builder, "    name = \"LightDir\", type = type_of(Vector3), offset = 64,\n");
    print_to_builder(*builder, "    set = 0, binding = 0, stage_flags = 2,\n");
    print_to_builder(*builder, "};\n");
    print_to_builder(*builder, "Ambient :: UniformDefinition.{\n");
    print_to_builder(*builder, "    name = \"Ambient\", type = type_of(float), offset = 76,\n");
    print_to_builder(*builder, "    set = 0, binding = 0, stage_flags = 2,\n");
    print_to_builder(*builder, "};\n");
    print_to_builder(*builder, "vs_entry :: \"vs_main\";\n");
    print_to_builder(*builder, "fs_entry :: \"fs_main\";\n");
    print_to_builder(*builder, "cs_entry :: \"\";\n");
    print_to_builder(*builder, "is_compute :: false;\n");
    print_to_builder(*builder, "push_constant_bytes :: 80;\n\n");
    print_to_builder(*builder, "spirv_raw :: u8.[\n");
    for i: 0..data.count-1 {
        print_to_builder(*builder, "%,", data[i]);
        if (i + 1) % 16 == 0 then print_to_builder(*builder, "\n");
    }
    print_to_builder(*builder, "\n];\n");
    return builder_to_string(*builder);
}

WEBGPU_CORNELL_COMPUTE_MEMBERS :: #run,host -> string {
    File :: #import "File";
    Process :: #import "Process";
    #import "Basic";
    #import "String";

    slang := #string END
// CORNELL_COMPUTE
[[format("rgba8")]]
RWTexture2D<float4> Output;

bool hit_aabb(float3 ro, float3 rd, float3 bmin, float3 bmax, out float tHit, out float3 nrm) {
    float3 inv = 1.0 / rd;
    float3 t0 = (bmin - ro) * inv;
    float3 t1 = (bmax - ro) * inv;
    float3 tminv = min(t0, t1);
    float3 tmaxv = max(t0, t1);
    float tmin = max(max(tminv.x, tminv.y), tminv.z);
    float tmax = min(min(tmaxv.x, tmaxv.y), tmaxv.z);
    if (tmax < max(tmin, 0.0)) {
        tHit = 0.0;
        nrm = float3(0, 1, 0);
        return false;
    }
    tHit = tmin > 0.0 ? tmin : tmax;
    if (tHit <= 0.0) {
        nrm = float3(0, 1, 0);
        return false;
    }
    float3 p = ro + rd * tHit;
    float3 c = (bmin + bmax) * 0.5;
    float3 d = (p - c) / max(bmax - bmin, float3(1e-4, 1e-4, 1e-4));
    float3 a = abs(d);
    if (a.x > a.y && a.x > a.z) nrm = float3(sign(d.x), 0, 0);
    else if (a.y > a.z) nrm = float3(0, sign(d.y), 0);
    else nrm = float3(0, 0, sign(d.z));
    return true;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void cs_main(
    uint3 id : SV_DispatchThreadID,
    uniform float3 CameraPos,
    uniform float3 CameraFwd
) {
    const uint W = 800;
    const uint H = 600;
    if (id.x >= W || id.y >= H) return;

    float2 uv = (float2(id.xy) + 0.5) / float2(W, H);
    uv = uv * 2.0 - 1.0;
    uv.y = -uv.y;
    float aspect = float(W) / float(H);

    float3 ro = CameraPos;
    float3 forward = normalize(CameraFwd);
    float3 worldUp = float3(0.0, 1.0, 0.0);
    float3 right = normalize(cross(forward, worldUp));
    if (dot(right, right) < 1e-6) {
        right = normalize(cross(forward, float3(0.0, 0.0, 1.0)));
    }
    float3 up = cross(right, forward);
    float3 rd = normalize(forward + right * (uv.x * aspect * 0.7) + up * (uv.y * 0.7));

    float3 lightPos = float3(0.0, 0.92, 0.0);
    float bestT = 1e9;
    float3 albedo = float3(0.02, 0.02, 0.03);
    float3 nrm = float3(0, 1, 0);
    float emissive = 0.0;

    float t; float3 n;
    if (hit_aabb(ro, rd, float3(-1,-1.02,-1), float3(1,-0.98,1), t, n) && t < bestT) {
        bestT = t; albedo = float3(0.75,0.75,0.75); nrm = n; emissive = 0;
    }
    if (hit_aabb(ro, rd, float3(-1,0.98,-1), float3(1,1.02,1), t, n) && t < bestT) {
        bestT = t; albedo = float3(0.75,0.75,0.75); nrm = n; emissive = 0;
    }
    if (hit_aabb(ro, rd, float3(-1,-1,-1.02), float3(1,1,-0.98), t, n) && t < bestT) {
        bestT = t; albedo = float3(0.75,0.75,0.75); nrm = n; emissive = 0;
    }
    if (hit_aabb(ro, rd, float3(-1.02,-1,-1), float3(-0.98,1,1), t, n) && t < bestT) {
        bestT = t; albedo = float3(0.75,0.12,0.12); nrm = n; emissive = 0;
    }
    if (hit_aabb(ro, rd, float3(0.98,-1,-1), float3(1.02,1,1), t, n) && t < bestT) {
        bestT = t; albedo = float3(0.12,0.55,0.12); nrm = n; emissive = 0;
    }
    if (hit_aabb(ro, rd, float3(-0.65,-1.0,-0.55), float3(-0.20,0.15,-0.05), t, n) && t < bestT) {
        bestT = t; albedo = float3(0.85,0.85,0.7); nrm = n; emissive = 0;
    }
    if (hit_aabb(ro, rd, float3(0.10,-1.0,-0.10), float3(0.55,-0.35,0.40), t, n) && t < bestT) {
        bestT = t; albedo = float3(0.7,0.85,0.85); nrm = n; emissive = 0;
    }
    if (hit_aabb(ro, rd, float3(-0.35,0.97,-0.25), float3(0.35,0.999,0.25), t, n) && t < bestT) {
        bestT = t; albedo = float3(1,1,0.9); nrm = n; emissive = 8.0;
    }

    float3 col = albedo * emissive;
    if (emissive < 0.01 && bestT < 1e8) {
        float3 p = ro + rd * bestT;
        float3 l = normalize(lightPos - p);
        float ndotl = saturate(dot(normalize(nrm), l));
        float dist = length(lightPos - p);
        float atten = 1.0 / (0.4 + dist * dist);
        col = albedo * (0.08 + 2.5 * ndotl * atten);
    }
    Output[id.xy] = float4(col, 1.0);
}
END;
    File.make_directory_if_it_does_not_exist(".bin/.build", recursive = true);
    assert(File.write_entire_file(".bin/.build/webgpu_cornell_cs.slang", slang), "write cornell cs slang");
    result, stdout, stderr := Process.run_command(
        "env", "-u", "LD_LIBRARY_PATH",
        "slangc", ".bin/.build/webgpu_cornell_cs.slang",
        "-target", "wgsl",
        "-matrix-layout-row-major",
        "-entry", "cs_main", "-stage", "compute",
        "-o", ".bin/.build/webgpu_cornell_cs.wgsl",
        capture_and_return_output = true,
    );
    assert(result.type != .FAILED_TO_LAUNCH, "slangc not found on PATH");
    assert(result.exit_code == 0, "slangc→wgsl cornell compute failed:\n%\n%", stdout, stderr);
    data, ok := File.read_entire_file(".bin/.build/webgpu_cornell_cs.wgsl");
    assert(ok && data.count > 0, "read cornell cs wgsl failed");

    builder: String_Builder;
    print_to_builder(*builder, "Vertex_t :: struct {\n");
    print_to_builder(*builder, "    GPU_USAGE :: BUFFER_USAGE.VERTEX;\n");
    print_to_builder(*builder, "};\n\n");
    print_to_builder(*builder, "CameraPos :: UniformDefinition.{\n");
    print_to_builder(*builder, "    name = \"CameraPos\", type = type_of(Vector3), offset = 0,\n");
    print_to_builder(*builder, "    set = 0, binding = 1, stage_flags = 32,\n");
    print_to_builder(*builder, "};\n");
    print_to_builder(*builder, "CameraFwd :: UniformDefinition.{\n");
    print_to_builder(*builder, "    name = \"CameraFwd\", type = type_of(Vector3), offset = 16,\n");
    print_to_builder(*builder, "    set = 0, binding = 1, stage_flags = 32,\n");
    print_to_builder(*builder, "};\n");
    print_to_builder(*builder, "vs_entry :: \"\";\n");
    print_to_builder(*builder, "fs_entry :: \"\";\n");
    print_to_builder(*builder, "cs_entry :: \"cs_main\";\n");
    print_to_builder(*builder, "is_compute :: true;\n");
    print_to_builder(*builder, "push_constant_bytes :: 32;\n\n");
    print_to_builder(*builder, "spirv_raw :: u8.[\n");
    for i: 0..data.count-1 {
        print_to_builder(*builder, "%,", data[i]);
        if (i + 1) % 16 == 0 then print_to_builder(*builder, "\n");
    }
    print_to_builder(*builder, "\n];\n");
    return builder_to_string(*builder);
}

WebGpuShader :: struct ($source: string, $stages: [] string) {
    device: *WebGpuDevice;
    module_handle: WGpuHandle;
    pipeline: WGpuHandle;
    uniform_layout: WGpuHandle;
    uniform_buffer: WGpuHandle;
    bind_group: WGpuHandle;
    storage_layout: WGpuHandle;
    #insert -> string {
        _ := stages;
        if contains(source, "CORNELL_COMPUTE") {
            return WEBGPU_CORNELL_COMPUTE_MEMBERS;
        }
        if contains(source, "LightDir") || contains(source, "Ambient") {
            return WEBGPU_LIT_MEMBERS;
        }
        // Default graphics path (UNLIT_COLOR_SLANG and similar).
        if contains(source, "vs_main") && contains(source, "fs_main") {
            return WEBGPU_UNLIT_MEMBERS;
        }
        assert(false, "WebGPU: no host-baked WGSL for this shader source");
        return "";
    }
}

Spawn :: (dev: *WebGpuDevice, $source: string, $stages: [] string) -> WebGpuShader(source, stages) {
    assert(dev != null, "Spawn: invalid device");
    Shader_t :: WebGpuShader(source, stages);
    shdr: Shader_t;
    shdr.device = dev;
    assert(Shader_t.spirv_raw.count > 0, "Spawn: empty WGSL");

    shdr.module_handle = jsCreateShaderModule(Shader_t.spirv_raw.data, xx Shader_t.spirv_raw.count);

    #if Shader_t.is_compute {
        if Shader_t.push_constant_bytes > 0 {
            shdr.storage_layout = jsCreateBindGroupLayoutStorageTextureUniform();
            shdr.uniform_buffer = jsCreateUniformBuffer(Shader_t.push_constant_bytes);
        } else {
            shdr.storage_layout = jsCreateBindGroupLayoutStorageTexture();
        }
        shdr.pipeline = jsCreateComputePipeline(
            shdr.module_handle,
            Shader_t.cs_entry.data, xx Shader_t.cs_entry.count,
            shdr.storage_layout,
        );
    } else {
        shdr.uniform_layout = jsCreateBindGroupLayoutUniform();
        shdr.uniform_buffer = jsCreateUniformBuffer(Shader_t.push_constant_bytes);
        shdr.bind_group = jsCreateBindGroupUniform(shdr.uniform_layout, shdr.uniform_buffer);

        stride := cast(u32) size_of(Shader_t.Vertex_t);
        shdr.pipeline = jsCreateRenderPipeline(
            shdr.module_handle, Shader_t.vs_entry.data, xx Shader_t.vs_entry.count,
            shdr.module_handle, Shader_t.fs_entry.data, xx Shader_t.fs_entry.count,
            stride, 1,
            0, 1,
            shdr.uniform_layout,
        );
    }
    return shdr;
}

Destroy :: (shdr: *WebGpuShader($source, $stages)) {
    if shdr.bind_group { jsDestroyHandle(shdr.bind_group); }
    if shdr.uniform_buffer { jsDestroyHandle(shdr.uniform_buffer); }
    if shdr.uniform_layout { jsDestroyHandle(shdr.uniform_layout); }
    if shdr.storage_layout { jsDestroyHandle(shdr.storage_layout); }
    if shdr.pipeline { jsDestroyHandle(shdr.pipeline); }
    if shdr.module_handle { jsDestroyHandle(shdr.module_handle); }
}

// --- Queues / Pass ---

WebGpuGraphicsQueue :: struct {
    device: *WebGpuDevice;
    bound_framebuffer: *WebGpuFrameBuffer(1, false);
    bound_fb_any: *void;
    color_count: s64;
    index_count: u32;
    vertex_handle: WGpuHandle;
    index_handle: WGpuHandle;
    recording: bool;
    index_is_u16: bool;
}

WebGpuComputeQueue :: struct {
    device: *WebGpuDevice;
    recording: bool;
    storage_bound: bool;
    bound_pipeline: WGpuHandle;
    bound_bind_group: WGpuHandle;
    storage_layout: WGpuHandle;
}

WebGpuCopyQueue :: struct {
    device: *WebGpuDevice;
}

WebGpuGraphicsPass :: struct($source: string, $stages: [] string) {
    queue: *WebGpuGraphicsQueue;
    shader: *WebGpuShader(source, stages);
}

WebGpuComputePass :: struct($source: string, $stages: [] string) {
    queue: *WebGpuComputeQueue;
    shader: *WebGpuShader(source, stages);
}

Queue :: (dev: *WebGpuDevice, $type: QUEUE_TYPE) -> WebGpuGraphicsQueue
    #modify { return type == .GRAPHICS; }
{
    assert(dev != null, "Queue(GRAPHICS): invalid device");
    return .{device = dev, recording = false, index_count = 0, color_count = 1};
}

Queue :: (dev: *WebGpuDevice, $type: QUEUE_TYPE) -> WebGpuComputeQueue
    #modify { return type == .COMPUTE; }
{
    assert(dev != null, "Queue(COMPUTE): invalid device");
    return .{
        device = dev,
        recording = false,
        storage_bound = false,
        bound_pipeline = 0,
        bound_bind_group = 0,
        storage_layout = 0,
    };
}

Queue :: (dev: *WebGpuDevice, $type: QUEUE_TYPE) -> WebGpuCopyQueue
    #modify { return type == .COPY; }
{
    _ := dev;
    not_implemented("Queue(COPY) WebGPU");
    return .{};
}

Bind :: (q: *WebGpuGraphicsQueue, frm_buf: *WebGpuFrameBuffer($N, $has_depth)) {
    assert(q && frm_buf && frm_buf.color_textures[0], "Bind: invalid");
    q.bound_fb_any = cast(*void) frm_buf;
    q.color_count = N;
    q.index_count = 0;
    q.vertex_handle = 0;
    q.index_handle = 0;
    if !q.recording {
        jsBeginCommands();
        q.recording = true;
    }
    c := frm_buf.clear_color;
    depth_handle: WGpuHandle = 0;
    #if has_depth {
        depth := framebuffer_depth(frm_buf);
        assert(depth != null, "Bind: null depth");
        depth_handle = depth.handle;
    }
    jsBeginRenderPassToTexture(
        frm_buf.color_textures[0].handle, depth_handle,
        c.r, c.g, c.b, c.a,
    );
}

Pass :: (q: *WebGpuGraphicsQueue, shdr: *WebGpuShader($source, $stages)) -> [1] WebGpuGraphicsPass(source, stages) {
    assert(q && shdr, "Pass: invalid");
    assert(q.recording, "Pass: Bind FrameBuffer first");
    jsSetPipeline(shdr.pipeline);
    return .[.{queue = q, shader = shdr}];
}

Pass :: (q: *WebGpuComputeQueue, shdr: *WebGpuShader($source, $stages)) -> [1] WebGpuComputePass(source, stages) {
    assert(q && shdr, "Pass(Compute): invalid");
    assert(shdr.pipeline != 0, "Pass(Compute): no pipeline");
    assert(shdr.storage_layout != 0, "Pass(Compute): no storage layout");
    if !q.recording {
        jsBeginCommands();
        q.recording = true;
    }
    jsBeginComputePass();
    jsSetPipeline(shdr.pipeline);
    q.bound_pipeline = shdr.pipeline;
    q.storage_layout = shdr.storage_layout;
    q.storage_bound = false;
    if q.bound_bind_group {
        jsDestroyHandle(q.bound_bind_group);
        q.bound_bind_group = 0;
    }
    return .[.{queue = q, shader = shdr}];
}

Set :: (buf: *WebGpuBuffer) #expand { Set(`it, buf); }
Set :: (buf: *WebGpuIndexBuffer($IndexT)) #expand { Set(`it, buf); }
Set :: (tex: *WebGpuTexture2D) #expand { Set(`it, tex); }

Set :: (pass: WebGpuGraphicsPass($source, $stages), buf: *WebGpuBuffer) {
    q := pass.queue;
    if buf.usage == .VERTEX {
        q.vertex_handle = buf.handle;
        jsSetVertexBuffer(0, buf.handle);
    } else {
        assert(false, "Set(buffer): expected VERTEX");
    }
}

Set :: (pass: WebGpuGraphicsPass($source, $stages), buf: *WebGpuIndexBuffer($IndexT)) {
    q := pass.queue;
    q.index_handle = buf.handle;
    q.index_count = cast(u32) buf.count;
    q.index_is_u16 = size_of(IndexT) == 2;
    jsSetIndexBuffer(buf.handle);
}

Set :: (def: UniformDefinition, val: $T) #expand { Set(`it, def, val); }

Set :: (pass: WebGpuGraphicsPass($source, $stages), def: UniformDefinition, val: $T) {
    shdr := pass.shader;
    // As-is upload (row-major bake via slangc -matrix-layout-row-major).
    jsWriteBuffer(shdr.uniform_buffer, def.offset, cast(*u8) *val, xx size_of(T));
    jsSetBindGroup(0, shdr.bind_group);
}

Set :: (pass: WebGpuComputePass($source, $stages), tex: *WebGpuTexture2D) {
    assert(tex && tex.handle, "Set(compute texture): invalid");
    assert((tex.usage & .STORAGE) != 0, "Set(compute): texture needs STORAGE usage");
    q := pass.queue;
    shdr := pass.shader;
    if q.bound_bind_group {
        jsDestroyHandle(q.bound_bind_group);
        q.bound_bind_group = 0;
    }
    if shdr.uniform_buffer {
        q.bound_bind_group = jsCreateBindGroupStorageTextureUniform(
            q.storage_layout, tex.handle, shdr.uniform_buffer,
        );
    } else {
        q.bound_bind_group = jsCreateBindGroupStorageTexture(q.storage_layout, tex.handle);
    }
    jsSetBindGroup(0, q.bound_bind_group);
    q.storage_bound = true;
}

Set :: (pass: WebGpuComputePass($source, $stages), def: UniformDefinition, val: $T) {
    shdr := pass.shader;
    assert(shdr.uniform_buffer != 0, "Set(compute uniform): no uniform buffer on shader");
    jsWriteBuffer(shdr.uniform_buffer, def.offset, cast(*u8) *val, xx size_of(T));
}

Set :: (pass: WebGpuComputePass($source, $stages), buf: *WebGpuBuffer) {
    _ := pass; _ := buf;
    not_implemented("WebGPU Set(compute STORAGE buffer)");
}

Record :: () #expand { Record(`it); }

Record :: (pass: WebGpuGraphicsPass($source, $stages)) {
    q := pass.queue;
    assert(q.index_count > 0, "Record: no index buffer");
    jsDrawIndexed(q.index_count);
}

Submit :: (q: *WebGpuGraphicsQueue, wait := true) {
    _ := wait;
    if q.recording {
        jsEndRenderPass();
        jsSubmit();
        q.recording = false;
    }
}

Submit :: (q: *WebGpuComputeQueue, groups_x: u32, groups_y: u32 = 1, groups_z: u32 = 1, wait := true) {
    _ := wait;
    assert(q.recording, "Submit(Compute): Pass first");
    assert(q.storage_bound, "Submit(Compute): Set a STORAGE texture first");
    assert(groups_x >= 1 && groups_y >= 1 && groups_z >= 1, "Submit(Compute): groups >= 1");
    jsDispatch(groups_x, groups_y, groups_z);
    jsEndComputePass();
    jsSubmit();
    q.recording = false;
    if q.bound_bind_group {
        jsDestroyHandle(q.bound_bind_group);
        q.bound_bind_group = 0;
    }
}

// --- Surface / Present ---

WebGpuSurface :: struct ($Window_t: Type) {
    device: *WebGpuDevice;
    window: *Window_t;
    width: u32;
    height: u32;
    last_time: float64;
    delta_time: float64;
    canvas_handle: WGpuHandle;
    present_pipeline: WGpuHandle;
    sample_layout: WGpuHandle;
    sample_bind_group: WGpuHandle;
    sampler: WGpuHandle;
    present_shader: WGpuHandle;
}

Surface :: (dev: *WebGpuDevice, window: *JsCanvasWindow) -> WebGpuSurface(JsCanvasWindow) {
    assert(dev && window && window.alive, "Surface: invalid args");
    require_feature(dev.vulkan_context, .SURFACE);

    srf: WebGpuSurface(JsCanvasWindow);
    srf.device = dev;
    srf.window = window;
    srf.width = window.width;
    srf.height = window.height;
    srf.last_time = app_time();
    srf.canvas_handle = jsCreateSurface(window.name_id.data, xx window.name_id.count);
    jsConfigureSurface(srf.canvas_handle, window.width, window.height);

    srf.sample_layout = jsCreateBindGroupLayoutSampled();
    srf.sampler = jsCreateSampler();

    // Note: some WebGPU builds still parse struct members with `,` (pre-semicolon WGSL).
    present_wgsl := #string END
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var tex: texture_2d<f32>;
struct VSOut {
  @builtin(position) pos: vec4f,
  @location(0) uv: vec2f,
}
@vertex fn vs_fullscreen(@builtin(vertex_index) vid: u32) -> VSOut {
  var o: VSOut;
  let x = f32(i32(vid & 1u) * 4 - 1);
  let y = f32(i32(vid >> 1u) * 4 - 1);
  o.pos = vec4f(x, y, 0.0, 1.0);
  o.uv = vec2f((x + 1.0) * 0.5, 1.0 - (y + 1.0) * 0.5);
  return o;
}
@fragment fn fs_fullscreen(@location(0) uv: vec2f) -> @location(0) vec4f {
  return textureSample(tex, samp, uv);
}
END;
    srf.present_shader = jsCreateShaderModule(present_wgsl.data, xx present_wgsl.count);
    format_buf: [64] u8;
    n := jsGetPreferredSwapFormat(format_buf.data, 64);
    srf.present_pipeline = jsCreatePresentPipeline(
        srf.present_shader, srf.present_shader,
        srf.sample_layout,
        format_buf.data, n,
    );
    return srf;
}

Surface :: (dev: *WebGpuDevice, window: *$Window_t) -> WebGpuSurface(Window_t)
    #modify { return Window_t != JsCanvasWindow; }
{
    _ := window;
    assert(dev && dev.vulkan_context, "Surface: invalid device");
    require_feature(dev.vulkan_context, .SURFACE);
    assert(false, "Surface: no specialization for %", Window_t);
    return .{};
}

Present :: (srf: *WebGpuSurface($Window_t), tex: *WebGpuTexture2D, fps: u32 = 60) {
    assert(srf && srf.canvas_handle && tex && tex.handle, "Present: invalid");
    assert(srf.window && srf.window.alive, "Present: window gone");

    _, _, win_w, win_h, ok := GetDimensions(srf.window);
    if ok && win_w > 0 && win_h > 0 {
        if win_w != srf.width || win_h != srf.height {
            srf.width = win_w;
            srf.height = win_h;
            jsConfigureSurface(srf.canvas_handle, win_w, win_h);
        }
    }

    if srf.sample_bind_group {
        jsDestroyHandle(srf.sample_bind_group);
        srf.sample_bind_group = 0;
    }
    srf.sample_bind_group = jsCreateBindGroupSampled(srf.sample_layout, srf.sampler, tex.handle);

    jsBeginCommands();
    jsBeginRenderPassToSurface(srf.canvas_handle, 0, 0, 0, 1);
    jsSetPipeline(srf.present_pipeline);
    jsSetBindGroup(0, srf.sample_bind_group);
    jsDraw(3);
    jsEndRenderPass();
    jsSubmit();

    jsWaitForFrame(fps);

    current_time := app_time();
    if srf.last_time > 0 {
        srf.delta_time = current_time - srf.last_time;
    }
    srf.last_time = current_time;
}

Destroy :: (srf: *WebGpuSurface($Window_t)) {
    if srf.sample_bind_group { jsDestroyHandle(srf.sample_bind_group); }
    if srf.present_pipeline { jsDestroyHandle(srf.present_pipeline); }
    if srf.present_shader { jsDestroyHandle(srf.present_shader); }
    if srf.sampler { jsDestroyHandle(srf.sampler); }
    if srf.sample_layout { jsDestroyHandle(srf.sample_layout); }
    if srf.canvas_handle { jsDestroyHandle(srf.canvas_handle); }
    srf.* = .{};
}

// ---------- foreign JS imports ----------

jsWebGpuHasDevice :: () -> s32 #foreign;
jsCreateBuffer :: (usage: u32, size: u64, data: *u8, data_len: s64) -> WGpuHandle #foreign;
jsCreateTexture :: (width: u32, height: u32, usage: u32, format: u32) -> WGpuHandle #foreign;
jsWriteTexture :: (tex: WGpuHandle, width: u32, height: u32, data: *u8, data_len: s64) #foreign;
jsCreateShaderModule :: (code: *u8, code_len: s64) -> WGpuHandle #foreign;
jsCreateUniformBuffer :: (size: u32) -> WGpuHandle #foreign;
jsWriteBuffer :: (buf: WGpuHandle, offset: u32, data: *u8, data_len: s64) #foreign;
jsCreateRenderPipeline :: (
    vs_mod: WGpuHandle, vs_entry: *u8, vs_entry_len: s64,
    fs_mod: WGpuHandle, fs_entry: *u8, fs_entry_len: s64,
    stride: u32, has_color_attr: s32,
    topology: s32, depth_enabled: s32,
    bind_group_layout: WGpuHandle,
) -> WGpuHandle #foreign;
jsCreatePresentPipeline :: (
    vs_mod: WGpuHandle, fs_mod: WGpuHandle, sample_layout: WGpuHandle,
    swap_format: *u8, swap_format_len: s64,
) -> WGpuHandle #foreign;
jsCreateBindGroupLayoutUniform :: () -> WGpuHandle #foreign;
jsCreateBindGroupLayoutSampled :: () -> WGpuHandle #foreign;
jsCreateBindGroupLayoutStorageTexture :: () -> WGpuHandle #foreign;
jsCreateBindGroupLayoutStorageTextureUniform :: () -> WGpuHandle #foreign;
jsCreateBindGroupUniform :: (layout: WGpuHandle, buffer: WGpuHandle) -> WGpuHandle #foreign;
jsCreateBindGroupSampled :: (layout: WGpuHandle, sampler: WGpuHandle, tex: WGpuHandle) -> WGpuHandle #foreign;
jsCreateBindGroupStorageTexture :: (layout: WGpuHandle, tex: WGpuHandle) -> WGpuHandle #foreign;
jsCreateBindGroupStorageTextureUniform :: (layout: WGpuHandle, tex: WGpuHandle, uniform: WGpuHandle) -> WGpuHandle #foreign;
jsCreateComputePipeline :: (
    mod: WGpuHandle, entry: *u8, entry_len: s64, bind_group_layout: WGpuHandle,
) -> WGpuHandle #foreign;
jsCreateSampler :: () -> WGpuHandle #foreign;
jsCreateSurface :: (id: *u8, id_len: s64) -> WGpuHandle #foreign;
jsConfigureSurface :: (surface: WGpuHandle, width: u32, height: u32) -> WGpuHandle #foreign;
jsGetPreferredSwapFormat :: (out: *u8, out_cap: s64) -> s64 #foreign;
jsBeginCommands :: () -> s32 #foreign;
jsBeginRenderPassToTexture :: (color: WGpuHandle, depth: WGpuHandle, r: float, g: float, b: float, a: float) #foreign;
jsBeginRenderPassToSurface :: (surface: WGpuHandle, r: float, g: float, b: float, a: float) #foreign;
jsBeginComputePass :: () #foreign;
jsSetPipeline :: (pipe: WGpuHandle) #foreign;
jsSetVertexBuffer :: (slot: u32, buf: WGpuHandle) #foreign;
jsSetIndexBuffer :: (buf: WGpuHandle) #foreign;
jsSetBindGroup :: (index: u32, bg: WGpuHandle) #foreign;
jsDrawIndexed :: (index_count: u32) #foreign;
jsDraw :: (vertex_count: u32) #foreign;
jsDispatch :: (groups_x: u32, groups_y: u32, groups_z: u32) #foreign;
jsEndRenderPass :: () #foreign;
jsEndComputePass :: () #foreign;
jsSubmit :: () #foreign;
jsDestroyHandle :: (handle: WGpuHandle) #foreign;
