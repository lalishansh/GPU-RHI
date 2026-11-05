// Vulkan host backend — Phase 2 headless (Context → Device → Texture → Buffer →
// Spawn → Queue → Pass → Submit → Get). Surface / CrossWindow deferred.

MAX_INSTANCE_LAYERS :: 64;
MAX_PHYSICAL_DEVICES :: 8;
MAX_QUEUE_FAMILIES :: 16;

VulkanContext :: struct {
    instance: VkInstance;
    debug_report_callback: VkDebugReportCallbackEXT;
    name: string;
    flags: Context_Flags;
    debug_callback: Debug_Callback;
}

Context :: (
    $api: API,
    name := "GPU-RHI",
    flags := Context_Flags.ENABLE_DEBUG,
    debug_callback := DEFAULT_DEBUG_CALLBACK,
) -> VulkanContext
    #modify { return api == .VULKAN, "This overload is for API.VULKAN."; }
{
    ctx: VulkanContext;
    ctx.name = name;
    ctx.flags = flags;
    ctx.debug_callback = debug_callback;

    app_info: VkApplicationInfo;
    app_info.pApplicationName = name.data;
    app_info.pEngineName = "GPU-RHI".data;
    app_info.apiVersion = VK_API_VERSION_1_2;

    instance_create_info: VkInstanceCreateInfo;
    instance_create_info.pApplicationInfo = *app_info;

    ext_names: [..]*u8;
    defer array_free(ext_names);

    if (flags & .ENABLE_SURFACE) != 0 {
        array_add(*ext_names, VK_KHR_SURFACE_EXTENSION_NAME.data);
        #if OS == .LINUX {
            array_add(*ext_names, "VK_KHR_xlib_surface".data);
        }
    }

    layers_available := false;
    want_validation := (flags & .ENABLE_VALIDATION) != 0 || (flags & .ENABLE_DEBUG) != 0;
    if want_validation {
        layer_count: u32;
        vkEnumerateInstanceLayerProperties(*layer_count, null);
        if layer_count > MAX_INSTANCE_LAYERS {
            layer_count = MAX_INSTANCE_LAYERS;
        }

        layers: [MAX_INSTANCE_LAYERS] VkLayerProperties;
        if layer_count {
            vkEnumerateInstanceLayerProperties(*layer_count, layers.data);

            validation_layer := "VK_LAYER_KHRONOS_validation";
            layer_found := false;
            for i: 0..layer_count-1 {
                if equal(to_string(layers[i].layerName.data), validation_layer) {
                    layer_found = true;
                    break;
                }
            }
            layers_available = layer_found;

            if layers_available {
                layer_names: [1] *u8;
                layer_names[0] = validation_layer.data;
                instance_create_info.ppEnabledLayerNames = layer_names.data;
                instance_create_info.enabledLayerCount = 1;
                array_add(*ext_names, VK_EXT_DEBUG_REPORT_EXTENSION_NAME.data);
            }
        }
    }

    instance_create_info.enabledExtensionCount = xx ext_names.count;
    instance_create_info.ppEnabledExtensionNames = ext_names.data;

    vk_check(vkCreateInstance(*instance_create_info, null, *ctx.instance));

    if layers_available {
        debug_info: VkDebugReportCallbackCreateInfoEXT;
        debug_info.flags = .ERROR_BIT_EXT | .WARNING_BIT_EXT;
        debug_info.pfnCallback = vulkan_debug_message_callback;

        create_cb: PFN_vkCreateDebugReportCallbackEXT =
            xx vkGetInstanceProcAddr(ctx.instance, "vkCreateDebugReportCallbackEXT");
        assert(create_cb != null);
        vk_check(create_cb(ctx.instance, *debug_info, null, *ctx.debug_report_callback));
    }

    if (flags & .ENABLE_DEBUG) != 0 {
        ctx.debug_callback(tprint("Context(VULKAN) name=\"%\" flags=%", name, cast(u32) flags));
    }
    return ctx;
}

Context :: (
    name := "GPU-RHI",
    flags := Context_Flags.ENABLE_DEBUG,
    debug_callback := DEFAULT_DEBUG_CALLBACK,
) -> VulkanContext {
    return Context(.VULKAN, name = name, flags = flags, debug_callback = debug_callback);
}

Destroy :: (ctx: *VulkanContext) {
    if ctx.debug_report_callback {
        destroy_cb: PFN_vkDestroyDebugReportCallbackEXT =
            xx vkGetInstanceProcAddr(ctx.instance, "vkDestroyDebugReportCallbackEXT");
        if destroy_cb then destroy_cb(ctx.instance, ctx.debug_report_callback, null);
        ctx.debug_report_callback = null;
    }
    if ctx.instance {
        vkDestroyInstance(ctx.instance, null);
        ctx.instance = null;
    }
}

VulkanDevice :: struct {
    vulkan_context: *VulkanContext;
    physical_device: VkPhysicalDevice;
    device: VkDevice;
    queue_family_index: u32;
    graphics_queue: VkQueue;
    name: string;
}

require_feature :: (ctx: *VulkanContext, f: Feature, loc := #caller_location) {
    flag := feature_to_flag(f);
    if (ctx.flags & flag) == 0 {
        assert(false, "feature not enabled on Context: % (at %:%)",
            f, loc.fully_pathed_filename, loc.line_number);
    }
}

Device :: (ctx: *VulkanContext) -> VulkanDevice {
    assert(ctx != null && ctx.instance != null, "Device: invalid context");
    dev: VulkanDevice;
    dev.vulkan_context = ctx;

    device_count: u32;
    vk_check(vkEnumeratePhysicalDevices(ctx.instance, *device_count, null));
    assert(device_count > 0, "No Vulkan physical devices");
    assert(device_count <= MAX_PHYSICAL_DEVICES, "Too many physical devices (%)", device_count);

    physical_devices: [MAX_PHYSICAL_DEVICES] VkPhysicalDevice;
    vk_check(vkEnumeratePhysicalDevices(ctx.instance, *device_count, physical_devices.data));
    dev.physical_device = physical_devices[0];

    props: VkPhysicalDeviceProperties;
    vkGetPhysicalDeviceProperties(dev.physical_device, *props);
    // Copy device name into a stable string for the caller.
    raw_name := to_string(props.deviceName.data);
    name_copy, _ := NewArray(raw_name.count, u8);
    memcpy(name_copy.data, raw_name.data, xx raw_name.count);
    dev.name = .{data = name_copy.data, count = raw_name.count};

    queue_family_count: u32;
    vkGetPhysicalDeviceQueueFamilyProperties(dev.physical_device, *queue_family_count, null);
    assert(queue_family_count <= MAX_QUEUE_FAMILIES, "Too many queue families (%)", queue_family_count);

    queue_families: [MAX_QUEUE_FAMILIES] VkQueueFamilyProperties;
    vkGetPhysicalDeviceQueueFamilyProperties(dev.physical_device, *queue_family_count, queue_families.data);

    found_graphics := false;
    default_queue_priority: float = 0.0;
    queue_create_info: VkDeviceQueueCreateInfo;
    for i: 0..queue_family_count-1 {
        if queue_families[i].queueFlags & .GRAPHICS_BIT {
            dev.queue_family_index = i;
            queue_create_info.queueFamilyIndex = i;
            queue_create_info.queueCount = 1;
            queue_create_info.pQueuePriorities = *default_queue_priority;
            found_graphics = true;
            break;
        }
    }
    assert(found_graphics, "No graphics queue family");

    device_create_info: VkDeviceCreateInfo;
    device_create_info.queueCreateInfoCount = 1;
    device_create_info.pQueueCreateInfos = *queue_create_info;

    draw_params: VkPhysicalDeviceShaderDrawParameterFeatures;
    draw_params.shaderDrawParameters = VK_TRUE;
    device_create_info.pNext = *draw_params;

    if (ctx.flags & .ENABLE_SURFACE) != 0 {
        device_exts: [1]*u8;
        device_exts[0] = VK_KHR_SWAPCHAIN_EXTENSION_NAME.data;
        device_create_info.enabledExtensionCount = 1;
        device_create_info.ppEnabledExtensionNames = device_exts.data;
    }

    vk_check(vkCreateDevice(dev.physical_device, *device_create_info, null, *dev.device));
    vkGetDeviceQueue(dev.device, dev.queue_family_index, 0, *dev.graphics_queue);
    return dev;
}

Destroy :: (dev: *VulkanDevice) {
    if !dev.device return;
    vkDeviceWaitIdle(dev.device);
    vkDestroyDevice(dev.device, null);
    if dev.name.data {
        free(dev.name.data);
        dev.name = .{};
    }
    dev.device = null;
    dev.graphics_queue = null;
}

// --- Buffers ---

VulkanBuffer :: struct {
    device: *VulkanDevice;
    size: s64;
    usage: BUFFER_USAGE;
    locality: DataLocality;
    buffer: VkBuffer;
    memory: VkDeviceMemory;
}

VulkanIndexBuffer :: struct($IndexT: Type) {
    device: *VulkanDevice;
    size: s64;
    count: s64;
    locality: DataLocality;
    buffer: VkBuffer;
    memory: VkDeviceMemory;
}

Buffer :: (dev: *VulkanDevice, data: [] $T, locality := DataLocality.CREATE_ON_DEVICE) -> VulkanIndexBuffer(T)
    #modify { return T == IndexU8_t || T == IndexU16_t || T == IndexU32_t; }
{
    assert(dev != null, "Buffer(index): invalid device");
    assert(data.count > 0, "Buffer(index): empty data");

    buf: VulkanIndexBuffer(T);
    buf.device = dev;
    buf.size = cast(s64) (data.count * size_of(T));
    buf.count = cast(s64) data.count;
    buf.locality = locality;

    create_vk_buffer(
        dev,
        .INDEX_BUFFER_BIT | .TRANSFER_DST_BIT,
        .DEVICE_LOCAL_BIT,
        *buf.buffer,
        *buf.memory,
        xx buf.size,
        null,
    );
    upload_buffer_data(dev, buf.buffer, xx buf.size, data.data);
    return buf;
}

Buffer :: (dev: *VulkanDevice, data: [] $T, locality := DataLocality.CREATE_ON_DEVICE) -> VulkanBuffer
    #modify { return T != IndexU8_t && T != IndexU16_t && T != IndexU32_t; }
{
    assert(dev != null, "Buffer: invalid device");
    assert(data.count > 0, "Buffer: empty data");

    usage := BUFFER_USAGE.VERTEX;
    #if #exists(T.GPU_USAGE) {
        usage = T.GPU_USAGE;
    }

    buf: VulkanBuffer;
    buf.device = dev;
    buf.size = cast(s64) (data.count * size_of(T));
    buf.usage = usage;
    buf.locality = locality;

    create_vk_buffer(
        dev,
        buffer_usage_to_vk(usage) | .TRANSFER_DST_BIT,
        .DEVICE_LOCAL_BIT,
        *buf.buffer,
        *buf.memory,
        xx buf.size,
        null,
    );
    upload_buffer_data(dev, buf.buffer, xx buf.size, data.data);
    return buf;
}

Destroy :: (buf: *VulkanBuffer) {
    if !buf.device || !buf.device.device return;
    if buf.buffer {
        vkDestroyBuffer(buf.device.device, buf.buffer, null);
        buf.buffer = null;
    }
    if buf.memory {
        vkFreeMemory(buf.device.device, buf.memory, null);
        buf.memory = null;
    }
}

Destroy :: (buf: *VulkanIndexBuffer($IndexT)) {
    if !buf.device || !buf.device.device return;
    if buf.buffer {
        vkDestroyBuffer(buf.device.device, buf.buffer, null);
        buf.buffer = null;
    }
    if buf.memory {
        vkFreeMemory(buf.device.device, buf.memory, null);
        buf.memory = null;
    }
}

Update :: (buf: *VulkanBuffer, data: [] $T) {
    assert(buf != null && buf.device != null, "Update(buffer): invalid buffer");
    assert(data.count > 0, "Update(buffer): empty data");
    needed := cast(s64) (data.count * size_of(T));
    assert(needed <= buf.size, "Update(buffer): data larger than buffer");
    upload_buffer_data(buf.device, buf.buffer, xx needed, data.data);
}

Update :: (buf: *VulkanIndexBuffer($IndexT), data: [] IndexT) {
    assert(buf != null && buf.device != null, "Update(index): invalid buffer");
    assert(data.count > 0, "Update(index): empty data");
    assert(cast(s64) data.count <= buf.count, "Update(index): too many indices");
    upload_buffer_data(buf.device, buf.buffer, xx (data.count * size_of(IndexT)), data.data);
}

// --- Textures ---

VulkanTexture2D :: struct {
    device: *VulkanDevice;
    size: Size2D;
    format: TextureFormat;
    locality: DataLocality;
    usage: TextureUsage;
    mips: u32;
    samples: u32;
    vk_format: VkFormat;
    image: VkImage;
    memory: VkDeviceMemory;
    view: VkImageView;
}

VulkanTexture3D :: struct {
    device: *VulkanDevice;
    size: Size3D;
    format: TextureFormat;
}

VulkanTextureCube :: struct {
    device: *VulkanDevice;
    size: SizeCube;
    format: TextureFormat;
}

texture_format_to_vk :: (format: TextureFormat) -> VkFormat {
    if format == {
        case .R8G8B8A8_UNORM;   return .R8G8B8A8_UNORM;
        case .B8G8R8A8_UNORM;   return .B8G8R8A8_UNORM;
        case .R32_SFLOAT;       return .R32_SFLOAT;
        case .D32_SFLOAT;       return .D32_SFLOAT;
        case .D24_UNORM_S8_UINT; return .D24_UNORM_S8_UINT;
    }
    return .R8G8B8A8_UNORM;
}

texture_usage_to_vk :: (usage: TextureUsage, format: TextureFormat) -> VkImageUsageFlags, VkImageAspectFlags {
    if (usage & .DEPTH_STENCIL) != 0 || format == .D32_SFLOAT || format == .D24_UNORM_S8_UINT {
        return .DEPTH_STENCIL_ATTACHMENT_BIT, depth_aspect_mask(texture_format_to_vk(format));
    }
    vk_usage: VkImageUsageFlags = xx 0;
    if (usage & .COLOR_ATTACHMENT) != 0 then vk_usage |= .COLOR_ATTACHMENT_BIT;
    if (usage & .SAMPLED) != 0 then vk_usage |= .SAMPLED_BIT;
    if (usage & .COPY_SRC) != 0 then vk_usage |= .TRANSFER_SRC_BIT;
    if (usage & .COPY_DST) != 0 then vk_usage |= .TRANSFER_DST_BIT;
    if (usage & .STORAGE) != 0 then vk_usage |= .STORAGE_BIT;
    if vk_usage == xx 0 {
        vk_usage = .COLOR_ATTACHMENT_BIT | .TRANSFER_SRC_BIT | .SAMPLED_BIT;
    }
    return vk_usage, .COLOR_BIT;
}

Texture :: (
    dev: *VulkanDevice,
    size: Size2D,
    format := TextureFormat.R8G8B8A8_UNORM,
    locality := DataLocality.CREATE_ON_DEVICE,
    usage := TextureUsage.COLOR_ATTACHMENT | TextureUsage.SAMPLED | TextureUsage.COPY_SRC,
    mips: u32 = 1,
    samples: u32 = 1,
) -> VulkanTexture2D {
    assert(dev != null, "Texture2D: invalid device");
    assert(size.x >= 1 && size.y >= 1, "Texture2D: size components must be >= 1");
    assert(mips >= 1 && samples >= 1, "Texture2D: mips/samples must be >= 1");
    assert(samples == 1, "Texture2D: MSAA samples > 1 not implemented yet");

    tex: VulkanTexture2D;
    tex.device = dev;
    tex.size = size;
    tex.format = format;
    tex.locality = locality;
    tex.usage = usage;
    tex.mips = mips;
    tex.samples = samples;
    if (usage & .DEPTH_STENCIL) != 0 {
        // Match Spawn / FrameBuffer compatible depth (device-preferred depth format).
        tex.vk_format = find_depth_format(dev.physical_device);
        assert(tex.vk_format != .UNDEFINED, "Texture2D: no supported depth format");
    } else {
        tex.vk_format = texture_format_to_vk(format);
    }
    vk_usage, aspect := texture_usage_to_vk(usage, format);
    if (usage & .DEPTH_STENCIL) != 0 {
        aspect = depth_aspect_mask(tex.vk_format);
        vk_usage = .DEPTH_STENCIL_ATTACHMENT_BIT;
    }
    create_image_2d(dev, *tex, tex.vk_format, size, vk_usage, aspect, mips);
    return tex;
}

Texture :: (
    dev: *VulkanDevice,
    size: Size3D,
    format := TextureFormat.R8G8B8A8_UNORM,
    locality := DataLocality.CREATE_ON_DEVICE,
    usage := TextureUsage.SAMPLED | TextureUsage.COPY_DST,
    mips: u32 = 1,
) -> VulkanTexture3D {
    _ := locality; _ := usage; _ := mips;
    not_implemented("Texture3D (Phase 2 headless milestone)");
    return VulkanTexture3D.{device = dev, size = size, format = format};
}

Texture :: (
    dev: *VulkanDevice,
    size: SizeCube,
    format := TextureFormat.R8G8B8A8_UNORM,
    locality := DataLocality.CREATE_ON_DEVICE,
    usage := TextureUsage.SAMPLED | TextureUsage.COPY_DST,
    mips: u32 = 1,
) -> VulkanTextureCube {
    _ := locality; _ := usage; _ := mips;
    not_implemented("TextureCube (Phase 2 headless milestone)");
    return VulkanTextureCube.{device = dev, size = size, format = format};
}

Destroy :: (tex: *VulkanTexture2D) {
    if !tex.device || !tex.device.device return;
    destroy_image_resources(tex.device.device, tex);
}

Destroy :: (tex: *VulkanTexture3D) { tex.* = .{}; }
Destroy :: (tex: *VulkanTextureCube) { tex.* = .{}; }

Get :: (tex: *VulkanTexture2D) -> [] u8 {
    assert(tex.device && tex.device.device, "Get: invalid texture");
    assert((tex.usage & .DEPTH_STENCIL) == 0, "Get: depth textures not readable as RGBA");
    dev := tex.device;
    device := dev.device;
    width := tex.size.x;
    height := tex.size.y;
    byte_count := cast(s64) (width * height * 4);

    img_create_info: VkImageCreateInfo;
    img_create_info.imageType = ._2D;
    img_create_info.format = .R8G8B8A8_UNORM;
    img_create_info.extent.width = width;
    img_create_info.extent.height = height;
    img_create_info.extent.depth = 1;
    img_create_info.arrayLayers = 1;
    img_create_info.mipLevels = 1;
    img_create_info.initialLayout = .UNDEFINED;
    img_create_info.samples = ._1_BIT;
    img_create_info.tiling = .LINEAR;
    img_create_info.usage = .TRANSFER_DST_BIT;

    dst_image: VkImage;
    vk_check(vkCreateImage(device, *img_create_info, null, *dst_image));
    defer vkDestroyImage(device, dst_image, null);

    mem_requirements: VkMemoryRequirements;
    mem_alloc_info: VkMemoryAllocateInfo;
    dst_image_memory: VkDeviceMemory;
    vkGetImageMemoryRequirements(device, dst_image, *mem_requirements);
    mem_alloc_info.allocationSize = mem_requirements.size;
    mem_alloc_info.memoryTypeIndex = get_memory_type_index(
        dev,
        mem_requirements.memoryTypeBits,
        .HOST_VISIBLE_BIT | .HOST_COHERENT_BIT,
    );
    vk_check(vkAllocateMemory(device, *mem_alloc_info, null, *dst_image_memory));
    defer vkFreeMemory(device, dst_image_memory, null);
    vk_check(vkBindImageMemory(device, dst_image, dst_image_memory, 0));

    pool, copy_cmd := create_command_pool_and_buffer(dev);
    defer vkDestroyCommandPool(device, pool, null);

    begin_info: VkCommandBufferBeginInfo;
    begin_info.flags = .ONE_TIME_SUBMIT_BIT;
    vk_check(vkBeginCommandBuffer(copy_cmd, *begin_info));

    color_range := VkImageSubresourceRange.{.COLOR_BIT, 0, 1, 0, 1};
    insert_image_memory_barrier(
        copy_cmd, dst_image,
        xx 0, .TRANSFER_WRITE_BIT,
        .UNDEFINED, .TRANSFER_DST_OPTIMAL,
        .TRANSFER_BIT, .TRANSFER_BIT,
        color_range,
    );

    image_copy_region: VkImageCopy;
    image_copy_region.srcSubresource.aspectMask = .COLOR_BIT;
    image_copy_region.srcSubresource.layerCount = 1;
    image_copy_region.dstSubresource.aspectMask = .COLOR_BIT;
    image_copy_region.dstSubresource.layerCount = 1;
    image_copy_region.extent.width = width;
    image_copy_region.extent.height = height;
    image_copy_region.extent.depth = 1;

    vkCmdCopyImage(
        copy_cmd,
        tex.image, .TRANSFER_SRC_OPTIMAL,
        dst_image, .TRANSFER_DST_OPTIMAL,
        1, *image_copy_region,
    );

    insert_image_memory_barrier(
        copy_cmd, dst_image,
        .TRANSFER_WRITE_BIT, .MEMORY_READ_BIT,
        .TRANSFER_DST_OPTIMAL, .GENERAL,
        .TRANSFER_BIT, .TRANSFER_BIT,
        color_range,
    );

    vk_check(vkEndCommandBuffer(copy_cmd));
    submit_work(dev, copy_cmd, wait = true);

    sub_resource: VkImageSubresource;
    sub_resource.aspectMask = .COLOR_BIT;
    sub_resource_layout: VkSubresourceLayout;
    vkGetImageSubresourceLayout(device, dst_image, *sub_resource, *sub_resource_layout);

    imagedata: *u8;
    vk_check(vkMapMemory(device, dst_image_memory, 0, VK_WHOLE_SIZE, 0, cast(**void) *imagedata));
    defer vkUnmapMemory(device, dst_image_memory);
    imagedata += sub_resource_layout.offset;

    out, _ := NewArray(byte_count, u8);
    row := imagedata;
    dst := out.data;
    for y: 0..height-1 {
        memcpy(dst, row, xx (width * 4));
        dst += width * 4;
        row += sub_resource_layout.rowPitch;
    }
    return out;
}

Update :: (tex: *VulkanTexture2D, pixels: [] u8) {
    assert(tex != null, "Update(texture2d): invalid texture");
    expected := cast(s64) (tex.size.x * tex.size.y * 4);
    assert(pixels.count >= expected, "Update(texture2d): pixel buffer too small");
    not_implemented("Update(texture2d) pixel upload");
}

// --- FrameBuffer ---

VulkanFrameBuffer :: struct($color_count: s64, $has_external_depth: bool) {
    device: *VulkanDevice;
    color0: *VulkanTexture2D;
    color1: *VulkanTexture2D;
    // External depth pointer (has_external_depth=true) OR unused when owns_depth.
    external_depth: *VulkanTexture2D;
    owned_depth: VulkanTexture2D;
    owns_depth: bool;
    render_pass: VkRenderPass;
    framebuffer: VkFramebuffer;
    clear_color: Color4;
}

framebuffer_depth :: (fb: *VulkanFrameBuffer($N, $has_external_depth)) -> *VulkanTexture2D {
    if fb.owns_depth return *fb.owned_depth;
    return fb.external_depth;
}

create_framebuffer_rp :: (
    fb: *$FB,
    color: *VulkanTexture2D,
    depth: *VulkanTexture2D,
) {
    dev := color.device;
    fb.device = dev;

    attachments: [2] VkAttachmentDescription;
    attachments[0].format = color.vk_format;
    attachments[0].samples = ._1_BIT;
    attachments[0].loadOp = .CLEAR;
    attachments[0].storeOp = .STORE;
    attachments[0].stencilLoadOp = .DONT_CARE;
    attachments[0].stencilStoreOp = .DONT_CARE;
    attachments[0].initialLayout = .UNDEFINED;
    attachments[0].finalLayout = .TRANSFER_SRC_OPTIMAL;

    attachments[1].format = depth.vk_format;
    attachments[1].samples = ._1_BIT;
    attachments[1].loadOp = .CLEAR;
    attachments[1].storeOp = .DONT_CARE;
    attachments[1].stencilLoadOp = .DONT_CARE;
    attachments[1].stencilStoreOp = .DONT_CARE;
    attachments[1].initialLayout = .UNDEFINED;
    attachments[1].finalLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

    color_ref := VkAttachmentReference.{0, .COLOR_ATTACHMENT_OPTIMAL};
    depth_ref := VkAttachmentReference.{1, .DEPTH_STENCIL_ATTACHMENT_OPTIMAL};

    subpass: VkSubpassDescription;
    subpass.pipelineBindPoint = .GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = *color_ref;
    subpass.pDepthStencilAttachment = *depth_ref;

    deps: [2] VkSubpassDependency;
    deps[0].srcSubpass = VK_SUBPASS_EXTERNAL;
    deps[0].dstSubpass = 0;
    deps[0].srcStageMask = .BOTTOM_OF_PIPE_BIT;
    deps[0].dstStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].srcAccessMask = .MEMORY_READ_BIT;
    deps[0].dstAccessMask = .COLOR_ATTACHMENT_READ_BIT | .COLOR_ATTACHMENT_WRITE_BIT;
    deps[0].dependencyFlags = .BY_REGION_BIT;

    deps[1].srcSubpass = 0;
    deps[1].dstSubpass = VK_SUBPASS_EXTERNAL;
    deps[1].srcStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[1].dstStageMask = .BOTTOM_OF_PIPE_BIT;
    deps[1].srcAccessMask = .COLOR_ATTACHMENT_READ_BIT | .COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].dstAccessMask = .MEMORY_READ_BIT;
    deps[1].dependencyFlags = .BY_REGION_BIT;

    rp_info: VkRenderPassCreateInfo;
    rp_info.attachmentCount = 2;
    rp_info.pAttachments = attachments.data;
    rp_info.subpassCount = 1;
    rp_info.pSubpasses = *subpass;
    rp_info.dependencyCount = 2;
    rp_info.pDependencies = deps.data;
    vk_check(vkCreateRenderPass(dev.device, *rp_info, null, *fb.render_pass));

    views := VkImageView.[color.view, depth.view];
    fb_info: VkFramebufferCreateInfo;
    fb_info.renderPass = fb.render_pass;
    fb_info.attachmentCount = 2;
    fb_info.pAttachments = views.data;
    fb_info.width = color.size.x;
    fb_info.height = color.size.y;
    fb_info.layers = 1;
    vk_check(vkCreateFramebuffer(dev.device, *fb_info, null, *fb.framebuffer));
}

FrameBuffer :: (c0: *VulkanTexture2D, clear_color := DEFAULT_CLEAR_COLOR) -> VulkanFrameBuffer(1, false) {
    assert(c0 != null, "FrameBuffer: color0 required");
    fb: VulkanFrameBuffer(1, false);
    fb.color0 = c0;
    fb.clear_color = clear_color;
    fb.owns_depth = true;

    depth_vk := find_depth_format(c0.device.physical_device);
    assert(depth_vk != .UNDEFINED, "No supported depth format");
    fb.owned_depth.device = c0.device;
    fb.owned_depth.size = c0.size;
    fb.owned_depth.format = .D32_SFLOAT;
    fb.owned_depth.usage = .DEPTH_STENCIL;
    fb.owned_depth.vk_format = depth_vk;
    create_image_2d(
        c0.device,
        *fb.owned_depth,
        depth_vk,
        c0.size,
        .DEPTH_STENCIL_ATTACHMENT_BIT,
        depth_aspect_mask(depth_vk),
        1,
    );
    create_framebuffer_rp(*fb, c0, *fb.owned_depth);
    return fb;
}

FrameBuffer :: (
    c0: *VulkanTexture2D,
    depth_texture: *VulkanTexture2D,
    clear_color := DEFAULT_CLEAR_COLOR,
) -> VulkanFrameBuffer(1, true) {
    assert(c0 != null && depth_texture != null, "FrameBuffer: color0 and depth required");
    assert((depth_texture.usage & .DEPTH_STENCIL) != 0, "FrameBuffer: depth_texture needs DEPTH_STENCIL usage");
    assert(c0.device == depth_texture.device, "FrameBuffer: textures must share a device");
    assert(c0.size.x == depth_texture.size.x && c0.size.y == depth_texture.size.y, "FrameBuffer: size mismatch");

    fb: VulkanFrameBuffer(1, true);
    fb.color0 = c0;
    fb.external_depth = depth_texture;
    fb.owns_depth = false;
    fb.clear_color = clear_color;
    create_framebuffer_rp(*fb, c0, depth_texture);
    return fb;
}

// MRT: 3-texture form only (2-color without depth collides with depth_texture overload).
FrameBuffer :: (
    c0: *VulkanTexture2D,
    c1: *VulkanTexture2D,
    depth_texture: *VulkanTexture2D,
    clear_color := DEFAULT_CLEAR_COLOR,
) -> VulkanFrameBuffer(2, true) {
    _ := c0; _ := c1; _ := depth_texture; _ := clear_color;
    not_implemented("FrameBuffer MRT+depth (later milestone)");
    return .{};
}

Destroy :: (fb: *VulkanFrameBuffer($N, $has_external_depth)) {
    if !fb.device || !fb.device.device return;
    device := fb.device.device;
    if fb.framebuffer {
        vkDestroyFramebuffer(device, fb.framebuffer, null);
        fb.framebuffer = null;
    }
    if fb.render_pass {
        vkDestroyRenderPass(device, fb.render_pass, null);
        fb.render_pass = null;
    }
    if fb.owns_depth {
        destroy_image_resources(device, *fb.owned_depth);
    }
}

// --- Shader ---

VulkanShader :: struct ($source: string, $stages: [] string) {
    device: *VulkanDevice;
    shader_module: VkShaderModule;
    pipeline_layout: VkPipelineLayout;
    pipeline: VkPipeline;
    compatible_render_pass: VkRenderPass;
    #insert -> string {
        blueprint := ShaderString(source, "embedded");
        return emit_vulkan_shader_members(blueprint, stages);
    }
}

emit_vulkan_shader_members :: (shader: ShaderBlueprint, stages: [] string) -> string {
    builder: String_Builder;

    has_vertex := false;
    for ep: shader.entry_points {
        if ep.type != .VERTEX_SHADER continue;
        if !stage_selected(ep.name, stages) continue;

        has_vertex = true;
        print_to_builder(*builder, "Vertex_t :: struct {\n");
        print_to_builder(*builder, "    GPU_USAGE :: BUFFER_USAGE.VERTEX;\n");
        for field: ep.inputs {
            print_to_builder(*builder, "    %: %;\n", field.name, type_info_source_name(field.type));
        }
        print_to_builder(*builder, "};\n\n");
        break;
    }
    if !has_vertex {
        // Compute-only (and other non-graphics) modules still need a Vertex_t member for the struct shape.
        print_to_builder(*builder, "Vertex_t :: struct {\n");
        print_to_builder(*builder, "    GPU_USAGE :: BUFFER_USAGE.VERTEX;\n");
        print_to_builder(*builder, "};\n\n");
    }

    emitted: [..]string;
    defer array_free(emitted);
    push_constant_bytes: u32 = 0;

    for ep: shader.entry_points {
        if !stage_selected(ep.name, stages) continue;
        for u: ep.uniforms {
            already := false;
            for e: emitted {
                if e == u.name {
                    already = true;
                    break;
                }
            }
            if already continue;
            array_add(*emitted, u.name);

            set_str := tprint("%", u.set);
            binding_str := tprint("%", u.binding);
            if u.set == VULKAN_UNIFORM_PUSH_CONSTANT {
                set_str = "VULKAN_UNIFORM_PUSH_CONSTANT";
                binding_str = "VULKAN_UNIFORM_PUSH_CONSTANT";
            }

            type_name := type_info_source_name(u.type);
            print_to_builder(*builder, "% :: VulkanShaderUniformDefinition.{\n", u.name);
            print_to_builder(*builder, "    name = \"%\",\n", u.name);
            print_to_builder(*builder, "    type = type_of(%),\n", type_name);
            print_to_builder(*builder, "    offset = %,\n", u.offset);
            print_to_builder(*builder, "    set = %,\n", set_str);
            print_to_builder(*builder, "    binding = %,\n", binding_str);
            print_to_builder(*builder, "    stage_flags = %,\n", u.stage_flags);
            print_to_builder(*builder, "};\n\n");

            if is_push_constant_meta(u.set, u.binding) {
                field_size := cast(u32) u.type.runtime_size;
                end := u.offset + field_size;
                if end > push_constant_bytes then push_constant_bytes = end;
            }
        }
    }

    vs_name := "";
    fs_name := "";
    cs_name := "";
    for ep: shader.entry_points {
        if !stage_selected(ep.name, stages) continue;
        if ep.type == .VERTEX_SHADER then vs_name = ep.name;
        if ep.type == .FRAGMENT_SHADER then fs_name = ep.name;
        if ep.type == .COMPUTE_SHADER then cs_name = ep.name;
    }
    print_to_builder(*builder, "vs_entry :: \"%\";\n", vs_name);
    print_to_builder(*builder, "fs_entry :: \"%\";\n", fs_name);
    print_to_builder(*builder, "cs_entry :: \"%\";\n", cs_name);
    print_to_builder(*builder, "is_compute :: %;\n", ifx cs_name.count && !vs_name.count then "true" else "false");
    if !push_constant_bytes then push_constant_bytes = xx size_of(Matrix4);
    print_to_builder(*builder, "push_constant_bytes :: %;\n\n", push_constant_bytes);

    print_to_builder(*builder, "spirv_raw :: u8.[\n");
    for i: 0..shader.spirv.count-1 {
        print_to_builder(*builder, "%,", shader.spirv[i]);
        if (i + 1) % 16 == 0 then print_to_builder(*builder, "\n");
    }
    print_to_builder(*builder, "\n];\n");

    return builder_to_string(*builder);
}

is_push_constant_meta :: (set: u32, binding: u32) -> bool {
    return set == VULKAN_UNIFORM_PUSH_CONSTANT && binding == VULKAN_UNIFORM_PUSH_CONSTANT;
}

stage_selected :: (entry_name: string, stages: [] string) -> bool {
    for s: stages {
        if s == entry_name return true;
    }
    return false;
}

Spawn :: (dev: *VulkanDevice, $source: string, $stages: [] string) -> VulkanShader(source, stages) {
    assert(dev != null, "Spawn: invalid device");
    assert(source.count > 0, "Spawn: empty shader source");
    assert(stages.count > 0, "Spawn: stages must be non-empty");

    Shader_t :: VulkanShader(source, stages);
    shdr: Shader_t;
    shdr.device = dev;

    assert(Shader_t.spirv_raw.count > 0, "Spawn: empty SPIR-V");

    module_info: VkShaderModuleCreateInfo;
    module_info.codeSize = xx Shader_t.spirv_raw.count;
    module_info.pCode = cast(*u32) Shader_t.spirv_raw.data;
    vk_check(vkCreateShaderModule(dev.device, *module_info, null, *shdr.shader_module));

    #if Shader_t.is_compute {
        // SPIR-V + module only for now. Compute pipelines need descriptor-set layouts for
        // storage buffers; full vkCreateComputePipelines comes with that work.
        cs_layout_info: VkPipelineLayoutCreateInfo;
        vk_check(vkCreatePipelineLayout(dev.device, *cs_layout_info, null, *shdr.pipeline_layout));
        return shdr;
    }

    push_constant_range: VkPushConstantRange;
    push_constant_range.stageFlags = .VERTEX_BIT | .FRAGMENT_BIT;
    push_constant_range.offset = 0;
    push_constant_range.size = Shader_t.push_constant_bytes;

    gfx_layout_info: VkPipelineLayoutCreateInfo;
    if Shader_t.push_constant_bytes {
        gfx_layout_info.pushConstantRangeCount = 1;
        gfx_layout_info.pPushConstantRanges = *push_constant_range;
    }
    vk_check(vkCreatePipelineLayout(dev.device, *gfx_layout_info, null, *shdr.pipeline_layout));

    depth_vk := find_depth_format(dev.physical_device);
    assert(depth_vk != .UNDEFINED, "No supported depth format");

    attachments: [2] VkAttachmentDescription;
    attachments[0].format = .R8G8B8A8_UNORM;
    attachments[0].samples = ._1_BIT;
    attachments[0].loadOp = .CLEAR;
    attachments[0].storeOp = .STORE;
    attachments[0].stencilLoadOp = .DONT_CARE;
    attachments[0].stencilStoreOp = .DONT_CARE;
    attachments[0].initialLayout = .UNDEFINED;
    attachments[0].finalLayout = .TRANSFER_SRC_OPTIMAL;

    attachments[1].format = depth_vk;
    attachments[1].samples = ._1_BIT;
    attachments[1].loadOp = .CLEAR;
    attachments[1].storeOp = .DONT_CARE;
    attachments[1].stencilLoadOp = .DONT_CARE;
    attachments[1].stencilStoreOp = .DONT_CARE;
    attachments[1].initialLayout = .UNDEFINED;
    attachments[1].finalLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

    color_ref := VkAttachmentReference.{0, .COLOR_ATTACHMENT_OPTIMAL};
    depth_ref := VkAttachmentReference.{1, .DEPTH_STENCIL_ATTACHMENT_OPTIMAL};

    subpass: VkSubpassDescription;
    subpass.pipelineBindPoint = .GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = *color_ref;
    subpass.pDepthStencilAttachment = *depth_ref;

    deps: [2] VkSubpassDependency;
    deps[0].srcSubpass = VK_SUBPASS_EXTERNAL;
    deps[0].dstSubpass = 0;
    deps[0].srcStageMask = .BOTTOM_OF_PIPE_BIT;
    deps[0].dstStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].srcAccessMask = .MEMORY_READ_BIT;
    deps[0].dstAccessMask = .COLOR_ATTACHMENT_READ_BIT | .COLOR_ATTACHMENT_WRITE_BIT;
    deps[0].dependencyFlags = .BY_REGION_BIT;

    deps[1].srcSubpass = 0;
    deps[1].dstSubpass = VK_SUBPASS_EXTERNAL;
    deps[1].srcStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[1].dstStageMask = .BOTTOM_OF_PIPE_BIT;
    deps[1].srcAccessMask = .COLOR_ATTACHMENT_READ_BIT | .COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].dstAccessMask = .MEMORY_READ_BIT;
    deps[1].dependencyFlags = .BY_REGION_BIT;

    rp_info: VkRenderPassCreateInfo;
    rp_info.attachmentCount = 2;
    rp_info.pAttachments = attachments.data;
    rp_info.subpassCount = 1;
    rp_info.pSubpasses = *subpass;
    rp_info.dependencyCount = 2;
    rp_info.pDependencies = deps.data;
    vk_check(vkCreateRenderPass(dev.device, *rp_info, null, *shdr.compatible_render_pass));

    binding := VkVertexInputBindingDescription.{
        binding = 0,
        stride = xx size_of(Shader_t.Vertex_t),
        inputRate = .VERTEX,
    };

    attrs: [..] VkVertexInputAttributeDescription;
    defer array_free(attrs);
    {
        info := type_info(Shader_t.Vertex_t);
        assert(info.type == .STRUCT, "Vertex_t must be a struct");
        si := cast(*Type_Info_Struct) info;
        loc: u32 = 0;
        for si.members {
            if it.flags & .CONSTANT continue;
            if it.flags & .OVERLAY continue;
            fmt := type_info_to_vk_format(it.type);
            array_add(*attrs, .{
                location = loc,
                binding = 0,
                format = fmt,
                offset = xx it.offset_in_bytes,
            });
            loc += 1;
        }
    }

    vertex_input_state: VkPipelineVertexInputStateCreateInfo;
    vertex_input_state.vertexBindingDescriptionCount = 1;
    vertex_input_state.pVertexBindingDescriptions = *binding;
    vertex_input_state.vertexAttributeDescriptionCount = xx attrs.count;
    vertex_input_state.pVertexAttributeDescriptions = attrs.data;

    input_assembly_state: VkPipelineInputAssemblyStateCreateInfo;
    input_assembly_state.topology = .TRIANGLE_LIST;

    rasterization_state: VkPipelineRasterizationStateCreateInfo;
    rasterization_state.depthClampEnable = VK_FALSE;
    rasterization_state.polygonMode = .FILL;
    rasterization_state.cullMode = .NONE;
    rasterization_state.frontFace = .COUNTER_CLOCKWISE;
    rasterization_state.lineWidth = 1.0;

    blend_attachment_state: VkPipelineColorBlendAttachmentState;
    blend_attachment_state.blendEnable = VK_FALSE;
    blend_attachment_state.colorWriteMask = xx 0xf;

    color_blend_state: VkPipelineColorBlendStateCreateInfo;
    color_blend_state.attachmentCount = 1;
    color_blend_state.pAttachments = *blend_attachment_state;

    depth_stencil_state: VkPipelineDepthStencilStateCreateInfo;
    depth_stencil_state.depthTestEnable = VK_TRUE;
    depth_stencil_state.depthWriteEnable = VK_TRUE;
    depth_stencil_state.depthCompareOp = .LESS_OR_EQUAL;

    viewport_state: VkPipelineViewportStateCreateInfo;
    viewport_state.viewportCount = 1;
    viewport_state.scissorCount = 1;

    multisample_state: VkPipelineMultisampleStateCreateInfo;
    multisample_state.rasterizationSamples = ._1_BIT;

    dynamic_state_enables := VkDynamicState.[.VIEWPORT, .SCISSOR];
    dynamic_state: VkPipelineDynamicStateCreateInfo;
    dynamic_state.dynamicStateCount = xx dynamic_state_enables.count;
    dynamic_state.pDynamicStates = dynamic_state_enables.data;

    shader_stages: [2] VkPipelineShaderStageCreateInfo;
    shader_stages[0].stage = .VERTEX_BIT;
    shader_stages[0].module = shdr.shader_module;
    shader_stages[0].pName = temp_c_string(Shader_t.vs_entry);
    shader_stages[1].stage = .FRAGMENT_BIT;
    shader_stages[1].module = shdr.shader_module;
    shader_stages[1].pName = temp_c_string(Shader_t.fs_entry);

    pipeline_create_info: VkGraphicsPipelineCreateInfo;
    pipeline_create_info.layout = shdr.pipeline_layout;
    pipeline_create_info.renderPass = shdr.compatible_render_pass;
    pipeline_create_info.basePipelineIndex = -1;
    pipeline_create_info.pInputAssemblyState = *input_assembly_state;
    pipeline_create_info.pRasterizationState = *rasterization_state;
    pipeline_create_info.pColorBlendState = *color_blend_state;
    pipeline_create_info.pMultisampleState = *multisample_state;
    pipeline_create_info.pViewportState = *viewport_state;
    pipeline_create_info.pDepthStencilState = *depth_stencil_state;
    pipeline_create_info.pDynamicState = *dynamic_state;
    pipeline_create_info.stageCount = 2;
    pipeline_create_info.pStages = shader_stages.data;
    pipeline_create_info.pVertexInputState = *vertex_input_state;

    vk_check(vkCreateGraphicsPipelines(dev.device, null, 1, *pipeline_create_info, null, *shdr.pipeline));
    return shdr;
}

Destroy :: (shdr: *VulkanShader($source, $stages)) {
    if !shdr.device || !shdr.device.device return;
    device := shdr.device.device;
    if shdr.pipeline {
        vkDestroyPipeline(device, shdr.pipeline, null);
        shdr.pipeline = null;
    }
    if shdr.pipeline_layout {
        vkDestroyPipelineLayout(device, shdr.pipeline_layout, null);
        shdr.pipeline_layout = null;
    }
    if shdr.shader_module {
        vkDestroyShaderModule(device, shdr.shader_module, null);
        shdr.shader_module = null;
    }
    if shdr.compatible_render_pass {
        vkDestroyRenderPass(device, shdr.compatible_render_pass, null);
        shdr.compatible_render_pass = null;
    }
}

// --- Queues / Passes ---

VulkanGraphicsQueue :: struct {
    device: *VulkanDevice;
    command_pool: VkCommandPool;
    cmd: VkCommandBuffer;
    render_pass_active: bool;
    bound_framebuffer_color: *VulkanTexture2D;
    bound_clear: Color4;
    bound_render_pass: VkRenderPass;
    bound_framebuffer: VkFramebuffer;
    index_count: u32;
}

VulkanComputeQueue :: struct {
    device: *VulkanDevice;
}

VulkanCopyQueue :: struct {
    device: *VulkanDevice;
}

VulkanGraphicsPass :: struct($source: string, $stages: [] string) {
    queue: *VulkanGraphicsQueue;
    shader: *VulkanShader(source, stages);
}

VulkanComputePass :: struct($source: string, $stages: [] string) {
    queue: *VulkanComputeQueue;
    shader: *VulkanShader(source, stages);
}

Queue :: (dev: *VulkanDevice, $type: QUEUE_TYPE) -> VulkanGraphicsQueue
    #modify { return type == .GRAPHICS; }
{
    assert(dev != null, "Queue(GRAPHICS): invalid device");
    pool, cmd := create_command_pool_and_buffer(dev);
    begin_info: VkCommandBufferBeginInfo;
    vk_check(vkBeginCommandBuffer(cmd, *begin_info));
    return VulkanGraphicsQueue.{
        device = dev,
        command_pool = pool,
        cmd = cmd,
        render_pass_active = false,
        index_count = 0,
    };
}

Queue :: (dev: *VulkanDevice, $type: QUEUE_TYPE) -> VulkanComputeQueue
    #modify { return type == .COMPUTE; }
{
    assert(dev != null, "Queue(COMPUTE): invalid device");
    // Dispatch path stubbed for this milestone; Spawn(compute) still builds a compute pipeline.
    return VulkanComputeQueue.{device = dev};
}

Queue :: (dev: *VulkanDevice, $type: QUEUE_TYPE) -> VulkanCopyQueue
    #modify { return type == .COPY; }
{
    assert(dev != null, "Queue(COPY): invalid device");
    return VulkanCopyQueue.{device = dev};
}

Bind :: (q: *VulkanGraphicsQueue, frm_buf: *VulkanFrameBuffer($N, $has_external_depth)) {
    assert(q != null && frm_buf != null, "Bind: invalid args");
    color := frm_buf.color0;

    clear_values: [2] VkClearValue;
    clear_values[0].color._float32 = float.[
        frm_buf.clear_color.r, frm_buf.clear_color.g, frm_buf.clear_color.b, frm_buf.clear_color.a,
    ];
    clear_values[1].depthStencil = .{1.0, 0};

    begin_info: VkRenderPassBeginInfo;
    begin_info.renderPass = frm_buf.render_pass;
    begin_info.framebuffer = frm_buf.framebuffer;
    begin_info.renderArea.extent.width = color.size.x;
    begin_info.renderArea.extent.height = color.size.y;
    begin_info.clearValueCount = 2;
    begin_info.pClearValues = clear_values.data;
    vkCmdBeginRenderPass(q.cmd, *begin_info, .INLINE);

    q.render_pass_active = true;
    q.bound_framebuffer_color = color;
    q.bound_clear = frm_buf.clear_color;
    q.bound_render_pass = frm_buf.render_pass;
    q.bound_framebuffer = frm_buf.framebuffer;
    q.index_count = 0;
}

Pass :: (q: *VulkanGraphicsQueue, shdr: *VulkanShader($source, $stages)) -> [1] VulkanGraphicsPass(source, stages) {
    assert(q != null && shdr != null, "Pass(Graphics): invalid args");
    assert(q.render_pass_active, "Pass(Graphics): Bind FrameBuffer first");

    vkCmdBindPipeline(q.cmd, .GRAPHICS, shdr.pipeline);

    tex := q.bound_framebuffer_color;
    viewport: VkViewport;
    viewport.x = 0;
    viewport.y = 0;
    viewport.width = cast(float) tex.size.x;
    viewport.height = cast(float) tex.size.y;
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    vkCmdSetViewport(q.cmd, 0, 1, *viewport);

    scissor: VkRect2D;
    scissor.offset.x = 0;
    scissor.offset.y = 0;
    scissor.extent.width = tex.size.x;
    scissor.extent.height = tex.size.y;
    vkCmdSetScissor(q.cmd, 0, 1, *scissor);

    return .[VulkanGraphicsPass(source, stages).{ queue = q, shader = shdr }];
}

Pass :: (q: *VulkanComputeQueue, shdr: *VulkanShader($source, $stages)) -> [1] VulkanComputePass(source, stages) {
    assert(q != null && shdr != null, "Pass(Compute): invalid args");
    // Full compute dispatch (descriptors / vkCmdDispatch) comes later.
    return .[VulkanComputePass(source, stages).{ queue = q, shader = shdr }];
}

Set :: (pass: VulkanComputePass($source, $stages), buf: *VulkanBuffer) {
    assert(buf != null, "Set(compute buffer): invalid buffer");
    _ := pass;
}

Set :: (buf: *VulkanBuffer) #expand {
    Set(`it, buf);
}

Set :: (buf: *VulkanIndexBuffer($IndexT)) #expand {
    Set(`it, buf);
}

Set :: (pass: VulkanGraphicsPass($source, $stages), buf: *VulkanBuffer) {
    q := pass.queue;
    if buf.usage == .VERTEX {
        offsets := VkDeviceSize.[0];
        vkCmdBindVertexBuffers(q.cmd, 0, 1, *buf.buffer, offsets.data);
    } else {
        assert(false, "Set(buffer): expected VERTEX (use Buffer(*dev, []IndexU*_t) for indices)");
    }
}

Set :: (pass: VulkanGraphicsPass($source, $stages), buf: *VulkanIndexBuffer($IndexT)) {
    q := pass.queue;
    index_type := VkIndexType.UINT32;
    #if IndexT == IndexU16_t {
        index_type = .UINT16;
    } else #if IndexT == IndexU32_t {
        index_type = .UINT32;
    } else {
        assert(false, "Set(index): IndexU8_t requires VK_EXT_index_type_uint8 (not enabled)");
    }
    vkCmdBindIndexBuffer(q.cmd, buf.buffer, 0, index_type);
    q.index_count = cast(u32) buf.count;
}

Set :: (def: UniformDefinition, val: $T) #expand {
    Set(`it, def, val);
}

Set :: (pass: VulkanGraphicsPass($source, $stages), def: UniformDefinition, val: $T) {
    assert(is_push_constant(def), "Set(uniform): UBO path not implemented yet — use entry-point uniform");
    q := pass.queue;
    shdr := pass.shader;
    // Must cover every stage bit in the overlapping VkPushConstantRange (Spawn uses VERTEX|FRAGMENT).
    vkCmdPushConstants(
        q.cmd,
        shdr.pipeline_layout,
        .VERTEX_BIT | .FRAGMENT_BIT,
        def.offset,
        xx size_of(T),
        *val,
    );
}

Record :: () #expand {
    Record(`it);
}

Record :: (pass: VulkanGraphicsPass($source, $stages)) {
    q := pass.queue;
    assert(q.index_count > 0, "Record: no index buffer Set");
    vkCmdDrawIndexed(q.cmd, q.index_count, 1, 0, 0, 0);
}

Submit :: (q: *VulkanGraphicsQueue, wait := true) {
    assert(q != null, "Submit(Graphics): invalid queue");
    if q.render_pass_active {
        vkCmdEndRenderPass(q.cmd);
        q.render_pass_active = false;
    }
    vk_check(vkEndCommandBuffer(q.cmd));
    submit_work(q.device, q.cmd, wait);

    if (q.device.vulkan_context.flags & .ENABLE_DEBUG) != 0 {
        q.device.vulkan_context.debug_callback(tprint("Submit(Graphics): done wait=%", wait));
    }

    if q.command_pool {
        vkDestroyCommandPool(q.device.device, q.command_pool, null);
        q.command_pool = null;
        q.cmd = null;
    }
}

Submit :: (q: *VulkanComputeQueue, groups_x: u32, groups_y: u32 = 1, groups_z: u32 = 1, wait := true) {
    assert(q != null, "Submit(Compute): invalid queue");
    assert(groups_x >= 1 && groups_y >= 1 && groups_z >= 1, "Submit(Compute): group counts must be >= 1");
    _ := wait;
    if (q.device.vulkan_context.flags & .ENABLE_DEBUG) != 0 {
        q.device.vulkan_context.debug_callback(
            tprint("Submit(Compute): groups %,%,% (dispatch stub)", groups_x, groups_y, groups_z),
        );
    }
}

Submit :: (q: *VulkanCopyQueue, wait := true) {
    assert(q != null, "Submit(Copy): invalid queue");
    _ := wait;
    if (q.device.vulkan_context.flags & .ENABLE_DEBUG) != 0 {
        q.device.vulkan_context.debug_callback("Submit(Copy): stub");
    }
}

VulkanSurface :: struct {
    device: *VulkanDevice;
    width: u32;
    height: u32;
}

Surface :: (dev: *VulkanDevice, width: u32, height: u32) -> VulkanSurface {
    _ := width; _ := height;
    require_feature(dev.vulkan_context, .SURFACE);
    not_implemented("Surface (needs CrossWindow)");
    return VulkanSurface.{device = dev, width = width, height = height};
}

Destroy :: (srf: *VulkanSurface) {
    srf.* = .{};
}

Present :: (srf: *VulkanSurface, tex: *VulkanTexture2D, fps: u32 = 60) {
    _ := srf; _ := tex; _ := fps;
    not_implemented("Present (needs CrossWindow / swapchain)");
}

#scope_file

vk_check :: (result: VkResult, loc := #caller_location) {
    if result != .SUCCESS {
        log_error("Fatal: VkResult is % (%) at %:%\n", result, cast(s32) result, loc.fully_pathed_filename, loc.line_number);
        exit(1);
    }
}

vulkan_debug_message_callback :: (
    flags: VkDebugReportFlagsEXT,
    objectType: VkDebugReportObjectTypeEXT,
    object: u64,
    location: u64,
    messageCode: s32,
    pLayerPrefix: *u8,
    pMessage: *u8,
    pUserData: *void
) -> VkBool32 #c_call {
    push_context {
        print("[VALIDATION]: % - %\n", to_string(pLayerPrefix), to_string(pMessage));
    }
    return VK_FALSE;
}

get_memory_type_index :: (dev: *VulkanDevice, type_bits: u32, properties: VkMemoryPropertyFlags) -> u32 {
    mem_props: VkPhysicalDeviceMemoryProperties;
    vkGetPhysicalDeviceMemoryProperties(dev.physical_device, *mem_props);

    bits := type_bits;
    for i: 0..mem_props.memoryTypeCount - 1 {
        if (bits & 1) == 1 {
            if (mem_props.memoryTypes[i].propertyFlags & properties) == properties {
                return i;
            }
        }
        bits >>= 1;
    }
    assert(false, "No matching memory type");
    return 0;
}

create_vk_buffer :: (
    dev: *VulkanDevice,
    usage_flags: VkBufferUsageFlags,
    memory_property_flags: VkMemoryPropertyFlags,
    buffer: *VkBuffer,
    memory: *VkDeviceMemory,
    size: VkDeviceSize,
    data: *void = null
) {
    buffer_create_info: VkBufferCreateInfo;
    buffer_create_info.size = size;
    buffer_create_info.usage = usage_flags;
    buffer_create_info.sharingMode = .EXCLUSIVE;
    vk_check(vkCreateBuffer(dev.device, *buffer_create_info, null, buffer));

    mem_reqs: VkMemoryRequirements;
    mem_alloc: VkMemoryAllocateInfo;
    vkGetBufferMemoryRequirements(dev.device, buffer.*, *mem_reqs);
    mem_alloc.allocationSize = mem_reqs.size;
    mem_alloc.memoryTypeIndex = get_memory_type_index(dev, mem_reqs.memoryTypeBits, memory_property_flags);
    vk_check(vkAllocateMemory(dev.device, *mem_alloc, null, memory));

    if data {
        mapped: *void;
        vk_check(vkMapMemory(dev.device, memory.*, 0, size, 0, *mapped));
        memcpy(mapped, data, xx size);
        vkUnmapMemory(dev.device, memory.*);
    }

    vk_check(vkBindBufferMemory(dev.device, buffer.*, memory.*, 0));
}

upload_buffer_data :: (dev: *VulkanDevice, dst: VkBuffer, size: VkDeviceSize, data: *void) {
    staging: VkBuffer;
    staging_mem: VkDeviceMemory;
    create_vk_buffer(
        dev,
        .TRANSFER_SRC_BIT,
        .HOST_VISIBLE_BIT | .HOST_COHERENT_BIT,
        *staging,
        *staging_mem,
        size,
        data,
    );

    upload_pool, upload_cmd := create_command_pool_and_buffer(dev);
    begin_info: VkCommandBufferBeginInfo;
    begin_info.flags = .ONE_TIME_SUBMIT_BIT;
    vk_check(vkBeginCommandBuffer(upload_cmd, *begin_info));

    copy_region: VkBufferCopy;
    copy_region.size = size;
    vkCmdCopyBuffer(upload_cmd, staging, dst, 1, *copy_region);

    vk_check(vkEndCommandBuffer(upload_cmd));
    submit_work(dev, upload_cmd, wait = true);
    vkDestroyCommandPool(dev.device, upload_pool, null);

    vkDestroyBuffer(dev.device, staging, null);
    vkFreeMemory(dev.device, staging_mem, null);
}

submit_work :: (dev: *VulkanDevice, cmd_buffer: VkCommandBuffer, wait: bool) {
    submit_info: VkSubmitInfo;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = *cmd_buffer;

    if wait {
        fence_info: VkFenceCreateInfo;
        fence: VkFence;
        vk_check(vkCreateFence(dev.device, *fence_info, null, *fence));
        vk_check(vkQueueSubmit(dev.graphics_queue, 1, *submit_info, fence));
        vk_check(vkWaitForFences(dev.device, 1, *fence, VK_TRUE, 0xffff_ffff_ffff_ffff));
        vkDestroyFence(dev.device, fence, null);
    } else {
        vk_check(vkQueueSubmit(dev.graphics_queue, 1, *submit_info, null));
    }
}

create_command_pool_and_buffer :: (dev: *VulkanDevice) -> VkCommandPool, VkCommandBuffer {
    pool_info: VkCommandPoolCreateInfo;
    pool_info.queueFamilyIndex = dev.queue_family_index;
    pool_info.flags = .RESET_COMMAND_BUFFER_BIT | .TRANSIENT_BIT;

    pool: VkCommandPool;
    vk_check(vkCreateCommandPool(dev.device, *pool_info, null, *pool));

    alloc_info: VkCommandBufferAllocateInfo;
    alloc_info.commandPool = pool;
    alloc_info.level = .PRIMARY;
    alloc_info.commandBufferCount = 1;

    cmd: VkCommandBuffer;
    vk_check(vkAllocateCommandBuffers(dev.device, *alloc_info, *cmd));
    return pool, cmd;
}

buffer_usage_to_vk :: (usage: BUFFER_USAGE) -> VkBufferUsageFlags {
    if usage == {
    case .VERTEX;  return .VERTEX_BUFFER_BIT;
    case .INDEX;   return .INDEX_BUFFER_BIT;
    case .UNIFORM; return .UNIFORM_BUFFER_BIT;
    case .STORAGE; return .STORAGE_BUFFER_BIT;
    case;          return .STORAGE_BUFFER_BIT;
    }
}

find_depth_format :: (physical_device: VkPhysicalDevice) -> VkFormat {
    candidates := VkFormat.[
        .D32_SFLOAT_S8_UINT,
        .D32_SFLOAT,
        .D24_UNORM_S8_UINT,
        .D16_UNORM_S8_UINT,
        .D16_UNORM,
    ];
    for candidates {
        format_props: VkFormatProperties;
        vkGetPhysicalDeviceFormatProperties(physical_device, it, *format_props);
        if format_props.optimalTilingFeatures & .DEPTH_STENCIL_ATTACHMENT_BIT {
            return it;
        }
    }
    return .UNDEFINED;
}

depth_aspect_mask :: (format: VkFormat) -> VkImageAspectFlags {
    aspect: VkImageAspectFlags = .DEPTH_BIT;
    if cast(u32) format >= cast(u32) VkFormat.D16_UNORM_S8_UINT {
        aspect |= .STENCIL_BIT;
    }
    return aspect;
}

create_image_2d :: (
    dev: *VulkanDevice,
    tex: *VulkanTexture2D,
    vk_format: VkFormat,
    size: Size2D,
    usage: VkImageUsageFlags,
    aspect: VkImageAspectFlags,
    mips: u32,
) {
    image_info: VkImageCreateInfo;
    image_info.imageType = ._2D;
    image_info.format = vk_format;
    image_info.extent.width = size.x;
    image_info.extent.height = size.y;
    image_info.extent.depth = 1;
    image_info.mipLevels = mips;
    image_info.arrayLayers = 1;
    image_info.samples = ._1_BIT;
    image_info.tiling = .OPTIMAL;
    image_info.usage = usage;

    vk_check(vkCreateImage(dev.device, *image_info, null, *tex.image));

    mem_reqs: VkMemoryRequirements;
    mem_alloc: VkMemoryAllocateInfo;
    vkGetImageMemoryRequirements(dev.device, tex.image, *mem_reqs);
    mem_alloc.allocationSize = mem_reqs.size;
    mem_alloc.memoryTypeIndex = get_memory_type_index(dev, mem_reqs.memoryTypeBits, .DEVICE_LOCAL_BIT);
    vk_check(vkAllocateMemory(dev.device, *mem_alloc, null, *tex.memory));
    vk_check(vkBindImageMemory(dev.device, tex.image, tex.memory, 0));

    view_info: VkImageViewCreateInfo;
    view_info.viewType = ._2D;
    view_info.format = vk_format;
    view_info.subresourceRange.aspectMask = aspect;
    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = mips;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 1;
    view_info.image = tex.image;
    vk_check(vkCreateImageView(dev.device, *view_info, null, *tex.view));
}

destroy_image_resources :: (device: VkDevice, tex: *VulkanTexture2D) {
    if tex.view {
        vkDestroyImageView(device, tex.view, null);
        tex.view = null;
    }
    if tex.image {
        vkDestroyImage(device, tex.image, null);
        tex.image = null;
    }
    if tex.memory {
        vkFreeMemory(device, tex.memory, null);
        tex.memory = null;
    }
}

insert_image_memory_barrier :: (
    cmdbuffer: VkCommandBuffer,
    image: VkImage,
    src_access_mask: VkAccessFlags,
    dst_access_mask: VkAccessFlags,
    old_image_layout: VkImageLayout,
    new_image_layout: VkImageLayout,
    src_stage_mask: VkPipelineStageFlags,
    dst_stage_mask: VkPipelineStageFlags,
    subresource_range: VkImageSubresourceRange
) {
    barrier: VkImageMemoryBarrier;
    barrier.srcAccessMask = src_access_mask;
    barrier.dstAccessMask = dst_access_mask;
    barrier.oldLayout = old_image_layout;
    barrier.newLayout = new_image_layout;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image;
    barrier.subresourceRange = subresource_range;

    vkCmdPipelineBarrier(
        cmdbuffer,
        src_stage_mask,
        dst_stage_mask,
        xx 0,
        0, null,
        0, null,
        1, *barrier
    );
}

type_info_to_vk_format :: (info: *Type_Info) -> VkFormat {
    if info.runtime_size == size_of(float) return .R32_SFLOAT;
    if info.runtime_size == size_of(Vector2) return .R32G32_SFLOAT;
    if info.runtime_size == size_of(Vector3) return .R32G32B32_SFLOAT;
    if info.runtime_size == size_of(Vector4) return .R32G32B32A32_SFLOAT;
    assert(false, "Unsupported vertex attribute type (size %)", info.runtime_size);
    return .UNDEFINED;
}
