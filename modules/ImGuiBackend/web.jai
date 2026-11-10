ImGuiFontWeb :: struct {
    atlas: *ImGui.ImFontAtlas;
    width: s32;
    height: s32;
    texture: GPU.WGpuHandle;
    bind_group: GPU.WGpuHandle;
}

ImGuiWeb :: struct {
    dev: *GPU.WebGpuDevice;
    shader: GPU.WGpuHandle;
    layout: GPU.WGpuHandle;
    pipeline: GPU.WGpuHandle;
    sampler: GPU.WGpuHandle;
    uniform: GPU.WGpuHandle;
    vtx: GPU.WGpuHandle;
    idx: GPU.WGpuHandle;
    vtx_bytes: s64;
    idx_bytes: s64;
    fonts: [..]*ImGuiFontWeb;
}

imgui_web: ImGuiWeb;

ImGuiBackend_Init :: (dev: *GPU.WebGpuDevice) {
    assert(dev != null, "ImGuiBackend_Init: null device");
    assert(imgui_web.dev == null, "ImGuiBackend_Init: already initialized");
    imgui_web.dev = dev;

    imgui_web.shader = GPU.jsCreateShaderModule(ImGuiShaderBytes.code.data, xx ImGuiShaderBytes.code.count);
    imgui_web.layout = jsCreateImGuiBindGroupLayout();
    imgui_web.sampler = GPU.jsCreateSampler();
    imgui_web.uniform = GPU.jsCreateUniformBuffer(256);
    imgui_web.pipeline = jsCreateImGuiPipeline(imgui_web.shader, imgui_web.layout);

    if ImGui.GetCurrentContext() {
        io := ImGui.GetIO();
        io.BackendFlags_ |= .RendererHasVtxOffset;
        imgui_upload_font(io.Fonts);
    }
}

ImGuiBackend_Destroy :: (dev: *GPU.WebGpuDevice) {
    if !imgui_web.dev || imgui_web.dev != dev return;
    for * imgui_web.fonts {
        imgui_destroy_font(it.*);
        free(it.*);
    }
    array_free(imgui_web.fonts);
    if imgui_web.vtx GPU.jsDestroyHandle(imgui_web.vtx);
    if imgui_web.idx GPU.jsDestroyHandle(imgui_web.idx);
    if imgui_web.pipeline GPU.jsDestroyHandle(imgui_web.pipeline);
    if imgui_web.uniform GPU.jsDestroyHandle(imgui_web.uniform);
    if imgui_web.sampler GPU.jsDestroyHandle(imgui_web.sampler);
    if imgui_web.layout GPU.jsDestroyHandle(imgui_web.layout);
    if imgui_web.shader GPU.jsDestroyHandle(imgui_web.shader);
    imgui_web = .{};
}

ImGuiBackend_RenderDrawData :: (q: *GPU.WebGpuGraphicsQueue, draw_data: *ImGui.ImDrawData) {
    assert(imgui_web.dev != null, "ImGuiBackend_RenderDrawData: call Init first");
    assert(q != null && q.recording, "ImGuiBackend_RenderDrawData: Bind a framebuffer first");
    if !draw_data || !draw_data.Valid return;
    if draw_data.CmdListsCount <= 0 return;
    if draw_data.DisplaySize.x <= 0 || draw_data.DisplaySize.y <= 0 return;

    io := ImGui.GetIO();
    io.BackendFlags_ |= .RendererHasVtxOffset;
    if !io.Fonts.TexID imgui_upload_font(io.Fonts);

    assert(q.bound_fb_any != null, "ImGuiBackend_RenderDrawData: no framebuffer");
    // FrameBuffer always starts with color_textures[0].
    color := (cast(**GPU.WebGpuTexture2D) q.bound_fb_any).*;
    assert(color != null, "ImGuiBackend_RenderDrawData: null color target");
    fb_w := cast(float) color.size.x;
    fb_h := cast(float) color.size.y;

    // Same projection as Vulkan: ImGui Y-down maps to NDC -1 at the top of the widget.
    // WebGPU stores that at the bottom of the texture. Present UV (y+1)*0.5
    // shows that edge at the top of the canvas, so the panel reads upright.
    //
    // slang WGSL path turns `uniform Push` into a std140 UBO:
    //   Scale @0 (vec2 + 8 pad), Translate @16 (vec2 + 8 pad) — not packed float4.
    scale_x := 2.0 / draw_data.DisplaySize.x;
    scale_y := 2.0 / draw_data.DisplaySize.y;
    pc := float.[
        cast(float) scale_x,
        cast(float) scale_y,
        0.0, 0.0,
        cast(float) (-1.0 - draw_data.DisplayPos.x * scale_x),
        cast(float) (-1.0 - draw_data.DisplayPos.y * scale_y),
        0.0, 0.0,
    ];
    GPU.jsWriteBuffer(imgui_web.uniform, 0, cast(*u8) pc.data, xx pc.count * size_of(float));
    GPU.jsSetPipeline(imgui_web.pipeline);

    // Grow once for the whole frame (same rule as Vulkan: never destroy a buffer
    // that was already bound in this pass when a later CmdList needs more space).
    //
    // WebGPU writeBuffer offsets must be 4-byte aligned. ImDrawIdx is u16, so
    // concatenating lists with per-list writes can hit offsets like 606. Stage on
    // the CPU and upload once at offset 0 (jsWriteBuffer also pads size to 4).
    total_vtx := cast(s64) draw_data.TotalVtxCount * size_of(ImGui.ImDrawVert);
    total_idx := cast(s64) draw_data.TotalIdxCount * size_of(ImGui.ImDrawIdx);
    if total_vtx <= 0 || total_idx <= 0 return;
    imgui_ensure_buffer(*imgui_web.vtx, *imgui_web.vtx_bytes, (total_vtx + 3) & ~3, 0x20);
    imgui_ensure_buffer(*imgui_web.idx, *imgui_web.idx_bytes, (total_idx + 3) & ~3, 0x10);

    vtx_stage: [] u8;
    idx_stage: [] u8;
    {
        push_allocator(temporary_allocator);
        vtx_stage, _ = NewArray(total_vtx, u8, initialized = false);
        idx_stage, _ = NewArray(total_idx, u8, initialized = false);
    }
    vtx_off: s64 = 0;
    idx_off: s64 = 0;
    for n: 0..draw_data.CmdListsCount-1 {
        cmd_list := draw_data.CmdLists[n];
        vtx_bytes := cast(s64) cmd_list.VtxBuffer.Size * size_of(ImGui.ImDrawVert);
        idx_bytes := cast(s64) cmd_list.IdxBuffer.Size * size_of(ImGui.ImDrawIdx);
        if vtx_bytes > 0 {
            memcpy(vtx_stage.data + vtx_off, cmd_list.VtxBuffer.Data, vtx_bytes);
            vtx_off += vtx_bytes;
        }
        if idx_bytes > 0 {
            memcpy(idx_stage.data + idx_off, cmd_list.IdxBuffer.Data, idx_bytes);
            idx_off += idx_bytes;
        }
    }
    GPU.jsWriteBuffer(imgui_web.vtx, 0, vtx_stage.data, total_vtx);
    GPU.jsWriteBuffer(imgui_web.idx, 0, idx_stage.data, total_idx);

    GPU.jsSetVertexBuffer(0, imgui_web.vtx);
    jsSetIndexBufferU16(imgui_web.idx);

    global_vtx: s32 = 0;
    global_idx: u32 = 0;
    for n: 0..draw_data.CmdListsCount-1 {
        cmd_list := draw_data.CmdLists[n];
        if cmd_list.CmdBuffer.Size <= 0 {
            global_vtx += cmd_list.VtxBuffer.Size;
            global_idx += cast(u32) cmd_list.IdxBuffer.Size;
            continue;
        }
        for cmd_i: 0..cmd_list.CmdBuffer.Size-1 {
            pcmd := cmd_list.CmdBuffer.Data + cmd_i;
            if pcmd.UserCallback {
                pcmd.UserCallback(cmd_list, pcmd);
                continue;
            }
            if pcmd.ElemCount == 0 continue;
            font := cast(*ImGuiFontWeb) pcmd.TextureId;
            if !font continue;
            GPU.jsSetBindGroup(0, font.bind_group);

            // Clip rects are Y-down. The projection mirrors them into the texture,
            // so the scissor (texture top-left) uses the mirrored Y.
            to_fb_x := fb_w / draw_data.DisplaySize.x;
            to_fb_y := fb_h / draw_data.DisplaySize.y;
            clip_x := (pcmd.ClipRect.x - draw_data.DisplayPos.x) * to_fb_x;
            clip_y := (pcmd.ClipRect.y - draw_data.DisplayPos.y) * to_fb_y;
            clip_z := (pcmd.ClipRect.z - draw_data.DisplayPos.x) * to_fb_x;
            clip_w := (pcmd.ClipRect.w - draw_data.DisplayPos.y) * to_fb_y;
            scissor_x := clip_x;
            scissor_y := fb_h - clip_w;
            scissor_w := clip_z - clip_x;
            scissor_h := clip_w - clip_y;
            if scissor_x < 0 {
                scissor_w += scissor_x;
                scissor_x = 0;
            }
            if scissor_y < 0 {
                scissor_h += scissor_y;
                scissor_y = 0;
            }
            if scissor_x + scissor_w > fb_w scissor_w = fb_w - scissor_x;
            if scissor_y + scissor_h > fb_h scissor_h = fb_h - scissor_y;
            if scissor_w <= 0 || scissor_h <= 0 continue;
            jsSetScissor(cast(s32) scissor_x, cast(s32) scissor_y, cast(u32) scissor_w, cast(u32) scissor_h);
            jsDrawIndexedRange(
                pcmd.ElemCount,
                global_idx + pcmd.IdxOffset,
                global_vtx + cast(s32) pcmd.VtxOffset,
            );
        }
        global_vtx += cmd_list.VtxBuffer.Size;
        global_idx += cast(u32) cmd_list.IdxBuffer.Size;
    }
}

imgui_upload_font :: (atlas: *ImGui.ImFontAtlas) {
    if !atlas return;
    pixels: *u8;
    w, h, bpp: s32;
    atlas.GetTexDataAsRGBA32(atlas, *pixels, *w, *h, *bpp);
    assert(pixels != null && w > 0 && h > 0, "ImGui font atlas is empty");

    for * imgui_web.fonts {
        font := it.*;
        if font.atlas != atlas continue;
        if font.width == w && font.height == h return;
        imgui_destroy_font(font);
        imgui_fill_font(font, atlas, pixels, w, h);
        return;
    }

    font := New(ImGuiFontWeb);
    imgui_fill_font(font, atlas, pixels, w, h);
    array_add(*imgui_web.fonts, font);
    atlas.TexID = cast(*void) font;
}

imgui_fill_font :: (font: *ImGuiFontWeb, atlas: *ImGui.ImFontAtlas, pixels: *u8, w: s32, h: s32) {
    font.atlas = atlas;
    font.width = w;
    font.height = h;
    byte_count := cast(s64) w * cast(s64) h * 4;
    font.texture = jsCreateRGBATexture(cast(u32) w, cast(u32) h, pixels, byte_count);
    font.bind_group = jsCreateImGuiBindGroup(imgui_web.layout, font.texture, imgui_web.sampler, imgui_web.uniform);
}

imgui_destroy_font :: (font: *ImGuiFontWeb) {
    if !font return;
    if font.bind_group GPU.jsDestroyHandle(font.bind_group);
    if font.texture GPU.jsDestroyHandle(font.texture);
    font.bind_group = 0;
    font.texture = 0;
    if font.atlas && font.atlas.TexID == cast(*void) font font.atlas.TexID = null;
}

imgui_ensure_buffer :: (handle: *GPU.WGpuHandle, capacity: *s64, needed: s64, usage: u32) {
    if needed <= capacity.* return;
    bytes := needed;
    if bytes < 65536 bytes = 65536;
    if capacity.* > 0 && bytes < capacity.* * 2 bytes = capacity.* * 2;
    if handle.* GPU.jsDestroyHandle(handle.*);
    handle.* = jsCreateRawBuffer(cast(u64) bytes, usage);
    capacity.* = bytes;
}

jsCreateRGBATexture :: (width: u32, height: u32, pixels: *u8, byte_count: s64) -> GPU.WGpuHandle #foreign;
jsCreateRawBuffer :: (size: u64, usage: u32) -> GPU.WGpuHandle #foreign;
jsCreateImGuiBindGroupLayout :: () -> GPU.WGpuHandle #foreign;
jsCreateImGuiBindGroup :: (layout: GPU.WGpuHandle, tex: GPU.WGpuHandle, sampler: GPU.WGpuHandle, uniform: GPU.WGpuHandle) -> GPU.WGpuHandle #foreign;
jsCreateImGuiPipeline :: (shader: GPU.WGpuHandle, layout: GPU.WGpuHandle) -> GPU.WGpuHandle #foreign;
jsSetIndexBufferU16 :: (buf: GPU.WGpuHandle) #foreign;
jsSetScissor :: (x: s32, y: s32, w: u32, h: u32) #foreign;
jsDrawIndexedRange :: (index_count: u32, first_index: u32, base_vertex: s32) #foreign;
