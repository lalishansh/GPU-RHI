// Vulkan host backend — Context → Device → Texture → Buffer → Spawn → Queue →
// Pass → Submit → Get / Surface → Present (CrossWindow X11).

MAX_INSTANCE_LAYERS :: 64;
MAX_PHYSICAL_DEVICES :: 8;
MAX_QUEUE_FAMILIES :: 16;

#if OS == .LINUX {
    VkXlibSurfaceCreateFlagsKHR :: u32;

    VkXlibSurfaceCreateInfoKHR :: struct {
        sType:  VkStructureType;
        pNext:  *void;
        flags:  VkXlibSurfaceCreateFlagsKHR;
        dpy:    *X11.Display;
        window: X11.Window;
    }

    PFN_vkCreateXlibSurfaceKHR :: #type (
        instance: VkInstance,
        pCreateInfo: *VkXlibSurfaceCreateInfoKHR,
        pAllocator: *VkAllocationCallbacks,
        pSurface: *VkSurfaceKHR,
    ) -> VkResult #c_call;
}

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
            // Enable every WSI platform extension the loader exposes (X11 + Wayland today).
            add_available_instance_extensions(*ext_names, string.[
                "VK_KHR_xlib_surface",
                "VK_KHR_wayland_surface",
            ]);
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

    enabled_features: VkPhysicalDeviceFeatures;
    if (ctx.flags & .ENABLE_TESSELLATION) != 0 {
        enabled_features.tessellationShader = VK_TRUE;
    }
    device_create_info.pEnabledFeatures = *enabled_features;

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
    locality: DataLocality;
    usage: TextureUsage;
    mips: u32;
    vk_format: VkFormat;
    image: VkImage;
    memory: VkDeviceMemory;
    view: VkImageView;
}

VulkanTextureCube :: struct {
    device: *VulkanDevice;
    size: SizeCube;
    format: TextureFormat;
    locality: DataLocality;
    usage: TextureUsage;
    mips: u32;
    vk_format: VkFormat;
    image: VkImage;
    memory: VkDeviceMemory;
    view: VkImageView;
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
    assert(samples == 1 || samples == 2 || samples == 4 || samples == 8,
        "Texture2D: unsupported sample count %", samples);
    assert(samples == 1 || mips == 1, "Texture2D: MSAA requires mips == 1");

    // Host-locality images are still device images; mark them copy-dst so Update can upload.
    if locality == .CREATE_ON_HOST {
        usage |= .COPY_DST;
    }

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
    create_image_2d(dev, *tex, tex.vk_format, size, vk_usage, aspect, mips, samples);
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
    assert(dev != null, "Texture3D: invalid device");
    assert(size.x >= 1 && size.y >= 1 && size.z >= 1, "Texture3D: size components must be >= 1");
    assert(mips >= 1, "Texture3D: mips must be >= 1");
    assert((usage & .DEPTH_STENCIL) == 0, "Texture3D: depth volumes not supported yet");

    if locality == .CREATE_ON_HOST {
        usage |= .COPY_DST;
    }

    tex: VulkanTexture3D;
    tex.device = dev;
    tex.size = size;
    tex.format = format;
    tex.locality = locality;
    tex.usage = usage;
    tex.mips = mips;
    tex.vk_format = texture_format_to_vk(format);
    vk_usage, aspect := texture_usage_to_vk(usage, format);
    create_image_3d(dev, *tex, tex.vk_format, size, vk_usage, aspect, mips);
    return tex;
}

Texture :: (
    dev: *VulkanDevice,
    size: SizeCube,
    format := TextureFormat.R8G8B8A8_UNORM,
    locality := DataLocality.CREATE_ON_DEVICE,
    usage := TextureUsage.SAMPLED | TextureUsage.COPY_DST,
    mips: u32 = 1,
) -> VulkanTextureCube {
    assert(dev != null, "TextureCube: invalid device");
    assert(size.face >= 1, "TextureCube: face size must be >= 1");
    assert(mips >= 1, "TextureCube: mips must be >= 1");
    assert((usage & .DEPTH_STENCIL) == 0, "TextureCube: depth cubes not supported yet");

    if locality == .CREATE_ON_HOST {
        usage |= .COPY_DST;
    }

    tex: VulkanTextureCube;
    tex.device = dev;
    tex.size = size;
    tex.format = format;
    tex.locality = locality;
    tex.usage = usage;
    tex.mips = mips;
    tex.vk_format = texture_format_to_vk(format);
    vk_usage, aspect := texture_usage_to_vk(usage, format);
    create_image_cube(dev, *tex, tex.vk_format, size, vk_usage, aspect, mips);
    return tex;
}

Destroy :: (tex: *VulkanTexture2D) {
    if !tex.device || !tex.device.device return;
    destroy_image_resources(tex.device.device, tex.image, tex.view, tex.memory);
    tex.image = null; tex.view = null; tex.memory = null;
}

Destroy :: (tex: *VulkanTexture3D) {
    if !tex.device || !tex.device.device return;
    destroy_image_resources(tex.device.device, tex.image, tex.view, tex.memory);
    tex.* = .{};
}

Destroy :: (tex: *VulkanTextureCube) {
    if !tex.device || !tex.device.device return;
    destroy_image_resources(tex.device.device, tex.image, tex.view, tex.memory);
    tex.* = .{};
}

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
    assert(tex != null && tex.device && tex.device.device, "Update(texture2d): invalid texture");
    assert((tex.usage & .DEPTH_STENCIL) == 0, "Update(texture2d): depth textures not supported");
    assert(tex.samples == 1, "Update(texture2d): MSAA textures not supported");
    assert((tex.usage & .COPY_DST) != 0, "Update(texture2d): texture needs COPY_DST usage");
    assert(tex.format == .R8G8B8A8_UNORM || tex.format == .B8G8R8A8_UNORM,
        "Update(texture2d): only RGBA8/BGRA8 uploads for now");

    expected := cast(s64) (tex.size.x * tex.size.y * 4);
    assert(pixels.count >= expected, "Update(texture2d): pixel buffer too small (need %)", expected);

    upload_image_2d_data(tex.device, tex.image, tex.size.x, tex.size.y, 1, pixels.data, expected);
}

Update :: (tex: *VulkanTexture2D, new_size: Size2D) {
    assert(tex != null && tex.device && tex.device.device, "Update(texture2d size): invalid texture");
    assert(new_size.x >= 1 && new_size.y >= 1, "Update(texture2d size): size >= 1");
    if tex.size.x == new_size.x && tex.size.y == new_size.y return;

    destroy_image_resources(tex.device.device, tex.image, tex.view, tex.memory);
    tex.image = null; tex.view = null; tex.memory = null;
    tex.size = new_size;

    vk_usage, aspect := texture_usage_to_vk(tex.usage, tex.format);
    if (tex.usage & .DEPTH_STENCIL) != 0 {
        aspect = depth_aspect_mask(tex.vk_format);
        vk_usage = .DEPTH_STENCIL_ATTACHMENT_BIT;
    }
    create_image_2d(tex.device, tex, tex.vk_format, new_size, vk_usage, aspect, tex.mips, tex.samples);
}

Update :: (tex: *VulkanTexture3D, new_size: Size3D) {
    assert(tex != null && tex.device && tex.device.device, "Update(texture3d size): invalid texture");
    assert(new_size.x >= 1 && new_size.y >= 1 && new_size.z >= 1, "Update(texture3d size): size >= 1");
    if tex.size.x == new_size.x && tex.size.y == new_size.y && tex.size.z == new_size.z return;

    destroy_image_resources(tex.device.device, tex.image, tex.view, tex.memory);
    tex.image = null; tex.view = null; tex.memory = null;
    tex.size = new_size;

    vk_usage, aspect := texture_usage_to_vk(tex.usage, tex.format);
    create_image_3d(tex.device, tex, tex.vk_format, new_size, vk_usage, aspect, tex.mips);
}

// --- FrameBuffer ---
// $has_depth = whether the render pass includes a depth attachment (depth testing).

VulkanFrameBuffer :: struct($color_count: s64, $has_depth: bool) {
    device: *VulkanDevice;
    color_textures: [color_count] *VulkanTexture2D;
    #if has_depth {
        depth_texture: *VulkanTexture2D;
        _owned_depth: VulkanTexture2D; // backing store when FrameBuffer creates depth
        owns_depth: bool;
    }
    render_pass: VkRenderPass;
    framebuffer: VkFramebuffer;
    clear_color: Color4;
}

// FrameBuffer is returned by value; `depth_texture = *_owned_depth` would dangle after the
// temporary is copied. Always re-seat owned depth to the live struct before use.
framebuffer_depth :: (fb: *VulkanFrameBuffer($N, $has_depth)) -> *VulkanTexture2D {
    #if has_depth {
        if fb.owns_depth {
            fb.depth_texture = *fb._owned_depth;
        }
        return fb.depth_texture;
    }
    #if !has_depth return null;
}

create_framebuffer_vk :: (fb: *VulkanFrameBuffer($N, $has_depth)) {
    assert(N >= 1 && N <= 2, "FrameBuffer: unsupported color count %", N);
    c0 := fb.color_textures[0];
    assert(c0 != null, "FrameBuffer: color_textures[0] required");
    fb.device = c0.device;
    device := c0.device.device;

    attachment_count := cast(u32) N;
    #if has_depth attachment_count += 1;

    attachments: [3] VkAttachmentDescription;
    color_refs: [2] VkAttachmentReference;
    views: [3] VkImageView;

    for i: 0..N-1 {
        color := fb.color_textures[i];
        assert(color != null, "FrameBuffer: color_textures[%] null", i);
        assert(color.device == c0.device, "FrameBuffer: textures must share a device");
        assert(color.size.x == c0.size.x && color.size.y == c0.size.y, "FrameBuffer: color size mismatch");

        attachments[i].format = color.vk_format;
        attachments[i].samples = ._1_BIT;
        attachments[i].loadOp = .CLEAR;
        attachments[i].storeOp = .STORE;
        attachments[i].stencilLoadOp = .DONT_CARE;
        attachments[i].stencilStoreOp = .DONT_CARE;
        attachments[i].initialLayout = .UNDEFINED;
        // Single-color path matches Present (TRANSFER_SRC); MRT leaves SHADER_READ.
        if N == 1 {
            attachments[i].finalLayout = .TRANSFER_SRC_OPTIMAL;
        } else {
            attachments[i].finalLayout = .SHADER_READ_ONLY_OPTIMAL;
        }
        color_refs[i] = .{cast(u32) i, .COLOR_ATTACHMENT_OPTIMAL};
        views[i] = color.view;
    }

    depth_ref: VkAttachmentReference;
    #if has_depth {
        depth := framebuffer_depth(fb);
        assert(depth != null, "FrameBuffer: depth_texture required when has_depth");
        assert((depth.usage & .DEPTH_STENCIL) != 0, "FrameBuffer: depth_texture needs DEPTH_STENCIL usage");
        assert(depth.device == c0.device, "FrameBuffer: depth must share device");
        assert(depth.size.x == c0.size.x && depth.size.y == c0.size.y, "FrameBuffer: depth size mismatch");

        di := N;
        attachments[di].format = depth.vk_format;
        attachments[di].samples = ._1_BIT;
        attachments[di].loadOp = .CLEAR;
        attachments[di].storeOp = .DONT_CARE;
        attachments[di].stencilLoadOp = .DONT_CARE;
        attachments[di].stencilStoreOp = .DONT_CARE;
        attachments[di].initialLayout = .UNDEFINED;
        attachments[di].finalLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        depth_ref = .{cast(u32) di, .DEPTH_STENCIL_ATTACHMENT_OPTIMAL};
        views[di] = depth.view;
    }

    subpass: VkSubpassDescription;
    subpass.pipelineBindPoint = .GRAPHICS;
    subpass.colorAttachmentCount = cast(u32) N;
    subpass.pColorAttachments = color_refs.data;
    #if has_depth {
        subpass.pDepthStencilAttachment = *depth_ref;
    }

    deps: [2] VkSubpassDependency;
    deps[0].srcSubpass = VK_SUBPASS_EXTERNAL;
    deps[0].dstSubpass = 0;
    deps[0].srcStageMask = .BOTTOM_OF_PIPE_BIT;
    deps[0].dstStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
    #if has_depth deps[0].dstStageMask |= .EARLY_FRAGMENT_TESTS_BIT;
    deps[0].srcAccessMask = .MEMORY_READ_BIT;
    deps[0].dstAccessMask = .COLOR_ATTACHMENT_READ_BIT | .COLOR_ATTACHMENT_WRITE_BIT;
    #if has_depth deps[0].dstAccessMask |= .DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
    deps[0].dependencyFlags = .BY_REGION_BIT;

    deps[1].srcSubpass = 0;
    deps[1].dstSubpass = VK_SUBPASS_EXTERNAL;
    deps[1].srcStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
    #if has_depth deps[1].srcStageMask |= .LATE_FRAGMENT_TESTS_BIT;
    deps[1].dstStageMask = .BOTTOM_OF_PIPE_BIT;
    deps[1].srcAccessMask = .COLOR_ATTACHMENT_READ_BIT | .COLOR_ATTACHMENT_WRITE_BIT;
    #if has_depth deps[1].srcAccessMask |= .DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
    deps[1].dstAccessMask = .MEMORY_READ_BIT;
    deps[1].dependencyFlags = .BY_REGION_BIT;

    if !fb.render_pass {
        rp_info: VkRenderPassCreateInfo;
        rp_info.attachmentCount = attachment_count;
        rp_info.pAttachments = attachments.data;
        rp_info.subpassCount = 1;
        rp_info.pSubpasses = *subpass;
        rp_info.dependencyCount = 2;
        rp_info.pDependencies = deps.data;
        vk_check(vkCreateRenderPass(device, *rp_info, null, *fb.render_pass));
    }

    if fb.framebuffer {
        vkDestroyFramebuffer(device, fb.framebuffer, null);
        fb.framebuffer = null;
    }
    fb_info: VkFramebufferCreateInfo;
    fb_info.renderPass = fb.render_pass;
    fb_info.attachmentCount = attachment_count;
    fb_info.pAttachments = views.data;
    fb_info.width = c0.size.x;
    fb_info.height = c0.size.y;
    fb_info.layers = 1;
    vk_check(vkCreateFramebuffer(device, *fb_info, null, *fb.framebuffer));
}

make_owned_depth_texture :: (c0: *VulkanTexture2D) -> VulkanTexture2D {
    depth: VulkanTexture2D;
    depth_vk := find_depth_format(c0.device.physical_device);
    assert(depth_vk != .UNDEFINED, "No supported depth format");
    depth.device = c0.device;
    depth.size = c0.size;
    depth.format = .D32_SFLOAT;
    depth.usage = .DEPTH_STENCIL;
    depth.locality = .CREATE_ON_DEVICE;
    depth.mips = 1;
    depth.samples = 1;
    depth.vk_format = depth_vk;
    create_image_2d(
        c0.device,
        *depth,
        depth_vk,
        c0.size,
        .DEPTH_STENCIL_ATTACHMENT_BIT,
        depth_aspect_mask(depth_vk),
        1,
        1,
    );
    return depth;
}

// Variadic colors; N is inferred from the fixed-size array at the call site.
//   FrameBuffer(.[*tex])
//   FrameBuffer(.[*tex], has_depth = false)
//   FrameBuffer(.[*albedo, *normals], depth_texture = *depth)
FrameBuffer :: (
    textures: [$N] *VulkanTexture2D,
    clear_color := DEFAULT_CLEAR_COLOR,
    $has_depth := true,
) -> VulkanFrameBuffer(N, has_depth) {
    assert(N >= 1 && N <= 2, "FrameBuffer: need 1..2 color textures, got %", N);
    for textures assert(it != null, "FrameBuffer: null color texture");

    fb: VulkanFrameBuffer(N, has_depth);
    fb.clear_color = clear_color;
    for i: 0..N-1 {
        fb.color_textures[i] = textures[i];
    }
    #if has_depth {
        fb._owned_depth = make_owned_depth_texture(textures[0]);
        fb.depth_texture = *fb._owned_depth;
        fb.owns_depth = true;
    }
    create_framebuffer_vk(*fb);
    return fb;
}

FrameBuffer :: (
    textures: [$N] *VulkanTexture2D,
    clear_color := DEFAULT_CLEAR_COLOR,
    depth_texture: *VulkanTexture2D,
) -> VulkanFrameBuffer(N, true) {
    assert(depth_texture != null, "FrameBuffer: depth_texture required (use has_depth=false for color-only)");
    assert(N >= 1 && N <= 2, "FrameBuffer: need 1..2 color textures, got %", N);
    for textures assert(it != null, "FrameBuffer: null color texture");
    assert((depth_texture.usage & .DEPTH_STENCIL) != 0, "FrameBuffer: depth_texture needs DEPTH_STENCIL usage");

    fb: VulkanFrameBuffer(N, true);
    fb.clear_color = clear_color;
    for i: 0..N-1 {
        fb.color_textures[i] = textures[i];
    }
    fb.depth_texture = depth_texture;
    fb.owns_depth = false;
    create_framebuffer_vk(*fb);
    return fb;
}

// Single-color ergonomic wrappers. MRT: FrameBuffer(.[*a, *b], …).
FrameBuffer :: (t0: *VulkanTexture2D, clear_color := DEFAULT_CLEAR_COLOR, $has_depth := true) -> VulkanFrameBuffer(1, has_depth) {
    return FrameBuffer(.[t0], clear_color, has_depth);
}

FrameBuffer :: (t0: *VulkanTexture2D, clear_color := DEFAULT_CLEAR_COLOR, depth_texture: *VulkanTexture2D) -> VulkanFrameBuffer(1, true) {
    return FrameBuffer(.[t0], clear_color, depth_texture);
}

Update :: (fb: *VulkanFrameBuffer($N, $has_depth), new_size: Size2D) {
    assert(fb != null && fb.device && fb.device.device, "Update(framebuffer): invalid");
    assert(new_size.x >= 1 && new_size.y >= 1, "Update(framebuffer): size >= 1");

    c0 := fb.color_textures[0];
    assert(c0 != null, "Update(framebuffer): null color_textures[0]");
    if c0.size.x == new_size.x && c0.size.y == new_size.y return;

    // VkFramebuffer holds the image views — tear it down (and drain the GPU) before
    // recreating the underlying textures, or destroy_image_resources hits live views.
    device := fb.device.device;
    vkDeviceWaitIdle(device);
    if fb.framebuffer {
        vkDestroyFramebuffer(device, fb.framebuffer, null);
        fb.framebuffer = null;
    }

    for fb.color_textures {
        assert(it != null, "Update(framebuffer): null color texture");
        Update(it, new_size);
    }
    #if has_depth {
        depth := framebuffer_depth(fb);
        assert(depth != null, "Update(framebuffer): null depth texture");
        Update(depth, new_size);
    }
    create_framebuffer_vk(fb);
}

Destroy :: (fb: *VulkanFrameBuffer($N, $has_depth)) {
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
    #if has_depth {
        if fb.owns_depth {
            destroy_image_resources(device, fb._owned_depth.image, fb._owned_depth.view, fb._owned_depth.memory);
            fb._owned_depth.image = null;
            fb._owned_depth.view = null;
            fb._owned_depth.memory = null;
            fb.depth_texture = null;
        }
    }
}

// --- Shader ---

VulkanShader :: struct ($source: string, $stages: [] string) {
    device: *VulkanDevice;
    shader_module: VkShaderModule;
    pipeline_layout: VkPipelineLayout;
    pipeline: VkPipeline;
    compatible_render_pass: VkRenderPass;
    desc_set_layout: VkDescriptorSetLayout;
    desc_pool: VkDescriptorPool;
    desc_set: VkDescriptorSet;
    #insert -> string {
        blueprint := ShaderString(source, "embedded");
        return emit_vulkan_shader_members(blueprint, stages);
    }
}

ResourceBinding :: struct {
    name: string;
    set: u32;
    binding: u32;
    kind: SlangResourceKind;
};

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
    hs_name := "";
    ds_name := "";
    has_geometry := false;
    for ep: shader.entry_points {
        if !stage_selected(ep.name, stages) continue;
        if ep.type == .VERTEX_SHADER then vs_name = ep.name;
        if ep.type == .FRAGMENT_SHADER then fs_name = ep.name;
        if ep.type == .COMPUTE_SHADER then cs_name = ep.name;
        if ep.type == .HULL_SHADER then hs_name = ep.name;
        if ep.type == .DOMAIN_SHADER then ds_name = ep.name;
        if ep.type == .GEOMETRY_SHADER then has_geometry = true;
    }
    assert(!has_geometry, "Spawn: geometry stage not implemented");
    if hs_name.count || ds_name.count {
        assert(hs_name.count && ds_name.count && vs_name.count && fs_name.count,
            "Spawn: tessellation requires vs+hs+ds+fs entry points");
    }

    print_to_builder(*builder, "vs_entry :: \"%\";\n", vs_name);
    print_to_builder(*builder, "fs_entry :: \"%\";\n", fs_name);
    print_to_builder(*builder, "cs_entry :: \"%\";\n", cs_name);
    print_to_builder(*builder, "hs_entry :: \"%\";\n", hs_name);
    print_to_builder(*builder, "ds_entry :: \"%\";\n", ds_name);
    print_to_builder(*builder, "is_compute :: %;\n", ifx cs_name.count && !vs_name.count then "true" else "false");
    print_to_builder(*builder, "is_tessellation :: %;\n", ifx hs_name.count then "true" else "false");
    if !push_constant_bytes && !cs_name.count then push_constant_bytes = xx size_of(Matrix4);
    print_to_builder(*builder, "push_constant_bytes :: %;\n\n", push_constant_bytes);

    print_to_builder(*builder, "resource_bindings :: ResourceBinding.[\n");
    for r: shader.resources {
        kind_str := "SlangResourceKind.STORAGE_BUFFER";
        if r.kind == .SAMPLED_TEXTURE then kind_str = "SlangResourceKind.SAMPLED_TEXTURE";
        if r.kind == .STORAGE_TEXTURE then kind_str = "SlangResourceKind.STORAGE_TEXTURE";
        if r.kind == .SAMPLER then kind_str = "SlangResourceKind.SAMPLER";
        print_to_builder(*builder,
            "    .{ name = \"%\", set = %, binding = %, kind = % },\n",
            r.name, r.set, r.binding, kind_str);
    }
    print_to_builder(*builder, "];\n\n");

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
        spawn_compute_pipeline(dev, *shdr);
        return shdr;
    }

    #if Shader_t.is_tessellation {
        require_feature(dev.vulkan_context, .TESSELLATION);
    }

    push_constant_range: VkPushConstantRange;
    push_constant_range.stageFlags = .VERTEX_BIT | .FRAGMENT_BIT;
    #if Shader_t.is_tessellation {
        push_constant_range.stageFlags |= .TESSELLATION_CONTROL_BIT | .TESSELLATION_EVALUATION_BIT;
    }
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

    // Must match FrameBuffer(has_depth=true) deps — validation checks RP compatibility
    // against the pipeline's renderPass, including subpass dependency stage/access masks.
    deps: [2] VkSubpassDependency;
    deps[0].srcSubpass = VK_SUBPASS_EXTERNAL;
    deps[0].dstSubpass = 0;
    deps[0].srcStageMask = .BOTTOM_OF_PIPE_BIT;
    deps[0].dstStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT | .EARLY_FRAGMENT_TESTS_BIT;
    deps[0].srcAccessMask = .MEMORY_READ_BIT;
    deps[0].dstAccessMask = .COLOR_ATTACHMENT_READ_BIT | .COLOR_ATTACHMENT_WRITE_BIT | .DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
    deps[0].dependencyFlags = .BY_REGION_BIT;

    deps[1].srcSubpass = 0;
    deps[1].dstSubpass = VK_SUBPASS_EXTERNAL;
    deps[1].srcStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT | .LATE_FRAGMENT_TESTS_BIT;
    deps[1].dstStageMask = .BOTTOM_OF_PIPE_BIT;
    deps[1].srcAccessMask = .COLOR_ATTACHMENT_READ_BIT | .COLOR_ATTACHMENT_WRITE_BIT | .DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
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
    #if Shader_t.is_tessellation {
        input_assembly_state.topology = .PATCH_LIST;
    } else {
        input_assembly_state.topology = .TRIANGLE_LIST;
    }

    tessellation_state: VkPipelineTessellationStateCreateInfo;
    #if Shader_t.is_tessellation {
        tessellation_state.patchControlPoints = 3;
    }

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

    shader_stages: [4] VkPipelineShaderStageCreateInfo;
    stage_count: u32 = 2;
    shader_stages[0].stage = .VERTEX_BIT;
    shader_stages[0].module = shdr.shader_module;
    shader_stages[0].pName = temp_c_string(Shader_t.vs_entry);
    #if Shader_t.is_tessellation {
        shader_stages[1].stage = .TESSELLATION_CONTROL_BIT;
        shader_stages[1].module = shdr.shader_module;
        shader_stages[1].pName = temp_c_string(Shader_t.hs_entry);
        shader_stages[2].stage = .TESSELLATION_EVALUATION_BIT;
        shader_stages[2].module = shdr.shader_module;
        shader_stages[2].pName = temp_c_string(Shader_t.ds_entry);
        shader_stages[3].stage = .FRAGMENT_BIT;
        shader_stages[3].module = shdr.shader_module;
        shader_stages[3].pName = temp_c_string(Shader_t.fs_entry);
        stage_count = 4;
    } else {
        shader_stages[1].stage = .FRAGMENT_BIT;
        shader_stages[1].module = shdr.shader_module;
        shader_stages[1].pName = temp_c_string(Shader_t.fs_entry);
    }

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
    pipeline_create_info.stageCount = stage_count;
    pipeline_create_info.pStages = shader_stages.data;
    pipeline_create_info.pVertexInputState = *vertex_input_state;
    #if Shader_t.is_tessellation {
        pipeline_create_info.pTessellationState = *tessellation_state;
    }

    vk_check(vkCreateGraphicsPipelines(dev.device, null, 1, *pipeline_create_info, null, *shdr.pipeline));
    return shdr;
}

spawn_compute_pipeline :: (dev: *VulkanDevice, shdr: *$Shader_t) {
    assert(Shader_t.resource_bindings.count > 0, "Spawn(compute): no reflected resources (expected storage buffer)");

    bindings: [..] VkDescriptorSetLayoutBinding;
    defer array_free(bindings);
    for r: Shader_t.resource_bindings {
        dtype := VkDescriptorType.STORAGE_BUFFER;
        if r.kind == .STORAGE_BUFFER {
            dtype = .STORAGE_BUFFER;
        } else if r.kind == .STORAGE_TEXTURE {
            dtype = .STORAGE_IMAGE;
        } else {
            assert(false, "Spawn(compute): resource '%' kind=% (want STORAGE_BUFFER/TEXTURE)",
                r.name, cast(u32) r.kind);
        }
        array_add(*bindings, .{
            binding = r.binding,
            descriptorType = dtype,
            descriptorCount = 1,
            stageFlags = .COMPUTE_BIT,
        });
    }

    layout_info: VkDescriptorSetLayoutCreateInfo;
    layout_info.bindingCount = xx bindings.count;
    layout_info.pBindings = bindings.data;
    vk_check(vkCreateDescriptorSetLayout(dev.device, *layout_info, null, *shdr.desc_set_layout));

    pool_sizes: [..] VkDescriptorPoolSize;
    defer array_free(pool_sizes);
    for b: bindings {
        found := false;
        for *ps: pool_sizes {
            if ps.type == b.descriptorType {
                ps.descriptorCount += 1;
                found = true;
                break;
            }
        }
        if !found then array_add(*pool_sizes, .{ type = b.descriptorType, descriptorCount = 1 });
    }

    pool_info: VkDescriptorPoolCreateInfo;
    pool_info.maxSets = 1;
    pool_info.poolSizeCount = xx pool_sizes.count;
    pool_info.pPoolSizes = pool_sizes.data;
    vk_check(vkCreateDescriptorPool(dev.device, *pool_info, null, *shdr.desc_pool));

    alloc_info: VkDescriptorSetAllocateInfo;
    alloc_info.descriptorPool = shdr.desc_pool;
    alloc_info.descriptorSetCount = 1;
    alloc_info.pSetLayouts = *shdr.desc_set_layout;
    vk_check(vkAllocateDescriptorSets(dev.device, *alloc_info, *shdr.desc_set));

    pipe_layout_info: VkPipelineLayoutCreateInfo;
    pipe_layout_info.setLayoutCount = 1;
    pipe_layout_info.pSetLayouts = *shdr.desc_set_layout;
    vk_check(vkCreatePipelineLayout(dev.device, *pipe_layout_info, null, *shdr.pipeline_layout));

    stage: VkPipelineShaderStageCreateInfo;
    stage.stage = .COMPUTE_BIT;
    stage.module = shdr.shader_module;
    stage.pName = temp_c_string(Shader_t.cs_entry);

    pipe_info: VkComputePipelineCreateInfo;
    pipe_info.stage = stage;
    pipe_info.layout = shdr.pipeline_layout;
    vk_check(vkCreateComputePipelines(dev.device, null, 1, *pipe_info, null, *shdr.pipeline));
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
    if shdr.desc_pool {
        vkDestroyDescriptorPool(device, shdr.desc_pool, null);
        shdr.desc_pool = null;
        shdr.desc_set = null;
    }
    if shdr.desc_set_layout {
        vkDestroyDescriptorSetLayout(device, shdr.desc_set_layout, null);
        shdr.desc_set_layout = null;
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
    command_pool: VkCommandPool;
    cmd: VkCommandBuffer;
    bound_pipeline_layout: VkPipelineLayout;
    bound_desc_set: VkDescriptorSet;
    storage_bound: bool;
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
    pool, cmd := create_command_pool_and_buffer(dev);
    begin_info: VkCommandBufferBeginInfo;
    vk_check(vkBeginCommandBuffer(cmd, *begin_info));
    return VulkanComputeQueue.{
        device = dev,
        command_pool = pool,
        cmd = cmd,
        storage_bound = false,
    };
}

Queue :: (dev: *VulkanDevice, $type: QUEUE_TYPE) -> VulkanCopyQueue
    #modify { return type == .COPY; }
{
    assert(dev != null, "Queue(COPY): invalid device");
    not_implemented("Queue(COPY)");
    return VulkanCopyQueue.{device = dev};
}

Bind :: (q: *VulkanGraphicsQueue, frm_buf: *VulkanFrameBuffer($N, $has_depth)) {
    assert(q != null && frm_buf != null, "Bind: invalid args");
    assert(N >= 1 && N <= 2, "Bind: unsupported color attachment count %", N);
    color := frm_buf.color_textures[0];
    assert(color != null, "Bind: null color_textures[0]");

    clear_count := cast(u32) N;
    #if has_depth clear_count += 1;

    clear_values: [3] VkClearValue;
    color_clear := float.[
        frm_buf.clear_color.r, frm_buf.clear_color.g, frm_buf.clear_color.b, frm_buf.clear_color.a,
    ];
    for i: 0..N-1 {
        clear_values[i].color._float32 = color_clear;
    }
    #if has_depth {
        clear_values[N].depthStencil = .{1.0, 0};
    }

    begin_info: VkRenderPassBeginInfo;
    begin_info.renderPass = frm_buf.render_pass;
    begin_info.framebuffer = frm_buf.framebuffer;
    begin_info.renderArea.extent.width = color.size.x;
    begin_info.renderArea.extent.height = color.size.y;
    begin_info.clearValueCount = clear_count;
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
    assert(shdr.pipeline != null, "Pass(Compute): shader has no compute pipeline");
    assert(shdr.desc_set != null, "Pass(Compute): shader has no descriptor set");
    vkCmdBindPipeline(q.cmd, .COMPUTE, shdr.pipeline);
    q.bound_pipeline_layout = shdr.pipeline_layout;
    q.bound_desc_set = shdr.desc_set;
    q.storage_bound = false;
    return .[VulkanComputePass(source, stages).{ queue = q, shader = shdr }];
}

Set :: (pass: VulkanComputePass($source, $stages), buf: *VulkanBuffer) {
    assert(buf != null, "Set(compute buffer): invalid buffer");
    assert(buf.usage == .STORAGE, "Set(compute): buffer must have STORAGE usage");
    shdr := pass.shader;
    Shader_t :: type_of(shdr.*);
    #if Shader_t.resource_bindings.count < 1 {
        #assert false; // Spawn(compute) must reflect at least one storage binding
    }
    binding := Shader_t.resource_bindings[0].binding;
    buffer_info: VkDescriptorBufferInfo;
    buffer_info.buffer = buf.buffer;
    buffer_info.offset = 0;
    buffer_info.range = xx buf.size;

    write: VkWriteDescriptorSet;
    write.dstSet = shdr.desc_set;
    write.dstBinding = binding;
    write.descriptorCount = 1;
    write.descriptorType = .STORAGE_BUFFER;
    write.pBufferInfo = *buffer_info;
    vkUpdateDescriptorSets(shdr.device.device, 1, *write, 0, null);
    pass.queue.storage_bound = true;
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
    assert(q.cmd != null, "Submit(Compute): queue has no command buffer");
    assert(q.bound_pipeline_layout != null, "Submit(Compute): Pass a compute shader first");
    assert(q.bound_desc_set != null, "Submit(Compute): Pass a compute shader first");
    assert(q.storage_bound, "Submit(Compute): Set a STORAGE buffer before Submit");
    assert(groups_x >= 1 && groups_y >= 1 && groups_z >= 1, "Submit(Compute): group counts must be >= 1");

    vkCmdBindDescriptorSets(q.cmd, .COMPUTE, q.bound_pipeline_layout, 0, 1, *q.bound_desc_set, 0, null);
    vkCmdDispatch(q.cmd, groups_x, groups_y, groups_z);
    vk_check(vkEndCommandBuffer(q.cmd));
    submit_work(q.device, q.cmd, wait);

    if (q.device.vulkan_context.flags & .ENABLE_DEBUG) != 0 {
        q.device.vulkan_context.debug_callback(
            tprint("Submit(Compute): groups %,%,%", groups_x, groups_y, groups_z),
        );
    }

    if q.command_pool {
        vkDestroyCommandPool(q.device.device, q.command_pool, null);
        q.command_pool = null;
        q.cmd = null;
    }
}

Submit :: (q: *VulkanCopyQueue, wait := true) {
    _ := q; _ := wait;
    not_implemented("Submit(Copy)");
}

// Submit already tears down the pool; call Destroy when a Queue is created but never Submitted
// (e.g. 11_threaded_rendering), otherwise vkDestroyDevice reports live command pools.
Destroy :: (q: *VulkanGraphicsQueue) {
    if !q || !q.device || !q.device.device return;
    if q.render_pass_active {
        vkCmdEndRenderPass(q.cmd);
        q.render_pass_active = false;
    }
    if q.command_pool {
        vkDestroyCommandPool(q.device.device, q.command_pool, null);
        q.command_pool = null;
        q.cmd = null;
    }
}

Destroy :: (q: *VulkanComputeQueue) {
    if !q || !q.device || !q.device.device return;
    if q.command_pool {
        vkDestroyCommandPool(q.device.device, q.command_pool, null);
        q.command_pool = null;
        q.cmd = null;
    }
}

VulkanSurface :: struct ($Window_t: Type) {
    device: *VulkanDevice;
    window: *Window_t;
    width: u32;
    height: u32;
    last_time: float64;
    delta_time: float64;

    surface: VkSurfaceKHR;
    surface_format: VkSurfaceFormatKHR;
    present_mode: VkPresentModeKHR;
    extent: VkExtent2D;

    swapchain: VkSwapchainKHR;
    swapchain_images: [..] VkImage;
    swapchain_views: [..] VkImageView;
    framebuffers: [..] VkFramebuffer;

    render_pass: VkRenderPass;
    pipeline_layout: VkPipelineLayout;
    pipeline: VkPipeline;
    shader_module: VkShaderModule;

    desc_pool: VkDescriptorPool;
    desc_set_layout: VkDescriptorSetLayout;
    desc_set: VkDescriptorSet;
    sampler: VkSampler;

    cmd_pool: VkCommandPool;
    cmd: VkCommandBuffer;
    image_available: VkSemaphore;
    render_finished: [..] VkSemaphore;
    in_flight: VkFence;
}

PRESENT_SHADER_SLANG :: #string SLANG_CODE
struct VSOut
{
    float4 Pos : SV_POSITION;
    float2 UV;
};

[shader("vertex")]
VSOut vs_fullscreen(uint id : SV_VertexID)
{
    float2 uv = float2((id << 1) & 2, id & 2);
    VSOut o;
    o.UV = uv;
    o.Pos = float4(uv * float2(2, 2) + float2(-1, -1), 0, 1);
    return o;
}

[[vk::binding(0, 0)]]
Texture2D src_tex;

[[vk::binding(1, 0)]]
SamplerState src_samp;

[shader("fragment")]
float4 fs_fullscreen(VSOut input) : SV_TARGET
{
    return src_tex.Sample(src_samp, input.UV);
}
SLANG_CODE

PresentShaderSpirv :: struct {
    #insert -> string {
        bp := ShaderString(PRESENT_SHADER_SLANG, "present");
        defer array_free(bp.spirv);
        assert(bp.spirv.count > 0, "PresentShaderSpirv: empty SPIR-V");

        builder: String_Builder;
        print_to_builder(*builder, "spirv :: u8.[\n");
        for i: 0..bp.spirv.count-1 {
            print_to_builder(*builder, "%,", bp.spirv[i]);
            if (i + 1) % 16 == 0 then print_to_builder(*builder, "\n");
        }
        print_to_builder(*builder, "\n];\n");
        return builder_to_string(*builder);
    }
}

// --- Surface create: specialized per CrossWindow backend ---

#if OS == .LINUX {

Surface :: (dev: *VulkanDevice, window: *X11Window) -> VulkanSurface(X11Window) {
    assert(dev && dev.device && dev.vulkan_context, "Surface: invalid device");
    assert(window != null && window.alive, "Surface(X11): invalid window");
    require_feature(dev.vulkan_context, .SURFACE);

    srf: VulkanSurface(X11Window);
    srf.device = dev;
    srf.window = window;
    srf.delta_time = 0.0;
    srf.last_time = seconds_since_init();

    instance := dev.vulkan_context.instance;
    dpy, xid := GetNativeX11(window);
    assert(dpy != null && xid != X11.None, "Surface(X11): null native handles");

    create_xlib: VkXlibSurfaceCreateInfoKHR;
    create_xlib.sType = .XLIB_SURFACE_CREATE_INFO_KHR;
    create_xlib.dpy = dpy;
    create_xlib.window = xid;

    create_xlib_surface: PFN_vkCreateXlibSurfaceKHR =
        xx vkGetInstanceProcAddr(instance, "vkCreateXlibSurfaceKHR");
    assert(create_xlib_surface != null, "vkCreateXlibSurfaceKHR missing (enable VK_KHR_xlib_surface)");
    vk_check(create_xlib_surface(instance, *create_xlib, null, *srf.surface));

    surface_finish_create(*srf);
    return srf;
}

// Catch-all until WaylandWindow / etc. get their own Surface overloads.
Surface :: (dev: *VulkanDevice, window: *$Window_t) -> VulkanSurface(Window_t)
    #modify { return Window_t != X11Window; }
{
    _ := window;
    assert(dev && dev.vulkan_context, "Surface: invalid device");
    require_feature(dev.vulkan_context, .SURFACE);
    assert(false, "Surface: no specialization for window type % (X11 only for now)", Window_t);
    return .{};
}

} else {

Surface :: (dev: *VulkanDevice, window: *$Window_t) -> VulkanSurface(Window_t) {
    _ := window;
    assert(dev && dev.vulkan_context, "Surface: invalid device");
    require_feature(dev.vulkan_context, .SURFACE);
    assert(false, "Surface: unsupported OS (need a Window_t specialization)");
    return .{};
}

}

surface_finish_create :: (srf: *VulkanSurface($Window_t)) {
    assert(srf && srf.device && srf.window, "surface_finish_create: invalid surface");
    dev := srf.device;

    {
        present_supported: VkBool32;
        vk_check(vkGetPhysicalDeviceSurfaceSupportKHR(
            dev.physical_device, dev.queue_family_index, srf.surface, *present_supported,
        ));
        assert(present_supported != 0, "Surface: queue family lacks present support");
    }

    {
        count: u32;
        vkGetPhysicalDeviceSurfaceFormatsKHR(dev.physical_device, srf.surface, *count, null);
        assert(count > 0, "Surface: no surface formats");
        formats := NewArray(xx count, VkSurfaceFormatKHR);
        defer free(formats.data);
        vkGetPhysicalDeviceSurfaceFormatsKHR(dev.physical_device, srf.surface, *count, formats.data);

        preferred := VkFormat.[.B8G8R8A8_UNORM, .R8G8B8A8_UNORM];
        found := false;
        if count == 1 && formats[0].format == .UNDEFINED {
            srf.surface_format = .{.B8G8R8A8_UNORM, .COLOR_SPACE_SRGB_NONLINEAR_KHR};
            found = true;
        } else {
            for pref: preferred {
                for formats {
                    if it.format == pref && it.colorSpace == .COLOR_SPACE_SRGB_NONLINEAR_KHR {
                        srf.surface_format = it;
                        found = true;
                        break pref;
                    }
                }
            }
            if !found then srf.surface_format = formats[0];
        }
    }
    {
        count: u32;
        vkGetPhysicalDeviceSurfacePresentModesKHR(dev.physical_device, srf.surface, *count, null);
        modes := NewArray(xx count, VkPresentModeKHR);
        defer free(modes.data);
        vkGetPhysicalDeviceSurfacePresentModesKHR(dev.physical_device, srf.surface, *count, modes.data);
        srf.present_mode = .FIFO_KHR;
        for modes {
            if it == .MAILBOX_KHR {
                srf.present_mode = .MAILBOX_KHR;
                break;
            }
        }
    }

    {
        attachment: VkAttachmentDescription;
        attachment.format = srf.surface_format.format;
        attachment.samples = ._1_BIT;
        attachment.loadOp = .CLEAR;
        attachment.storeOp = .STORE;
        attachment.stencilLoadOp = .DONT_CARE;
        attachment.stencilStoreOp = .DONT_CARE;
        attachment.initialLayout = .UNDEFINED;
        attachment.finalLayout = .PRESENT_SRC_KHR;

        color_ref := VkAttachmentReference.{0, .COLOR_ATTACHMENT_OPTIMAL};

        subpass: VkSubpassDescription;
        subpass.pipelineBindPoint = .GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = *color_ref;

        dep: VkSubpassDependency;
        dep.srcSubpass = VK_SUBPASS_EXTERNAL;
        dep.dstSubpass = 0;
        dep.srcStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
        dep.dstStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
        dep.srcAccessMask = xx 0;
        dep.dstAccessMask = .COLOR_ATTACHMENT_WRITE_BIT;

        rp_info: VkRenderPassCreateInfo;
        rp_info.attachmentCount = 1;
        rp_info.pAttachments = *attachment;
        rp_info.subpassCount = 1;
        rp_info.pSubpasses = *subpass;
        rp_info.dependencyCount = 1;
        rp_info.pDependencies = *dep;
        vk_check(vkCreateRenderPass(dev.device, *rp_info, null, *srf.render_pass));
    }

    {
        _, _, win_w, win_h, ok := GetDimensions(srf.window);
        assert(ok && win_w > 0 && win_h > 0, "Surface: window has no dimensions");
        srf.width = win_w;
        srf.height = win_h;
        surface_recreate_swapchain(srf, win_w, win_h);
    }

    {
        assert(PresentShaderSpirv.spirv.count > 0, "Surface: present shader produced empty SPIR-V");
        module_info: VkShaderModuleCreateInfo;
        module_info.codeSize = xx PresentShaderSpirv.spirv.count;
        module_info.pCode = cast(*u32) PresentShaderSpirv.spirv.data;
        vk_check(vkCreateShaderModule(dev.device, *module_info, null, *srf.shader_module));
    }

    {
        bindings: [2] VkDescriptorSetLayoutBinding;
        bindings[0].binding = 0;
        bindings[0].descriptorType = .SAMPLED_IMAGE;
        bindings[0].descriptorCount = 1;
        bindings[0].stageFlags = .FRAGMENT_BIT;
        bindings[1].binding = 1;
        bindings[1].descriptorType = .SAMPLER;
        bindings[1].descriptorCount = 1;
        bindings[1].stageFlags = .FRAGMENT_BIT;

        layout_info: VkDescriptorSetLayoutCreateInfo;
        layout_info.bindingCount = 2;
        layout_info.pBindings = bindings.data;
        vk_check(vkCreateDescriptorSetLayout(dev.device, *layout_info, null, *srf.desc_set_layout));

        pool_sizes: [2] VkDescriptorPoolSize;
        pool_sizes[0] = .{.SAMPLED_IMAGE, 1};
        pool_sizes[1] = .{.SAMPLER, 1};
        pool_info: VkDescriptorPoolCreateInfo;
        pool_info.maxSets = 1;
        pool_info.poolSizeCount = 2;
        pool_info.pPoolSizes = pool_sizes.data;
        vk_check(vkCreateDescriptorPool(dev.device, *pool_info, null, *srf.desc_pool));

        alloc_info: VkDescriptorSetAllocateInfo;
        alloc_info.descriptorPool = srf.desc_pool;
        alloc_info.descriptorSetCount = 1;
        alloc_info.pSetLayouts = *srf.desc_set_layout;
        vk_check(vkAllocateDescriptorSets(dev.device, *alloc_info, *srf.desc_set));

        samp_info: VkSamplerCreateInfo;
        samp_info.magFilter = .LINEAR;
        samp_info.minFilter = .LINEAR;
        samp_info.addressModeU = .CLAMP_TO_EDGE;
        samp_info.addressModeV = .CLAMP_TO_EDGE;
        samp_info.addressModeW = .CLAMP_TO_EDGE;
        vk_check(vkCreateSampler(dev.device, *samp_info, null, *srf.sampler));
    }

    {
        layout_info: VkPipelineLayoutCreateInfo;
        layout_info.setLayoutCount = 1;
        layout_info.pSetLayouts = *srf.desc_set_layout;
        vk_check(vkCreatePipelineLayout(dev.device, *layout_info, null, *srf.pipeline_layout));
    }

    {
        stages: [2] VkPipelineShaderStageCreateInfo;
        stages[0].stage = .VERTEX_BIT;
        stages[0].module = srf.shader_module;
        stages[0].pName = temp_c_string("vs_fullscreen");
        stages[1].stage = .FRAGMENT_BIT;
        stages[1].module = srf.shader_module;
        stages[1].pName = temp_c_string("fs_fullscreen");

        vertex_input: VkPipelineVertexInputStateCreateInfo;

        input_assembly: VkPipelineInputAssemblyStateCreateInfo;
        input_assembly.topology = .TRIANGLE_LIST;

        viewport_state: VkPipelineViewportStateCreateInfo;
        viewport_state.viewportCount = 1;
        viewport_state.scissorCount = 1;

        raster: VkPipelineRasterizationStateCreateInfo;
        raster.polygonMode = .FILL;
        raster.cullMode = .NONE;
        raster.frontFace = .COUNTER_CLOCKWISE;
        raster.lineWidth = 1.0;

        multisample: VkPipelineMultisampleStateCreateInfo;
        multisample.rasterizationSamples = ._1_BIT;

        blend_att: VkPipelineColorBlendAttachmentState;
        blend_att.colorWriteMask = xx 0xf;
        blend: VkPipelineColorBlendStateCreateInfo;
        blend.attachmentCount = 1;
        blend.pAttachments = *blend_att;

        dynamic_enables := VkDynamicState.[.VIEWPORT, .SCISSOR];
        dynamic_state: VkPipelineDynamicStateCreateInfo;
        dynamic_state.dynamicStateCount = xx dynamic_enables.count;
        dynamic_state.pDynamicStates = dynamic_enables.data;

        gp: VkGraphicsPipelineCreateInfo;
        gp.stageCount = 2;
        gp.pStages = stages.data;
        gp.pVertexInputState = *vertex_input;
        gp.pInputAssemblyState = *input_assembly;
        gp.pViewportState = *viewport_state;
        gp.pRasterizationState = *raster;
        gp.pMultisampleState = *multisample;
        gp.pColorBlendState = *blend;
        gp.pDynamicState = *dynamic_state;
        gp.layout = srf.pipeline_layout;
        gp.renderPass = srf.render_pass;
        gp.basePipelineIndex = -1;
        vk_check(vkCreateGraphicsPipelines(dev.device, null, 1, *gp, null, *srf.pipeline));
    }

    srf.cmd_pool, srf.cmd = create_command_pool_and_buffer(dev);

    sem_info: VkSemaphoreCreateInfo;
    vk_check(vkCreateSemaphore(dev.device, *sem_info, null, *srf.image_available));
    fence_info: VkFenceCreateInfo;
    fence_info.flags = .SIGNALED_BIT;
    vk_check(vkCreateFence(dev.device, *fence_info, null, *srf.in_flight));
}

surface_destroy_swapchain :: (srf: *VulkanSurface($Window_t)) {
    if !srf.device || !srf.device.device return;
    device := srf.device.device;
    vkDeviceWaitIdle(device);

    for srf.framebuffers {
        if it then vkDestroyFramebuffer(device, it, null);
    }
    array_free(srf.framebuffers);

    for srf.swapchain_views {
        if it then vkDestroyImageView(device, it, null);
    }
    array_free(srf.swapchain_views);
    array_free(srf.swapchain_images);

    for srf.render_finished {
        if it then vkDestroySemaphore(device, it, null);
    }
    array_free(srf.render_finished);

    if srf.swapchain {
        vkDestroySwapchainKHR(device, srf.swapchain, null);
        srf.swapchain = null;
    }
}

surface_recreate_swapchain :: (srf: *VulkanSurface($Window_t), width: u32, height: u32) {
    assert(srf.device && srf.device.device, "surface_recreate_swapchain: invalid device");
    assert(srf.surface != null, "surface_recreate_swapchain: no VkSurface");
    assert(srf.render_pass != null, "surface_recreate_swapchain: create render_pass first");
    if width == 0 || height == 0 return;

    dev := srf.device;
    device := dev.device;
    vkDeviceWaitIdle(device);

    caps: VkSurfaceCapabilitiesKHR;
    vk_check(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(dev.physical_device, srf.surface, *caps));

    if caps.currentExtent.width != 0xFFFF_FFFF {
        srf.extent = caps.currentExtent;
    } else {
        srf.extent.width = clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width);
        srf.extent.height = clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height);
    }
    if srf.extent.width == 0 || srf.extent.height == 0 return;

    srf.width = srf.extent.width;
    srf.height = srf.extent.height;

    min_images: u32 = 2;
    if srf.present_mode == .MAILBOX_KHR then min_images = 3;
    if min_images < caps.minImageCount then min_images = caps.minImageCount;
    if caps.maxImageCount > 0 && min_images > caps.maxImageCount then min_images = caps.maxImageCount;

    composite := VkCompositeAlphaFlagBitsKHR.OPAQUE_BIT_KHR;
    if caps.supportedCompositeAlpha & .OPAQUE_BIT_KHR {
        composite = .OPAQUE_BIT_KHR;
    } else if caps.supportedCompositeAlpha & .INHERIT_BIT_KHR {
        composite = .INHERIT_BIT_KHR;
    }

    old_swapchain := srf.swapchain;

    swap_info: VkSwapchainCreateInfoKHR;
    swap_info.surface = srf.surface;
    swap_info.minImageCount = min_images;
    swap_info.imageFormat = srf.surface_format.format;
    swap_info.imageColorSpace = srf.surface_format.colorSpace;
    swap_info.imageExtent = srf.extent;
    swap_info.imageArrayLayers = 1;
    swap_info.imageUsage = .COLOR_ATTACHMENT_BIT;
    swap_info.imageSharingMode = .EXCLUSIVE;
    swap_info.preTransform = caps.currentTransform;
    swap_info.compositeAlpha = composite;
    swap_info.presentMode = srf.present_mode;
    swap_info.clipped = VK_TRUE;
    swap_info.oldSwapchain = old_swapchain;
    vk_check(vkCreateSwapchainKHR(dev.device, *swap_info, null, *srf.swapchain));

    if old_swapchain {
        for srf.framebuffers {
            if it then vkDestroyFramebuffer(device, it, null);
        }
        array_free(srf.framebuffers);
        for srf.swapchain_views {
            if it then vkDestroyImageView(device, it, null);
        }
        array_free(srf.swapchain_views);
        array_free(srf.swapchain_images);
        for srf.render_finished {
            if it then vkDestroySemaphore(device, it, null);
        }
        array_free(srf.render_finished);
        vkDestroySwapchainKHR(device, old_swapchain, null);
    }

    image_count: u32;
    vk_check(vkGetSwapchainImagesKHR(dev.device, srf.swapchain, *image_count, null));
    assert(image_count > 0 && image_count < 16, "surface_recreate_swapchain: bad image_count %", image_count);
    array_reserve(*srf.swapchain_images, xx image_count);
    srf.swapchain_images.count = xx image_count;
    vk_check(vkGetSwapchainImagesKHR(dev.device, srf.swapchain, *image_count, srf.swapchain_images.data));

    array_reserve(*srf.swapchain_views, xx image_count);
    srf.swapchain_views.count = xx image_count;
    for i: 0..image_count-1 {
        view_info: VkImageViewCreateInfo;
        view_info.sType = .IMAGE_VIEW_CREATE_INFO;
        view_info.viewType = ._2D;
        view_info.format = srf.surface_format.format;
        view_info.subresourceRange = .{.COLOR_BIT, 0, 1, 0, 1};
        view_info.image = srf.swapchain_images[i];
        vk_check(vkCreateImageView(dev.device, *view_info, null, *srf.swapchain_views[i]));
    }

    array_reserve(*srf.framebuffers, xx image_count);
    srf.framebuffers.count = xx image_count;
    for i: 0..image_count-1 {
        attachment := srf.swapchain_views[i];
        fb_info: VkFramebufferCreateInfo;
        fb_info.sType = .FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = srf.render_pass;
        fb_info.attachmentCount = 1;
        fb_info.pAttachments = *attachment;
        fb_info.width = srf.extent.width;
        fb_info.height = srf.extent.height;
        fb_info.layers = 1;
        vk_check(vkCreateFramebuffer(dev.device, *fb_info, null, *srf.framebuffers[i]));
    }

    sem_info: VkSemaphoreCreateInfo;
    array_reserve(*srf.render_finished, xx image_count);
    srf.render_finished.count = xx image_count;
    for i: 0..image_count-1 {
        vk_check(vkCreateSemaphore(dev.device, *sem_info, null, *srf.render_finished[i]));
    }
}

Present :: (srf: *VulkanSurface($Window_t), tex: *VulkanTexture2D, fps: u32 = 60) {
    assert(srf && srf.device && srf.device.device, "Present: invalid surface");
    assert(tex && tex.view, "Present: invalid texture");
    assert(srf.window != null && srf.window.alive, "Present: window gone");

    _, _, win_w, win_h, ok := GetDimensions(srf.window);
    if !ok || win_w == 0 || win_h == 0 {
        sleep_milliseconds(1);
        return;
    }
    if !srf.swapchain || win_w != srf.extent.width || win_h != srf.extent.height {
        surface_recreate_swapchain(srf, win_w, win_h);
        if !srf.swapchain return;
    }

    dev := srf.device;
    device := dev.device;

    vk_check(vkWaitForFences(device, 1, *srf.in_flight, VK_TRUE, 0xFFFF_FFFF_FFFF_FFFF));
    vk_check(vkResetFences(device, 1, *srf.in_flight));

    image_index: u32;
    acquire := vkAcquireNextImageKHR(
        device, srf.swapchain, 0xFFFF_FFFF_FFFF_FFFF,
        srf.image_available, null, *image_index,
    );
    if acquire == .ERROR_OUT_OF_DATE_KHR {
        surface_recreate_swapchain(srf, win_w, win_h);
        return;
    }
    assert(acquire == .SUCCESS || acquire == .SUBOPTIMAL_KHR, "AcquireNextImage failed: %", acquire);

    img_info: VkDescriptorImageInfo;
    img_info.imageView = tex.view;
    img_info.imageLayout = .SHADER_READ_ONLY_OPTIMAL;
    samp_info: VkDescriptorImageInfo;
    samp_info.sampler = srf.sampler;

    writes: [2] VkWriteDescriptorSet;
    writes[0].dstSet = srf.desc_set;
    writes[0].dstBinding = 0;
    writes[0].descriptorCount = 1;
    writes[0].descriptorType = .SAMPLED_IMAGE;
    writes[0].pImageInfo = *img_info;
    writes[1].dstSet = srf.desc_set;
    writes[1].dstBinding = 1;
    writes[1].descriptorCount = 1;
    writes[1].descriptorType = .SAMPLER;
    writes[1].pImageInfo = *samp_info;
    vkUpdateDescriptorSets(device, 2, writes.data, 0, null);

    vk_check(vkResetCommandBuffer(srf.cmd, xx 0));
    begin_info: VkCommandBufferBeginInfo;
    begin_info.flags = .ONE_TIME_SUBMIT_BIT;
    vk_check(vkBeginCommandBuffer(srf.cmd, *begin_info));

    // FrameBuffer leaves color as TRANSFER_SRC_OPTIMAL — transition for sampling.
    color_range := VkImageSubresourceRange.{.COLOR_BIT, 0, 1, 0, 1};
    insert_image_memory_barrier(
        srf.cmd, tex.image,
        .TRANSFER_READ_BIT, .SHADER_READ_BIT,
        .TRANSFER_SRC_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL,
        .TRANSFER_BIT, .FRAGMENT_SHADER_BIT,
        color_range,
    );

    clear: VkClearValue;
    clear.color._float32 = float.[0, 0, 0, 1];
    rp_begin: VkRenderPassBeginInfo;
    rp_begin.renderPass = srf.render_pass;
    rp_begin.framebuffer = srf.framebuffers[image_index];
    rp_begin.renderArea.extent = srf.extent;
    rp_begin.clearValueCount = 1;
    rp_begin.pClearValues = *clear;
    vkCmdBeginRenderPass(srf.cmd, *rp_begin, .INLINE);

    viewport: VkViewport;
    viewport.x = 0;
    viewport.y = 0;
    viewport.width = cast(float) srf.extent.width;
    viewport.height = cast(float) srf.extent.height;
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    vkCmdSetViewport(srf.cmd, 0, 1, *viewport);

    scissor: VkRect2D;
    scissor.offset = .{0, 0};
    scissor.extent = srf.extent;
    vkCmdSetScissor(srf.cmd, 0, 1, *scissor);

    vkCmdBindPipeline(srf.cmd, .GRAPHICS, srf.pipeline);
    vkCmdBindDescriptorSets(srf.cmd, .GRAPHICS, srf.pipeline_layout, 0, 1, *srf.desc_set, 0, null);
    vkCmdDraw(srf.cmd, 3, 1, 0, 0);

    vkCmdEndRenderPass(srf.cmd);
    vk_check(vkEndCommandBuffer(srf.cmd));

    wait_stage := VkPipelineStageFlags.COLOR_ATTACHMENT_OUTPUT_BIT;
    submit: VkSubmitInfo;
    submit.waitSemaphoreCount = 1;
    submit.pWaitSemaphores = *srf.image_available;
    submit.pWaitDstStageMask = *wait_stage;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = *srf.cmd;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = *srf.render_finished[image_index];
    vk_check(vkQueueSubmit(dev.graphics_queue, 1, *submit, srf.in_flight));

    present: VkPresentInfoKHR;
    present.waitSemaphoreCount = 1;
    present.pWaitSemaphores = *srf.render_finished[image_index];
    present.swapchainCount = 1;
    present.pSwapchains = *srf.swapchain;
    present.pImageIndices = *image_index;
    present_result := vkQueuePresentKHR(dev.graphics_queue, *present);
    if present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR {
        surface_recreate_swapchain(srf, win_w, win_h);
    } else {
        assert(present_result == .SUCCESS, "Present failed: %", present_result);
    }

    current_time: float64 = seconds_since_init();
    srf.delta_time = current_time - srf.last_time;
    ideal_delta_time: float64 = 1.0 / cast(float64) (ifx fps > 0 then fps else 60);
    while srf.delta_time < ideal_delta_time {
        sleep_milliseconds(1);
        current_time = seconds_since_init();
        srf.delta_time = current_time - srf.last_time;
    }
    srf.last_time = current_time;
}

Destroy :: (srf: *VulkanSurface($Window_t)) {
    if !srf || !srf.device || !srf.device.device return;
    device := srf.device.device;
    vkDeviceWaitIdle(device);

    if srf.in_flight then vkDestroyFence(device, srf.in_flight, null);
    if srf.image_available then vkDestroySemaphore(device, srf.image_available, null);
    if srf.cmd_pool then vkDestroyCommandPool(device, srf.cmd_pool, null);

    if srf.pipeline then vkDestroyPipeline(device, srf.pipeline, null);
    if srf.pipeline_layout then vkDestroyPipelineLayout(device, srf.pipeline_layout, null);
    if srf.shader_module then vkDestroyShaderModule(device, srf.shader_module, null);

    if srf.sampler then vkDestroySampler(device, srf.sampler, null);
    if srf.desc_pool then vkDestroyDescriptorPool(device, srf.desc_pool, null);
    if srf.desc_set_layout then vkDestroyDescriptorSetLayout(device, srf.desc_set_layout, null);

    surface_destroy_swapchain(srf);
    if srf.surface {
        vkDestroySurfaceKHR(srf.device.vulkan_context.instance, srf.surface, null);
    }
    if srf.render_pass then vkDestroyRenderPass(device, srf.render_pass, null);

    srf.* = .{};
}

#scope_file

add_available_instance_extensions :: (ext_names: *[..]*u8, wanted: [] string) {
    if wanted.count == 0 return;

    count: u32;
    vkEnumerateInstanceExtensionProperties(null, *count, null);
    if count == 0 return;

    props := NewArray(xx count, VkExtensionProperties);
    defer free(props.data);
    vk_check(vkEnumerateInstanceExtensionProperties(null, *count, props.data));

    for name: wanted {
        for i: 0..count-1 {
            if equal(to_string(props[i].extensionName.data), name) {
                array_add(ext_names, name.data);
                break;
            }
        }
    }
}

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

samples_to_vk :: (samples: u32) -> VkSampleCountFlagBits {
    if samples == 1 return ._1_BIT;
    if samples == 2 return ._2_BIT;
    if samples == 4 return ._4_BIT;
    if samples == 8 return ._8_BIT;
    assert(false, "unsupported sample count %", samples);
    return ._1_BIT;
}

create_image_2d :: (
    dev: *VulkanDevice,
    tex: *VulkanTexture2D,
    vk_format: VkFormat,
    size: Size2D,
    usage: VkImageUsageFlags,
    aspect: VkImageAspectFlags,
    mips: u32,
    samples: u32 = 1,
) {
    image_info: VkImageCreateInfo;
    image_info.imageType = ._2D;
    image_info.format = vk_format;
    image_info.extent.width = size.x;
    image_info.extent.height = size.y;
    image_info.extent.depth = 1;
    image_info.mipLevels = mips;
    image_info.arrayLayers = 1;
    image_info.samples = samples_to_vk(samples);
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

create_image_3d :: (
    dev: *VulkanDevice,
    tex: *VulkanTexture3D,
    vk_format: VkFormat,
    size: Size3D,
    usage: VkImageUsageFlags,
    aspect: VkImageAspectFlags,
    mips: u32,
) {
    image_info: VkImageCreateInfo;
    image_info.imageType = ._3D;
    image_info.format = vk_format;
    image_info.extent.width = size.x;
    image_info.extent.height = size.y;
    image_info.extent.depth = size.z;
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
    view_info.viewType = ._3D;
    view_info.format = vk_format;
    view_info.subresourceRange.aspectMask = aspect;
    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = mips;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 1;
    view_info.image = tex.image;
    vk_check(vkCreateImageView(dev.device, *view_info, null, *tex.view));
}

create_image_cube :: (
    dev: *VulkanDevice,
    tex: *VulkanTextureCube,
    vk_format: VkFormat,
    size: SizeCube,
    usage: VkImageUsageFlags,
    aspect: VkImageAspectFlags,
    mips: u32,
) {
    image_info: VkImageCreateInfo;
    image_info.flags = .CUBE_COMPATIBLE_BIT;
    image_info.imageType = ._2D;
    image_info.format = vk_format;
    image_info.extent.width = size.face;
    image_info.extent.height = size.face;
    image_info.extent.depth = 1;
    image_info.mipLevels = mips;
    image_info.arrayLayers = 6;
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
    view_info.viewType = .CUBE;
    view_info.format = vk_format;
    view_info.subresourceRange.aspectMask = aspect;
    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = mips;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 6;
    view_info.image = tex.image;
    vk_check(vkCreateImageView(dev.device, *view_info, null, *tex.view));
}

upload_image_2d_data :: (
    dev: *VulkanDevice,
    image: VkImage,
    width: u32,
    height: u32,
    depth: u32,
    data: *u8,
    size: s64,
) {
    staging: VkBuffer;
    staging_mem: VkDeviceMemory;
    create_vk_buffer(
        dev,
        .TRANSFER_SRC_BIT,
        .HOST_VISIBLE_BIT | .HOST_COHERENT_BIT,
        *staging,
        *staging_mem,
        xx size,
        data,
    );

    pool, cmd := create_command_pool_and_buffer(dev);
    begin_info: VkCommandBufferBeginInfo;
    begin_info.flags = .ONE_TIME_SUBMIT_BIT;
    vk_check(vkBeginCommandBuffer(cmd, *begin_info));

    color_range := VkImageSubresourceRange.{.COLOR_BIT, 0, 1, 0, 1};
    insert_image_memory_barrier(
        cmd, image,
        xx 0, .TRANSFER_WRITE_BIT,
        .UNDEFINED, .TRANSFER_DST_OPTIMAL,
        .TOP_OF_PIPE_BIT, .TRANSFER_BIT,
        color_range,
    );

    region: VkBufferImageCopy;
    region.imageSubresource.aspectMask = .COLOR_BIT;
    region.imageSubresource.layerCount = 1;
    region.imageExtent.width = width;
    region.imageExtent.height = height;
    region.imageExtent.depth = depth;
    vkCmdCopyBufferToImage(cmd, staging, image, .TRANSFER_DST_OPTIMAL, 1, *region);

    insert_image_memory_barrier(
        cmd, image,
        .TRANSFER_WRITE_BIT, .SHADER_READ_BIT,
        .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL,
        .TRANSFER_BIT, .FRAGMENT_SHADER_BIT,
        color_range,
    );

    vk_check(vkEndCommandBuffer(cmd));
    submit_work(dev, cmd, wait = true);
    vkDestroyCommandPool(dev.device, pool, null);

    vkDestroyBuffer(dev.device, staging, null);
    vkFreeMemory(dev.device, staging_mem, null);
}

destroy_image_resources :: (device: VkDevice, image: VkImage, view: VkImageView, memory: VkDeviceMemory) {
    if view then vkDestroyImageView(device, view, null);
    if image then vkDestroyImage(device, image, null);
    if memory then vkFreeMemory(device, memory, null);
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
