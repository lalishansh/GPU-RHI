ImGuiFontGpu :: struct {
    atlas: *ImGui.ImFontAtlas;
    width: s32;
    height: s32;
    image: VkImage;
    memory: VkDeviceMemory;
    view: VkImageView;
    desc_set: VkDescriptorSet;
}

ImGuiVk :: struct {
    dev: *GPU.VulkanDevice;
    shader: VkShaderModule;
    pipeline_layout: VkPipelineLayout;
    pipeline: VkPipeline;
    render_pass: VkRenderPass;
    sampler: VkSampler;
    desc_layout: VkDescriptorSetLayout;
    desc_pool: VkDescriptorPool;
    vtx_buffer: VkBuffer;
    vtx_memory: VkDeviceMemory;
    vtx_mapped: *u8;
    vtx_bytes: s64;
    idx_buffer: VkBuffer;
    idx_memory: VkDeviceMemory;
    idx_mapped: *u8;
    idx_bytes: s64;
    fonts: [..]*ImGuiFontGpu;
}

imgui_vk: ImGuiVk;

ImGuiBackend_Init :: (dev: *GPU.VulkanDevice) {
    assert(dev != null && dev.device != null, "ImGuiBackend_Init: null device");
    assert(imgui_vk.dev == null, "ImGuiBackend_Init: already initialized");
    imgui_vk.dev = dev;
    device := dev.device;

    {
        mod_info: VkShaderModuleCreateInfo;
        mod_info.codeSize = xx ImGuiShaderBytes.code.count;
        mod_info.pCode = cast(*u32) ImGuiShaderBytes.code.data;
        imgui_vk_check(vkCreateShaderModule(device, *mod_info, null, *imgui_vk.shader));
    }

    {
        bindings: [2] VkDescriptorSetLayoutBinding;
        bindings[0].binding = 0;
        bindings[0].descriptorType = .COMBINED_IMAGE_SAMPLER;
        bindings[0].descriptorCount = 1;
        bindings[0].stageFlags = .FRAGMENT_BIT;
        layout_info: VkDescriptorSetLayoutCreateInfo;
        layout_info.bindingCount = 1;
        layout_info.pBindings = bindings.data;
        // Separate texture + sampler matches the slang [[vk::binding]] pair.
        bindings[0].descriptorType = .SAMPLED_IMAGE;
        bindings[1].binding = 1;
        bindings[1].descriptorType = .SAMPLER;
        bindings[1].descriptorCount = 1;
        bindings[1].stageFlags = .FRAGMENT_BIT;
        layout_info.bindingCount = 2;
        imgui_vk_check(vkCreateDescriptorSetLayout(device, *layout_info, null, *imgui_vk.desc_layout));
    }

    {
        pool_sizes: [2] VkDescriptorPoolSize;
        pool_sizes[0].type = .SAMPLED_IMAGE;
        pool_sizes[0].descriptorCount = 64;
        pool_sizes[1].type = .SAMPLER;
        pool_sizes[1].descriptorCount = 64;
        pool_info: VkDescriptorPoolCreateInfo;
        pool_info.flags = .FREE_DESCRIPTOR_SET_BIT;
        pool_info.maxSets = 64;
        pool_info.poolSizeCount = 2;
        pool_info.pPoolSizes = pool_sizes.data;
        imgui_vk_check(vkCreateDescriptorPool(device, *pool_info, null, *imgui_vk.desc_pool));
    }

    {
        samp_info: VkSamplerCreateInfo;
        samp_info.magFilter = .LINEAR;
        samp_info.minFilter = .LINEAR;
        samp_info.mipmapMode = .LINEAR;
        samp_info.addressModeU = .CLAMP_TO_EDGE;
        samp_info.addressModeV = .CLAMP_TO_EDGE;
        samp_info.addressModeW = .CLAMP_TO_EDGE;
        imgui_vk_check(vkCreateSampler(device, *samp_info, null, *imgui_vk.sampler));
    }

    {
        pc: VkPushConstantRange;
        pc.stageFlags = .VERTEX_BIT;
        pc.offset = 0;
        pc.size = size_of(float) * 4;
        layout_info: VkPipelineLayoutCreateInfo;
        layout_info.setLayoutCount = 1;
        layout_info.pSetLayouts = *imgui_vk.desc_layout;
        layout_info.pushConstantRangeCount = 1;
        layout_info.pPushConstantRanges = *pc;
        imgui_vk_check(vkCreatePipelineLayout(device, *layout_info, null, *imgui_vk.pipeline_layout));
    }

    imgui_create_pipeline();

    if ImGui.GetCurrentContext() {
        io := ImGui.GetIO();
        io.BackendFlags_ |= .RendererHasVtxOffset;
        imgui_upload_font(io.Fonts);
    }
}

ImGuiBackend_Destroy :: (dev: *GPU.VulkanDevice) {
    if !imgui_vk.dev || imgui_vk.dev != dev return;
    vkDeviceWaitIdle(dev.device);
    device := dev.device;

    for * imgui_vk.fonts {
        imgui_destroy_font(it.*);
        free(it.*);
    }
    array_free(imgui_vk.fonts);

    imgui_destroy_buffer(*imgui_vk.vtx_buffer, *imgui_vk.vtx_memory, *imgui_vk.vtx_mapped);
    imgui_destroy_buffer(*imgui_vk.idx_buffer, *imgui_vk.idx_memory, *imgui_vk.idx_mapped);

    if imgui_vk.pipeline vkDestroyPipeline(device, imgui_vk.pipeline, null);
    if imgui_vk.pipeline_layout vkDestroyPipelineLayout(device, imgui_vk.pipeline_layout, null);
    if imgui_vk.shader vkDestroyShaderModule(device, imgui_vk.shader, null);
    if imgui_vk.render_pass vkDestroyRenderPass(device, imgui_vk.render_pass, null);
    if imgui_vk.sampler vkDestroySampler(device, imgui_vk.sampler, null);
    if imgui_vk.desc_pool vkDestroyDescriptorPool(device, imgui_vk.desc_pool, null);
    if imgui_vk.desc_layout vkDestroyDescriptorSetLayout(device, imgui_vk.desc_layout, null);
    imgui_vk = .{};
}

ImGuiBackend_RenderDrawData :: (q: *GPU.VulkanQueue, draw_data: *ImGui.ImDrawData) {
    assert(imgui_vk.dev != null, "ImGuiBackend_RenderDrawData: call Init first");
    assert(q != null && q.render_pass_active && q.cmd != null, "ImGuiBackend_RenderDrawData: Bind a framebuffer first");
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

    viewport: VkViewport;
    viewport.x = 0;
    viewport.y = 0;
    viewport.width = fb_w;
    viewport.height = fb_h;
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    vkCmdSetViewport(q.cmd, 0, 1, *viewport);

    vkCmdBindPipeline(q.cmd, .GRAPHICS, imgui_vk.pipeline);

    scale_x := 2.0 / draw_data.DisplaySize.x;
    scale_y := 2.0 / draw_data.DisplaySize.y;
    pc := float.[
        cast(float) scale_x,
        cast(float) scale_y,
        cast(float) (-1.0 - draw_data.DisplayPos.x * scale_x),
        cast(float) (-1.0 - draw_data.DisplayPos.y * scale_y),
    ];
    vkCmdPushConstants(q.cmd, imgui_vk.pipeline_layout, .VERTEX_BIT, 0, cast(u32) (pc.count * size_of(float)), pc.data);

    for n: 0..draw_data.CmdListsCount-1 {
        cmd_list := draw_data.CmdLists[n];
        if cmd_list.VtxBuffer.Size <= 0 || cmd_list.IdxBuffer.Size <= 0 continue;

        vtx_bytes := cast(s64) cmd_list.VtxBuffer.Size * size_of(ImGui.ImDrawVert);
        idx_bytes := cast(s64) cmd_list.IdxBuffer.Size * size_of(ImGui.ImDrawIdx);
        imgui_ensure_buffer(*imgui_vk.vtx_buffer, *imgui_vk.vtx_memory, *imgui_vk.vtx_mapped, *imgui_vk.vtx_bytes, vtx_bytes, .VERTEX_BUFFER_BIT);
        imgui_ensure_buffer(*imgui_vk.idx_buffer, *imgui_vk.idx_memory, *imgui_vk.idx_mapped, *imgui_vk.idx_bytes, idx_bytes, .INDEX_BUFFER_BIT);
        memcpy(imgui_vk.vtx_mapped, cmd_list.VtxBuffer.Data, vtx_bytes);
        memcpy(imgui_vk.idx_mapped, cmd_list.IdxBuffer.Data, idx_bytes);

        vtx_offset: VkDeviceSize = 0;
        vkCmdBindVertexBuffers(q.cmd, 0, 1, *imgui_vk.vtx_buffer, *vtx_offset);
        vkCmdBindIndexBuffer(q.cmd, imgui_vk.idx_buffer, 0, .UINT16);

        if cmd_list.CmdBuffer.Size <= 0 continue;
        for cmd_i: 0..cmd_list.CmdBuffer.Size-1 {
            pcmd := cmd_list.CmdBuffer.Data + cmd_i;
            if pcmd.UserCallback {
                pcmd.UserCallback(cmd_list, pcmd);
                continue;
            }
            if pcmd.ElemCount == 0 continue;
            font := cast(*ImGuiFontGpu) pcmd.TextureId;
            if !font continue;
            vkCmdBindDescriptorSets(q.cmd, .GRAPHICS, imgui_vk.pipeline_layout, 0, 1, *font.desc_set, 0, null);

            clip_x := pcmd.ClipRect.x - draw_data.DisplayPos.x;
            clip_y := pcmd.ClipRect.y - draw_data.DisplayPos.y;
            clip_z := pcmd.ClipRect.z - draw_data.DisplayPos.x;
            clip_w := pcmd.ClipRect.w - draw_data.DisplayPos.y;
            if clip_x < 0 clip_x = 0;
            if clip_y < 0 clip_y = 0;
            if clip_z > fb_w clip_z = fb_w;
            if clip_w > fb_h clip_w = fb_h;
            if clip_z <= clip_x || clip_w <= clip_y continue;

            scissor: VkRect2D;
            scissor.offset.x = cast(s32) clip_x;
            scissor.offset.y = cast(s32) clip_y;
            scissor.extent.width = cast(u32) (clip_z - clip_x);
            scissor.extent.height = cast(u32) (clip_w - clip_y);
            vkCmdSetScissor(q.cmd, 0, 1, *scissor);
            vkCmdDrawIndexed(q.cmd, pcmd.ElemCount, 1, pcmd.IdxOffset, cast(s32) pcmd.VtxOffset, 0);
        }
    }
}

imgui_upload_font :: (atlas: *ImGui.ImFontAtlas) {
    if !atlas return;
    pixels: *u8;
    w, h, bpp: s32;
    atlas.GetTexDataAsRGBA32(atlas, *pixels, *w, *h, *bpp);
    assert(pixels != null && w > 0 && h > 0, "ImGui font atlas is empty");

    for * imgui_vk.fonts {
        font := it.*;
        if font.atlas != atlas continue;
        if font.width == w && font.height == h return;
        imgui_destroy_font(font);
        imgui_fill_font(font, atlas, pixels, w, h);
        return;
    }

    font := New(ImGuiFontGpu);
    imgui_fill_font(font, atlas, pixels, w, h);
    array_add(*imgui_vk.fonts, font);
    atlas.TexID = cast(*void) font;
}

imgui_fill_font :: (font: *ImGuiFontGpu, atlas: *ImGui.ImFontAtlas, pixels: *u8, w: s32, h: s32) {
    dev := imgui_vk.dev;
    device := dev.device;
    font.atlas = atlas;
    font.width = w;
    font.height = h;

    byte_count := cast(s64) w * cast(s64) h * 4;
    staging: VkBuffer;
    staging_mem: VkDeviceMemory;
    staging_mapped: *u8;
    imgui_create_buffer(byte_count, .TRANSFER_SRC_BIT, .HOST_VISIBLE_BIT | .HOST_COHERENT_BIT, *staging, *staging_mem, *staging_mapped);
    memcpy(staging_mapped, pixels, byte_count);

    image_info: VkImageCreateInfo;
    image_info.imageType = ._2D;
    image_info.format = .R8G8B8A8_UNORM;
    image_info.extent.width = cast(u32) w;
    image_info.extent.height = cast(u32) h;
    image_info.extent.depth = 1;
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.samples = ._1_BIT;
    image_info.tiling = .OPTIMAL;
    image_info.usage = .TRANSFER_DST_BIT | .SAMPLED_BIT;
    image_info.initialLayout = .UNDEFINED;
    imgui_vk_check(vkCreateImage(device, *image_info, null, *font.image));

    reqs: VkMemoryRequirements;
    vkGetImageMemoryRequirements(device, font.image, *reqs);
    alloc: VkMemoryAllocateInfo;
    alloc.allocationSize = reqs.size;
    alloc.memoryTypeIndex = imgui_memory_type(dev, reqs.memoryTypeBits, .DEVICE_LOCAL_BIT);
    imgui_vk_check(vkAllocateMemory(device, *alloc, null, *font.memory));
    imgui_vk_check(vkBindImageMemory(device, font.image, font.memory, 0));

    view_info: VkImageViewCreateInfo;
    view_info.image = font.image;
    view_info.viewType = ._2D;
    view_info.format = .R8G8B8A8_UNORM;
    view_info.subresourceRange.aspectMask = .COLOR_BIT;
    view_info.subresourceRange.levelCount = 1;
    view_info.subresourceRange.layerCount = 1;
    imgui_vk_check(vkCreateImageView(device, *view_info, null, *font.view));

    alloc_info: VkDescriptorSetAllocateInfo;
    alloc_info.descriptorPool = imgui_vk.desc_pool;
    alloc_info.descriptorSetCount = 1;
    alloc_info.pSetLayouts = *imgui_vk.desc_layout;
    imgui_vk_check(vkAllocateDescriptorSets(device, *alloc_info, *font.desc_set));

    image_desc: VkDescriptorImageInfo;
    image_desc.imageView = font.view;
    image_desc.imageLayout = .SHADER_READ_ONLY_OPTIMAL;
    samp_desc: VkDescriptorImageInfo;
    samp_desc.sampler = imgui_vk.sampler;
    writes: [2] VkWriteDescriptorSet;
    writes[0].dstSet = font.desc_set;
    writes[0].dstBinding = 0;
    writes[0].descriptorCount = 1;
    writes[0].descriptorType = .SAMPLED_IMAGE;
    writes[0].pImageInfo = *image_desc;
    writes[1].dstSet = font.desc_set;
    writes[1].dstBinding = 1;
    writes[1].descriptorCount = 1;
    writes[1].descriptorType = .SAMPLER;
    writes[1].pImageInfo = *samp_desc;
    vkUpdateDescriptorSets(device, 2, writes.data, 0, null);

    pool, cmd := imgui_oneshot_begin();
    range: VkImageSubresourceRange;
    range.aspectMask = .COLOR_BIT;
    range.levelCount = 1;
    range.layerCount = 1;
    imgui_barrier(cmd, font.image, cast(VkAccessFlags) 0, .TRANSFER_WRITE_BIT, .UNDEFINED, .TRANSFER_DST_OPTIMAL, .TOP_OF_PIPE_BIT, .TRANSFER_BIT, range);

    copy: VkBufferImageCopy;
    copy.imageSubresource.aspectMask = .COLOR_BIT;
    copy.imageSubresource.layerCount = 1;
    copy.imageExtent.width = cast(u32) w;
    copy.imageExtent.height = cast(u32) h;
    copy.imageExtent.depth = 1;
    vkCmdCopyBufferToImage(cmd, staging, font.image, .TRANSFER_DST_OPTIMAL, 1, *copy);
    imgui_barrier(cmd, font.image, .TRANSFER_WRITE_BIT, .SHADER_READ_BIT, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL, .TRANSFER_BIT, .FRAGMENT_SHADER_BIT, range);
    imgui_oneshot_end(pool, cmd);

    vkDestroyBuffer(device, staging, null);
    vkFreeMemory(device, staging_mem, null);
}

imgui_destroy_font :: (font: *ImGuiFontGpu) {
    if !font || !imgui_vk.dev return;
    device := imgui_vk.dev.device;
    if font.desc_set {
        vkFreeDescriptorSets(device, imgui_vk.desc_pool, 1, *font.desc_set);
        font.desc_set = null;
    }
    if font.view { vkDestroyImageView(device, font.view, null); font.view = null; }
    if font.image { vkDestroyImage(device, font.image, null); font.image = null; }
    if font.memory { vkFreeMemory(device, font.memory, null); font.memory = null; }
    if font.atlas && font.atlas.TexID == cast(*void) font font.atlas.TexID = null;
}

imgui_create_pipeline :: () {
    dev := imgui_vk.dev;
    device := dev.device;
    depth_fmt := imgui_depth_format(dev.physical_device);

    attachments: [2] VkAttachmentDescription;
    attachments[0].format = .R8G8B8A8_UNORM;
    attachments[0].samples = ._1_BIT;
    attachments[0].loadOp = .LOAD;
    attachments[0].storeOp = .STORE;
    attachments[0].stencilLoadOp = .DONT_CARE;
    attachments[0].stencilStoreOp = .DONT_CARE;
    attachments[0].initialLayout = .COLOR_ATTACHMENT_OPTIMAL;
    attachments[0].finalLayout = .COLOR_ATTACHMENT_OPTIMAL;
    attachments[1].format = depth_fmt;
    attachments[1].samples = ._1_BIT;
    attachments[1].loadOp = .LOAD;
    attachments[1].storeOp = .STORE;
    attachments[1].stencilLoadOp = .DONT_CARE;
    attachments[1].stencilStoreOp = .DONT_CARE;
    attachments[1].initialLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    attachments[1].finalLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

    color_ref := VkAttachmentReference.{0, .COLOR_ATTACHMENT_OPTIMAL};
    depth_ref := VkAttachmentReference.{1, .DEPTH_STENCIL_ATTACHMENT_OPTIMAL};
    subpass: VkSubpassDescription;
    subpass.pipelineBindPoint = .GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = *color_ref;
    subpass.pDepthStencilAttachment = *depth_ref;
    rp_info: VkRenderPassCreateInfo;
    rp_info.attachmentCount = 2;
    rp_info.pAttachments = attachments.data;
    rp_info.subpassCount = 1;
    rp_info.pSubpasses = *subpass;
    imgui_vk_check(vkCreateRenderPass(device, *rp_info, null, *imgui_vk.render_pass));

    binding := VkVertexInputBindingDescription.{binding = 0, stride = xx size_of(ImGui.ImDrawVert), inputRate = .VERTEX};
    attrs: [3] VkVertexInputAttributeDescription;
    attrs[0] = .{location = 0, binding = 0, format = .R32G32_SFLOAT, offset = 0};
    attrs[1] = .{location = 1, binding = 0, format = .R32G32_SFLOAT, offset = 8};
    attrs[2] = .{location = 2, binding = 0, format = .R8G8B8A8_UNORM, offset = 16};
    vertex_input: VkPipelineVertexInputStateCreateInfo;
    vertex_input.vertexBindingDescriptionCount = 1;
    vertex_input.pVertexBindingDescriptions = *binding;
    vertex_input.vertexAttributeDescriptionCount = 3;
    vertex_input.pVertexAttributeDescriptions = attrs.data;

    input_assembly: VkPipelineInputAssemblyStateCreateInfo;
    input_assembly.topology = .TRIANGLE_LIST;

    raster: VkPipelineRasterizationStateCreateInfo;
    raster.polygonMode = .FILL;
    raster.cullMode = .NONE;
    raster.frontFace = .COUNTER_CLOCKWISE;
    raster.lineWidth = 1.0;

    blend_att: VkPipelineColorBlendAttachmentState;
    blend_att.blendEnable = VK_TRUE;
    blend_att.srcColorBlendFactor = .SRC_ALPHA;
    blend_att.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA;
    blend_att.colorBlendOp = .ADD;
    blend_att.srcAlphaBlendFactor = .ONE;
    blend_att.dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA;
    blend_att.alphaBlendOp = .ADD;
    blend_att.colorWriteMask = xx 0xf;
    blend: VkPipelineColorBlendStateCreateInfo;
    blend.attachmentCount = 1;
    blend.pAttachments = *blend_att;

    depth: VkPipelineDepthStencilStateCreateInfo;
    depth.depthTestEnable = VK_FALSE;
    depth.depthWriteEnable = VK_FALSE;

    viewport_state: VkPipelineViewportStateCreateInfo;
    viewport_state.viewportCount = 1;
    viewport_state.scissorCount = 1;
    multisample: VkPipelineMultisampleStateCreateInfo;
    multisample.rasterizationSamples = ._1_BIT;

    dynamic_enables := VkDynamicState.[.VIEWPORT, .SCISSOR];
    dynamic_state: VkPipelineDynamicStateCreateInfo;
    dynamic_state.dynamicStateCount = 2;
    dynamic_state.pDynamicStates = dynamic_enables.data;

    stages: [2] VkPipelineShaderStageCreateInfo;
    stages[0].stage = .VERTEX_BIT;
    stages[0].module = imgui_vk.shader;
    stages[0].pName = temp_c_string("vs_imgui");
    stages[1].stage = .FRAGMENT_BIT;
    stages[1].module = imgui_vk.shader;
    stages[1].pName = temp_c_string("fs_imgui");

    gp: VkGraphicsPipelineCreateInfo;
    gp.stageCount = 2;
    gp.pStages = stages.data;
    gp.pVertexInputState = *vertex_input;
    gp.pInputAssemblyState = *input_assembly;
    gp.pViewportState = *viewport_state;
    gp.pRasterizationState = *raster;
    gp.pMultisampleState = *multisample;
    gp.pColorBlendState = *blend;
    gp.pDepthStencilState = *depth;
    gp.pDynamicState = *dynamic_state;
    gp.layout = imgui_vk.pipeline_layout;
    gp.renderPass = imgui_vk.render_pass;
    gp.basePipelineIndex = -1;
    imgui_vk_check(vkCreateGraphicsPipelines(device, null, 1, *gp, null, *imgui_vk.pipeline));
}

imgui_ensure_buffer :: (buffer: *VkBuffer, memory: *VkDeviceMemory, mapped: **u8, capacity: *s64, needed: s64, usage: VkBufferUsageFlags) {
    if needed <= capacity.* return;
    bytes := needed;
    if bytes < 65536 bytes = 65536;
    if capacity.* > 0 && bytes < capacity.* * 2 bytes = capacity.* * 2;
    imgui_destroy_buffer(buffer, memory, mapped);
    imgui_create_buffer(bytes, usage, .HOST_VISIBLE_BIT | .HOST_COHERENT_BIT, buffer, memory, mapped);
    capacity.* = bytes;
}

imgui_create_buffer :: (bytes: s64, usage: VkBufferUsageFlags, props: VkMemoryPropertyFlags, buffer: *VkBuffer, memory: *VkDeviceMemory, mapped: **u8) {
    dev := imgui_vk.dev;
    info: VkBufferCreateInfo;
    info.size = cast(u64) bytes;
    info.usage = usage;
    info.sharingMode = .EXCLUSIVE;
    imgui_vk_check(vkCreateBuffer(dev.device, *info, null, buffer));
    reqs: VkMemoryRequirements;
    vkGetBufferMemoryRequirements(dev.device, buffer.*, *reqs);
    alloc: VkMemoryAllocateInfo;
    alloc.allocationSize = reqs.size;
    alloc.memoryTypeIndex = imgui_memory_type(dev, reqs.memoryTypeBits, props);
    imgui_vk_check(vkAllocateMemory(dev.device, *alloc, null, memory));
    imgui_vk_check(vkBindBufferMemory(dev.device, buffer.*, memory.*, 0));
    if mapped {
        ptr: *void;
        imgui_vk_check(vkMapMemory(dev.device, memory.*, 0, reqs.size, 0, *ptr));
        mapped.* = cast(*u8) ptr;
    }
}

imgui_destroy_buffer :: (buffer: *VkBuffer, memory: *VkDeviceMemory, mapped: **u8) {
    if !imgui_vk.dev return;
    device := imgui_vk.dev.device;
    if mapped.* {
        vkUnmapMemory(device, memory.*);
        mapped.* = null;
    }
    if buffer.* { vkDestroyBuffer(device, buffer.*, null); buffer.* = null; }
    if memory.* { vkFreeMemory(device, memory.*, null); memory.* = null; }
}

imgui_oneshot_begin :: () -> VkCommandPool, VkCommandBuffer {
    dev := imgui_vk.dev;
    pool_info: VkCommandPoolCreateInfo;
    pool_info.queueFamilyIndex = dev.queue_family_index;
    pool: VkCommandPool;
    imgui_vk_check(vkCreateCommandPool(dev.device, *pool_info, null, *pool));
    alloc_info: VkCommandBufferAllocateInfo;
    alloc_info.commandPool = pool;
    alloc_info.level = .PRIMARY;
    alloc_info.commandBufferCount = 1;
    cmd: VkCommandBuffer;
    imgui_vk_check(vkAllocateCommandBuffers(dev.device, *alloc_info, *cmd));
    begin: VkCommandBufferBeginInfo;
    begin.flags = .ONE_TIME_SUBMIT_BIT;
    imgui_vk_check(vkBeginCommandBuffer(cmd, *begin));
    return pool, cmd;
}

imgui_oneshot_end :: (pool: VkCommandPool, cmd: VkCommandBuffer) {
    dev := imgui_vk.dev;
    imgui_vk_check(vkEndCommandBuffer(cmd));
    submit: VkSubmitInfo;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = *cmd;
    imgui_vk_check(vkQueueSubmit(dev.graphics_queue, 1, *submit, null));
    imgui_vk_check(vkQueueWaitIdle(dev.graphics_queue));
    vkDestroyCommandPool(dev.device, pool, null);
}

imgui_barrier :: (cmd: VkCommandBuffer, image: VkImage, src_access: VkAccessFlags, dst_access: VkAccessFlags, old_layout: VkImageLayout, new_layout: VkImageLayout, src_stage: VkPipelineStageFlags, dst_stage: VkPipelineStageFlags, range: VkImageSubresourceRange) {
    barrier: VkImageMemoryBarrier;
    barrier.srcAccessMask = src_access;
    barrier.dstAccessMask = dst_access;
    barrier.oldLayout = old_layout;
    barrier.newLayout = new_layout;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image;
    barrier.subresourceRange = range;
    vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, *barrier);
}

imgui_memory_type :: (dev: *GPU.VulkanDevice, type_bits: u32, properties: VkMemoryPropertyFlags) -> u32 {
    mem_props: VkPhysicalDeviceMemoryProperties;
    vkGetPhysicalDeviceMemoryProperties(dev.physical_device, *mem_props);
    bits := type_bits;
    for i: 0..mem_props.memoryTypeCount-1 {
        if (bits & 1) == 1 {
            if (mem_props.memoryTypes[i].propertyFlags & properties) == properties return i;
        }
        bits >>= 1;
    }
    assert(false, "ImGuiBackend: no matching Vulkan memory type");
    return 0;
}

imgui_depth_format :: (physical: VkPhysicalDevice) -> VkFormat {
    candidates := VkFormat.[.D32_SFLOAT_S8_UINT, .D32_SFLOAT, .D24_UNORM_S8_UINT, .D16_UNORM_S8_UINT, .D16_UNORM];
    for candidates {
        props: VkFormatProperties;
        vkGetPhysicalDeviceFormatProperties(physical, it, *props);
        if props.optimalTilingFeatures & .DEPTH_STENCIL_ATTACHMENT_BIT return it;
    }
    return .D32_SFLOAT;
}

imgui_vk_check :: (result: VkResult) {
    assert(result == .SUCCESS, "ImGuiBackend Vulkan error %", result);
}
