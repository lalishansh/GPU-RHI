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

ImGuiBackend_RenderDrawData :: (q: *GPU.WebGpuQueue, draw_data: *ImGui.ImDrawData) {
    assert(imgui_web.dev != null, "ImGuiBackend_RenderDrawData: call Init first");
    assert(q != null && q.recording, "ImGuiBackend_RenderDrawData: Bind a framebuffer first");
    if !draw_data || !draw_data.Valid return;
    if draw_data.CmdListsCount <= 0 return;
    if draw_data.DisplaySize.x <= 0 || draw_data.DisplaySize.y <= 0 return;

    io := ImGui.GetIO();
    io.BackendFlags_ |= .RendererHasVtxOffset;
    if !io.Fonts.TexID imgui_upload_font(io.Fonts);

    fb := q.bound_framebuffer;
    assert(fb != null && fb.textures.count > 0, "ImGuiBackend_RenderDrawData: no framebuffer");
    fb_w := cast(float) fb.textures[0].size.width;
    fb_h := cast(float) fb.textures[0].size.height;

    scale_x := 2.0 / draw_data.DisplaySize.x;
    scale_y := 2.0 / draw_data.DisplaySize.y;
    pc := float.[
        cast(float) scale_x,
        cast(float) scale_y,
        cast(float) (-1.0 - draw_data.DisplayPos.x * scale_x),
        cast(float) (-1.0 - draw_data.DisplayPos.y * scale_y),
    ];
    GPU.jsWriteBuffer(imgui_web.uniform, 0, cast(*u8) pc.data, xx pc.count * size_of(float));
    GPU.jsSetPipeline(imgui_web.pipeline);

    for n: 0..draw_data.CmdListsCount-1 {
        cmd_list := draw_data.CmdLists[n];
        if cmd_list.VtxBuffer.Size <= 0 || cmd_list.IdxBuffer.Size <= 0 continue;

        vtx_bytes := cast(s64) cmd_list.VtxBuffer.Size * size_of(ImGui.ImDrawVert);
        idx_bytes := cast(s64) cmd_list.IdxBuffer.Size * size_of(ImGui.ImDrawIdx);
        imgui_ensure_buffer(*imgui_web.vtx, *imgui_web.vtx_bytes, vtx_bytes, 0x20);
        imgui_ensure_buffer(*imgui_web.idx, *imgui_web.idx_bytes, idx_bytes, 0x10);
        GPU.jsWriteBuffer(imgui_web.vtx, 0, cast(*u8) cmd_list.VtxBuffer.Data, vtx_bytes);
        GPU.jsWriteBuffer(imgui_web.idx, 0, cast(*u8) cmd_list.IdxBuffer.Data, idx_bytes);
        GPU.jsSetVertexBuffer(0, imgui_web.vtx);
        jsSetIndexBufferU16(imgui_web.idx);

        if cmd_list.CmdBuffer.Size <= 0 continue;
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

            clip_x := pcmd.ClipRect.x - draw_data.DisplayPos.x;
            clip_y := pcmd.ClipRect.y - draw_data.DisplayPos.y;
            clip_z := pcmd.ClipRect.z - draw_data.DisplayPos.x;
            clip_w := pcmd.ClipRect.w - draw_data.DisplayPos.y;
            if clip_x < 0 clip_x = 0;
            if clip_y < 0 clip_y = 0;
            if clip_z > fb_w clip_z = fb_w;
            if clip_w > fb_h clip_w = fb_h;
            if clip_z <= clip_x || clip_w <= clip_y continue;
            jsSetScissor(cast(s32) clip_x, cast(s32) clip_y, cast(u32) (clip_z - clip_x), cast(u32) (clip_w - clip_y));
            jsDrawIndexedRange(pcmd.ElemCount, pcmd.IdxOffset, cast(s32) pcmd.VtxOffset);
        }
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
