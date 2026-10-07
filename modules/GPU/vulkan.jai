DEBUG :: true;

VK_KHR_XLIB_SURFACE_EXTENSION_NAME :: "VK_KHR_xlib_surface";
VK_KHR_ANDROID_SURFACE_EXTENSION_NAME :: "VK_KHR_android_surface";

#if OS == .LINUX {
    VkXlibSurfaceCreateFlagsKHR :: u32;

    VkXlibSurfaceCreateInfoKHR :: struct {
        sType:   VkStructureType;
        pNext:   *void;
        flags:   VkXlibSurfaceCreateFlagsKHR;
        dpy:     *X11.Display;
        window:  X11.Window;
    }

    PFN_vkCreateXlibSurfaceKHR :: #type (
        instance: VkInstance,
        pCreateInfo: *VkXlibSurfaceCreateInfoKHR,
        pAllocator: *VkAllocationCallbacks,
        pSurface: *VkSurfaceKHR,
    ) -> VkResult #c_call;
}

#if OS == .ANDROID {
    VkAndroidSurfaceCreateFlagsKHR :: u32;

    VkAndroidSurfaceCreateInfoKHR :: struct {
        sType:  VkStructureType;
        pNext:  *void;
        flags:  VkAndroidSurfaceCreateFlagsKHR;
        window: *Android.ANativeWindow;
    }

    PFN_vkCreateAndroidSurfaceKHR :: #type (
        instance: VkInstance,
        pCreateInfo: *VkAndroidSurfaceCreateInfoKHR,
        pAllocator: *VkAllocationCallbacks,
        pSurface: *VkSurfaceKHR,
    ) -> VkResult #c_call;
}

VulkanShaderUniformDefinition :: struct {
    name: string;
    type: Type;
    offset: u32;
    set: u32;
    binding: u32;
    stage_flags: u32;
}

is_push_constant :: (d: VulkanShaderUniformDefinition) -> bool {
    return d.set == VULKAN_UNIFORM_PUSH_CONSTANT && d.binding == VULKAN_UNIFORM_PUSH_CONSTANT;
}

// ----------
// GPU helper structs and functions

MAX_INSTANCE_LAYERS :: 64;
MAX_PHYSICAL_DEVICES :: 8;
MAX_QUEUE_FAMILIES :: 16;

VulkanContext :: struct {
    instance: VkInstance;
    debug_report_callback: VkDebugReportCallbackEXT;
}

Context :: ($api: API) -> VulkanContext
    #modify { return api == .VULKAN, "This overload is for API.VULKAN."; }
{
    ctx: VulkanContext;

    app_info: VkApplicationInfo;
    app_info.pApplicationName = "GPU-RHI".data;
    app_info.pEngineName = "GPU-RHI".data;
    app_info.apiVersion = VK_API_VERSION_1_2;

    instance_create_info: VkInstanceCreateInfo;
    instance_create_info.pApplicationInfo = *app_info;

    ext_names: [..]*u8;
    defer array_free(ext_names);
    array_add(*ext_names, VK_KHR_SURFACE_EXTENSION_NAME.data);
    #if OS == .LINUX {
        array_add(*ext_names, VK_KHR_XLIB_SURFACE_EXTENSION_NAME.data);
    } else #if OS == .ANDROID {
        array_add(*ext_names, VK_KHR_ANDROID_SURFACE_EXTENSION_NAME.data);
    }

    layers_available := false;
    #if DEBUG {
        layer_count: u32;
        vkEnumerateInstanceLayerProperties(*layer_count, null);
        if layer_count > MAX_INSTANCE_LAYERS {
            log("Too many instance layers (%); truncating to %", layer_count, MAX_INSTANCE_LAYERS);
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

    #if DEBUG {
        if layers_available {
            debug_info: VkDebugReportCallbackCreateInfoEXT;
            debug_info.flags = .ERROR_BIT_EXT | .WARNING_BIT_EXT;
            debug_info.pfnCallback = debug_message_callback;

            create_cb: PFN_vkCreateDebugReportCallbackEXT =
                xx vkGetInstanceProcAddr(ctx.instance, "vkCreateDebugReportCallbackEXT");
            assert(create_cb != null);
            vk_check(create_cb(ctx.instance, *debug_info, null, *ctx.debug_report_callback));
        }
    }

    return ctx;
}

Context :: () -> VulkanContext {
    return Context(.VULKAN);
}

Destroy :: (ctx: *VulkanContext) {
    #if DEBUG {
        if ctx.debug_report_callback {
            destroy_cb: PFN_vkDestroyDebugReportCallbackEXT =
                xx vkGetInstanceProcAddr(ctx.instance, "vkDestroyDebugReportCallbackEXT");
            if destroy_cb then destroy_cb(ctx.instance, ctx.debug_report_callback, null);
            ctx.debug_report_callback = null;
        }
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
}

Device :: (ctx: *VulkanContext) -> VulkanDevice {
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
    print("GPU: %\n", to_string(props.deviceName.data));

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

    device_exts: [1]*u8;
    device_exts[0] = VK_KHR_SWAPCHAIN_EXTENSION_NAME.data;
    device_create_info.enabledExtensionCount = 1;
    device_create_info.ppEnabledExtensionNames = device_exts.data;

    vk_check(vkCreateDevice(dev.physical_device, *device_create_info, null, *dev.device));

    vkGetDeviceQueue(dev.device, dev.queue_family_index, 0, *dev.graphics_queue);

    return dev;
}

Destroy :: (dev: *VulkanDevice) {
    if !dev.device return;
    vkDeviceWaitIdle(dev.device);
    vkDestroyDevice(dev.device, null);
    dev.device = null;
    dev.graphics_queue = null;
}

VulkanBuffer :: struct {
    device: *VulkanDevice;
    size: u64;
    usage: BUFFER_USAGE;
    buffer: VkBuffer;
    memory: VkDeviceMemory;
}

Buffer :: (dev: *VulkanDevice, data: [] $T) -> VulkanBuffer {
    usage := buffer_usage_for(T);

    buf: VulkanBuffer;
    buf.device = dev;
    buf.size = xx (data.count * size_of(T));
    buf.usage = usage;

    vk_usage := buffer_usage_to_vk(usage) | .TRANSFER_DST_BIT;

    create_vk_buffer(
        dev,
        vk_usage,
        .DEVICE_LOCAL_BIT,
        *buf.buffer,
        *buf.memory,
        xx buf.size,
        null,
    );

    if data.count {
        staging: VkBuffer;
        staging_mem: VkDeviceMemory;
        create_vk_buffer(
            dev,
            .TRANSFER_SRC_BIT,
            .HOST_VISIBLE_BIT | .HOST_COHERENT_BIT,
            *staging,
            *staging_mem,
            xx buf.size,
            data.data,
        );

        upload_pool, upload_cmd := create_command_pool_and_buffer(dev);
        begin_info: VkCommandBufferBeginInfo;
        begin_info.flags = .ONE_TIME_SUBMIT_BIT;
        vk_check(vkBeginCommandBuffer(upload_cmd, *begin_info));

        copy_region: VkBufferCopy;
        copy_region.size = xx buf.size;
        vkCmdCopyBuffer(upload_cmd, staging, buf.buffer, 1, *copy_region);

        vk_check(vkEndCommandBuffer(upload_cmd));
        submit_work(dev, upload_cmd, wait = true);
        vkDestroyCommandPool(dev.device, upload_pool, null);

        vkDestroyBuffer(dev.device, staging, null);
        vkFreeMemory(dev.device, staging_mem, null);
    }

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

VulkanTexture :: struct {
    device: *VulkanDevice;
    size: Size2D;
    vk_format: VkFormat;
    image: VkImage;
    memory: VkDeviceMemory;
    view: VkImageView;
}

Texture :: (dev: *VulkanDevice, size: Size2D) -> VulkanTexture {
    tex: VulkanTexture;
    tex.device = dev;
    tex.size = size;
    tex.vk_format = .R8G8B8A8_UNORM;
    create_color_image(dev, *tex, tex.vk_format, size, .COLOR_ATTACHMENT_BIT | .TRANSFER_SRC_BIT | .SAMPLED_BIT, .COLOR_BIT);
    return tex;
}

Get :: (tex: *VulkanTexture) -> []u8 {
    assert(tex.device && tex.device.device, "Get: invalid texture");
    dev := tex.device;
    device := dev.device;
    width := tex.size.width;
    height := tex.size.height;
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

Destroy :: (tex: *VulkanTexture) {
    if !tex.device || !tex.device.device return;
    destroy_image_resources(tex.device.device, tex);
}

Update :: (tex: *VulkanTexture, new_size: Size2D) {
    assert(tex.device && tex.device.device, "Update: invalid texture");
    assert(new_size.width > 0 && new_size.height > 0, "Update: size must be non-zero");
    if tex.size.width == new_size.width && tex.size.height == new_size.height return;

    vkDeviceWaitIdle(tex.device.device);
    destroy_image_resources(tex.device.device, tex);
    tex.size = new_size;
    usage, aspect := image_usage_for_format(tex.vk_format);
    create_color_image(tex.device, tex, tex.vk_format, new_size, usage, aspect);
}

VulkanSurface :: struct {
    device: *VulkanDevice;
    window: *CrossWindowType;
    last_time: float64;
    delta_time: float64;

    surface: VkSurfaceKHR;
    #if OS == .ANDROID {
        // ANativeWindow used to create `surface` — rotation/TERM_WINDOW replaces it.
        android_window: *Android.ANativeWindow;
    }
    surface_format: VkSurfaceFormatKHR;
    present_mode: VkPresentModeKHR;
    extent: VkExtent2D;

    swapchain: VkSwapchainKHR;
    swapchain_images: [..]VkImage;
    swapchain_views: [..]VkImageView;
    framebuffers: [..]VkFramebuffer;

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
    render_finished: [..]VkSemaphore;
    in_flight: VkFence;
}

PRESENT_SHADER_SLANG :: #string SLANG_CODE
// Fullscreen triangle for presenting an offscreen color target to the swapchain.
// Vertex positions match the classic SV_VertexID trick.

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

#if OS == .ANDROID {

// Host-baked present SPIR-V (slangc). No libslang in the APK.
ANDROID_PRESENT_SPIRV_MEMBERS :: #run,host -> string {
    #import "Basic";
    #import "String";
    File :: #import "File";
    Process :: #import "Process";
    GPU :: #import "GPU";

    source := GPU.PRESENT_SHADER_SLANG;

    File.make_directory_if_it_does_not_exist(".bin/.build", recursive = true);
    assert(File.write_entire_file(".bin/.build/present_bake.slang", source), "write present_bake.slang failed");
    // Nix FHS LD_LIBRARY_PATH stack-smashes the host slangc binary — clear it.
    result, stdout, stderr := Process.run_command(
        "env", "-u", "LD_LIBRARY_PATH",
        "slangc", ".bin/.build/present_bake.slang",
        "-target", "spirv", "-fvk-use-entrypoint-name",
        "-matrix-layout-row-major",
        "-o", ".bin/.build/present.spv",
        capture_and_return_output = true,
    );
    assert(result.type != .FAILED_TO_LAUNCH, "slangc not found on PATH");
    assert(result.exit_code == 0, "slangc present failed:\n%\n%", stdout, stderr);
    data, ok := File.read_entire_file(".bin/.build/present.spv");
    assert(ok && data.count > 0, "read present.spv failed");

    builder: String_Builder;
    print_to_builder(*builder, "spirv :: u8.[\n");
    for i: 0..data.count-1 {
        print_to_builder(*builder, "%,", data[i]);
        if (i + 1) % 16 == 0 then print_to_builder(*builder, "\n");
    }
    print_to_builder(*builder, "\n];\n");
    return builder_to_string(*builder);
}

ANDROID_TRIANGLE_SHADER_MEMBERS :: #run,host -> string {
    #import "Basic";
    #import "String";
    File :: #import "File";
    Process :: #import "Process";

    File.make_directory_if_it_does_not_exist(".bin/.build", recursive = true);
    // Nix FHS LD_LIBRARY_PATH stack-smashes the host slangc binary — clear it.
    result, stdout, stderr := Process.run_command(
        "env", "-u", "LD_LIBRARY_PATH",
        "slangc", "assets/shaders/triangle.slang",
        "-target", "spirv", "-fvk-use-entrypoint-name",
        "-matrix-layout-row-major",
        "-entry", "vs_main", "-stage", "vertex",
        "-entry", "fs_main", "-stage", "fragment",
        "-o", ".bin/.build/triangle.spv",
        capture_and_return_output = true,
    );
    assert(result.type != .FAILED_TO_LAUNCH, "slangc not found on PATH");
    assert(result.exit_code == 0, "slangc triangle failed:\n%\n%", stdout, stderr);
    data, ok := File.read_entire_file(".bin/.build/triangle.spv");
    assert(ok && data.count > 0, "read triangle.spv failed");

    // Matrix4 is 16 floats = 64 bytes (matches Math::Matrix4).
    MATRIX4_BYTES :: 64;

    builder: String_Builder;
    print_to_builder(*builder, "Vertex_t :: struct {\n");
    print_to_builder(*builder, "    GPU_USAGE :: BUFFER_USAGE.VERTEX;\n");
    print_to_builder(*builder, "    Pos: Vector3;\n");
    print_to_builder(*builder, "    Color: Vector3;\n");
    print_to_builder(*builder, "};\n\n");
    print_to_builder(*builder, "MVP :: VulkanShaderUniformDefinition.{\n");
    print_to_builder(*builder, "    name = \"MVP\",\n");
    print_to_builder(*builder, "    type = type_of(Matrix4),\n");
    print_to_builder(*builder, "    offset = 0,\n");
    print_to_builder(*builder, "    set = VULKAN_UNIFORM_PUSH_CONSTANT,\n");
    print_to_builder(*builder, "    binding = VULKAN_UNIFORM_PUSH_CONSTANT,\n");
    print_to_builder(*builder, "    stage_flags = 1,\n");
    print_to_builder(*builder, "};\n\n");
    print_to_builder(*builder, "vs_entry :: \"vs_main\";\n");
    print_to_builder(*builder, "fs_entry :: \"fs_main\";\n");
    print_to_builder(*builder, "push_constant_bytes :: %;\n\n", MATRIX4_BYTES);
    print_to_builder(*builder, "spirv_raw :: u8.[\n");
    for i: 0..data.count-1 {
        print_to_builder(*builder, "%,", data[i]);
        if (i + 1) % 16 == 0 then print_to_builder(*builder, "\n");
    }
    print_to_builder(*builder, "\n];\n");
    return builder_to_string(*builder);
}

}

// Bake present SPIR-V at compile time so Android/device builds need no slang runtime.
PresentShaderSpirv :: struct {
    #insert -> string {
        #if OS == .ANDROID {
            return ANDROID_PRESENT_SPIRV_MEMBERS;
        } else {
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
}

Surface :: (dev: *VulkanDevice, window: *CrossWindowType) -> VulkanSurface {
    assert(dev && dev.device && dev.vulkan_context, "Surface: invalid device");
    assert(window != null, "Surface: null window");

    srf: VulkanSurface;
    srf.device = dev;
    srf.window = window;
    srf.delta_time = 0.0;
    srf.last_time = seconds_since_init();

    instance := dev.vulkan_context.instance;

    // --- VkSurfaceKHR ---
    #if OS == .LINUX {
        assert(X11.x_global_display != null, "Surface: X11 display not initialized (create_window first)");

        create_xlib: VkXlibSurfaceCreateInfoKHR;
        create_xlib.sType = .XLIB_SURFACE_CREATE_INFO_KHR;
        create_xlib.dpy = X11.x_global_display;
        create_xlib.window = window.host;

        create_xlib_surface: PFN_vkCreateXlibSurfaceKHR =
            xx vkGetInstanceProcAddr(instance, "vkCreateXlibSurfaceKHR");
        assert(create_xlib_surface != null, "vkCreateXlibSurfaceKHR missing");
        vk_check(create_xlib_surface(instance, *create_xlib, null, *srf.surface));
    } else #if OS == .ANDROID {
        assert(window.host != null, "Surface: null ANativeWindow (wait for foreground)");
        surface_create_android_vk_surface(*srf, window.host);
    } else {
        assert(false, "Surface: unsupported OS");
    }

    #if OS != .ANDROID {
        present_supported: VkBool32;
        vk_check(vkGetPhysicalDeviceSurfaceSupportKHR(
            dev.physical_device, dev.queue_family_index, srf.surface, *present_supported,
        ));
        assert(present_supported != 0, "Surface: queue family lacks present support");
    }

    // --- Format / present mode ---
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

    // --- Fullscreen-triangle render pass (swapchain color → PRESENT) ---
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

    // --- Swapchain (extent from window; recreated on resize in Present) ---
    {
        _, _, win_w, win_h := Window.get_dimensions(window.host, false);
        surface_recreate_swapchain(*srf, cast(u32) win_w, cast(u32) win_h);
    }

    // --- Present shaders (fullscreen triangle VS + sample FS) ---
    {
        assert(PresentShaderSpirv.spirv.count > 0, "Surface: present shader produced empty SPIR-V");

        module_info: VkShaderModuleCreateInfo;
        module_info.codeSize = xx PresentShaderSpirv.spirv.count;
        module_info.pCode = cast(*u32) PresentShaderSpirv.spirv.data;
        vk_check(vkCreateShaderModule(dev.device, *module_info, null, *srf.shader_module));
    }

    // Descriptor: texture (0) + sampler (1)
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

    // Fullscreen-triangle graphics pipeline (no vertex buffers — SV_VertexID only)
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
    // render_finished semaphores are created in surface_recreate_swapchain
    fence_info: VkFenceCreateInfo;
    fence_info.flags = .SIGNALED_BIT;
    vk_check(vkCreateFence(dev.device, *fence_info, null, *srf.in_flight));

    return srf;
}

surface_destroy_swapchain :: (srf: *VulkanSurface) {
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

#if OS == .ANDROID {

surface_destroy_vk_surface :: (srf: *VulkanSurface) {
    surface_destroy_swapchain(srf);
    if srf.surface && srf.device && srf.device.vulkan_context {
        vkDestroySurfaceKHR(srf.device.vulkan_context.instance, srf.surface, null);
        srf.surface = null;
    }
    srf.android_window = null;
    srf.extent = .{};
}

surface_create_android_vk_surface :: (srf: *VulkanSurface, window: *Android.ANativeWindow) {
    assert(srf.device && srf.device.device && srf.device.vulkan_context, "android surface: invalid device");
    assert(window != null && window != Window.WT.INVALID_WINDOW, "android surface: null window");

    instance := srf.device.vulkan_context.instance;

    create_android: VkAndroidSurfaceCreateInfoKHR;
    create_android.sType = .ANDROID_SURFACE_CREATE_INFO_KHR;
    create_android.window = window;

    create_android_surface: PFN_vkCreateAndroidSurfaceKHR =
        xx vkGetInstanceProcAddr(instance, "vkCreateAndroidSurfaceKHR");
    assert(create_android_surface != null, "vkCreateAndroidSurfaceKHR missing");
    vk_check(create_android_surface(instance, *create_android, null, *srf.surface));
    srf.android_window = window;

    present_supported: VkBool32;
    vk_check(vkGetPhysicalDeviceSurfaceSupportKHR(
        srf.device.physical_device, srf.device.queue_family_index, srf.surface, *present_supported,
    ));
    assert(present_supported != 0, "Surface: queue family lacks present support");
}

// Rotation / TERM+INIT_WINDOW replace ANativeWindow; VkSurfaceKHR must be rebuilt.
surface_rebind_android_window :: (srf: *VulkanSurface, window: *Android.ANativeWindow) {
    if window == null || window == Window.WT.INVALID_WINDOW {
        surface_destroy_vk_surface(srf);
        return;
    }
    if srf.android_window == window && srf.surface return;

    surface_destroy_vk_surface(srf);
    surface_create_android_vk_surface(srf, window);

    _, _, win_w, win_h := Window.get_dimensions(window, false);
    if win_w > 0 && win_h > 0 {
        surface_recreate_swapchain(srf, cast(u32) win_w, cast(u32) win_h);
    }
}

}

surface_recreate_swapchain :: (srf: *VulkanSurface, width: u32, height: u32) {
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

    min_images: u32 = 2;
    if srf.present_mode == .MAILBOX_KHR then min_images = 3;
    if min_images < caps.minImageCount then min_images = caps.minImageCount;
    if caps.maxImageCount > 0 && min_images > caps.maxImageCount then min_images = caps.maxImageCount;

    // Prefer INHERIT on Android; fall back to any supported bit.
    composite := VkCompositeAlphaFlagBitsKHR.OPAQUE_BIT_KHR;
    if caps.supportedCompositeAlpha & .OPAQUE_BIT_KHR {
        composite = .OPAQUE_BIT_KHR;
    } else if caps.supportedCompositeAlpha & .INHERIT_BIT_KHR {
        composite = .INHERIT_BIT_KHR;
    } else if caps.supportedCompositeAlpha & .PRE_MULTIPLIED_BIT_KHR {
        composite = .PRE_MULTIPLIED_BIT_KHR;
    } else if caps.supportedCompositeAlpha & .POST_MULTIPLIED_BIT_KHR {
        composite = .POST_MULTIPLIED_BIT_KHR;
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

    // Drop old swapchain resources only after the new one exists.
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

Present :: (srf: *VulkanSurface, tex: *VulkanTexture, fps: u32) {
    assert(srf && srf.device && srf.device.device, "Present: invalid surface");
    assert(tex && tex.view, "Present: invalid texture");
    assert(srf.window != null, "Present: no window");

    win_w: s32 = 0;
    win_h: s32 = 0;

    #if OS == .ANDROID {
        // :AndroidLifeCycle — TERM_WINDOW nulls the host; INIT_WINDOW gives a new ANativeWindow.
        // Resize can also arrive before TERM; recreating a swapchain on a dying
        // ANativeWindow/VkSurfaceKHR crashes the Adreno driver in vkCreateFramebuffer.
        if srf.window.host == null || srf.window.host == Window.WT.INVALID_WINDOW {
            surface_destroy_vk_surface(srf);
            sleep_milliseconds(1);
            return;
        }

        _, _, win_w, win_h = Window.get_dimensions(srf.window.host, false);
        if win_w <= 0 || win_h <= 0 {
            surface_destroy_vk_surface(srf);
            sleep_milliseconds(1);
            return;
        }

        needs_rebind := !srf.surface
            || srf.android_window != srf.window.host
            || !srf.swapchain
            || cast(u32) win_w != srf.extent.width
            || cast(u32) win_h != srf.extent.height;
        if needs_rebind {
            surface_rebind_android_window(srf, srf.window.host);
            if !srf.swapchain {
                sleep_milliseconds(1);
                return;
            }
        }
    } else {
        if srf.window.host == Window.WT.INVALID_WINDOW {
            sleep_milliseconds(1);
            return;
        }

        _, _, win_w, win_h = Window.get_dimensions(srf.window.host, false);
        if win_w <= 0 || win_h <= 0 {
            sleep_milliseconds(1);
            return;
        }
        if !srf.swapchain || cast(u32) win_w != srf.extent.width || cast(u32) win_h != srf.extent.height {
            surface_recreate_swapchain(srf, cast(u32) win_w, cast(u32) win_h);
            if !srf.swapchain return;
        }
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
        #if OS == .ANDROID {
            surface_rebind_android_window(srf, srf.window.host);
        } else {
            surface_recreate_swapchain(srf, cast(u32) win_w, cast(u32) win_h);
        }
        return;
    }
    assert(acquire == .SUCCESS || acquire == .SUBOPTIMAL_KHR, "AcquireNextImage failed: %", acquire);

    // Bind source texture for the fullscreen sample pass.
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
    vkCmdDraw(srf.cmd, 3, 1, 0, 0); // fullscreen triangle via SV_VertexID

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
        #if OS == .ANDROID {
            surface_rebind_android_window(srf, srf.window.host);
        } else {
            surface_recreate_swapchain(srf, cast(u32) win_w, cast(u32) win_h);
        }
    } else {
        assert(present_result == .SUCCESS, "Present failed: %", present_result);
    }

    // Frame pacing
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

Destroy :: (srf: *VulkanSurface) {
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

    #if OS == .ANDROID {
        surface_destroy_vk_surface(srf);
    } else {
        surface_destroy_swapchain(srf);
        if srf.surface {
            vkDestroySurfaceKHR(srf.device.vulkan_context.instance, srf.surface, null);
        }
    }

    if srf.render_pass then vkDestroyRenderPass(device, srf.render_pass, null);

    srf.* = .{};
}



VulkanFrameBuffer :: struct {
    device: *VulkanDevice;
    textures: []*VulkanTexture;
    render_pass: VkRenderPass;
    framebuffer: VkFramebuffer;
    depth_tex: VulkanTexture;
}

FrameBuffer :: (textures: .. *VulkanTexture) -> VulkanFrameBuffer {
    assert(textures.count > 0, "FrameBuffer requires at least one color texture");
    tex := textures[0];
    dev := tex.device;
    for t: textures {
        assert(t.device == dev, "FrameBuffer textures must share a device");
        assert(t.size.width == tex.size.width && t.size.height == tex.size.height, "FrameBuffer textures must match size");
    }

    fb: VulkanFrameBuffer;
    fb.device = dev;
    fb.textures = textures;

    depth_vk := find_depth_format(dev.physical_device);
    assert(depth_vk != .UNDEFINED, "No supported depth format");
    fb.depth_tex.device = dev;
    fb.depth_tex.size = tex.size;
    fb.depth_tex.vk_format = depth_vk;
    create_color_image(
        dev,
        *fb.depth_tex,
        depth_vk,
        tex.size,
        .DEPTH_STENCIL_ATTACHMENT_BIT,
        depth_aspect_mask(depth_vk),
    );

    attachments: [2] VkAttachmentDescription;
    attachments[0].format = tex.vk_format;
    attachments[0].samples = ._1_BIT;
    attachments[0].loadOp = .CLEAR;
    attachments[0].storeOp = .STORE;
    attachments[0].stencilLoadOp = .DONT_CARE;
    attachments[0].stencilStoreOp = .DONT_CARE;
    attachments[0].initialLayout = .UNDEFINED;
    attachments[0].finalLayout = .TRANSFER_SRC_OPTIMAL;

    attachments[1].format = fb.depth_tex.vk_format;
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

    views := VkImageView.[tex.view, fb.depth_tex.view];
    fb_info: VkFramebufferCreateInfo;
    fb_info.renderPass = fb.render_pass;
    fb_info.attachmentCount = 2;
    fb_info.pAttachments = views.data;
    fb_info.width = tex.size.width;
    fb_info.height = tex.size.height;
    fb_info.layers = 1;
    vk_check(vkCreateFramebuffer(dev.device, *fb_info, null, *fb.framebuffer));

    return fb;
}

Bind :: (q: *VulkanQueue, frm_buf: *VulkanFrameBuffer) {
    update_depth_texture_on_size_changed(frm_buf);
    tex := frm_buf.textures[0];

    clear_values: [2] VkClearValue;
    clear_values[0].color._float32 = float.[0.0, 0.0, 0.2, 1.0];
    clear_values[1].depthStencil = .{1.0, 0};

    begin_info: VkRenderPassBeginInfo;
    begin_info.renderPass = frm_buf.render_pass;
    begin_info.framebuffer = frm_buf.framebuffer;
    begin_info.renderArea.extent.width = tex.size.width;
    begin_info.renderArea.extent.height = tex.size.height;
    begin_info.clearValueCount = 2;
    begin_info.pClearValues = clear_values.data;
    vkCmdBeginRenderPass(q.cmd, *begin_info, .INLINE);

    q.render_pass_active = true;
    q.bound_framebuffer = frm_buf;
    q.index_count = 0;
}

Destroy :: (frm_buf: *VulkanFrameBuffer) {
    if !frm_buf.device || !frm_buf.device.device return;
    device := frm_buf.device.device;

    if frm_buf.framebuffer {
        vkDestroyFramebuffer(device, frm_buf.framebuffer, null);
        frm_buf.framebuffer = null;
    }
    if frm_buf.render_pass {
        vkDestroyRenderPass(device, frm_buf.render_pass, null);
        frm_buf.render_pass = null;
    }
    destroy_image_resources(device, *frm_buf.depth_tex);
}

VulkanShader :: struct ($path: string, $stages: []string) {
    device: *VulkanDevice;
    shader_module: VkShaderModule;
    pipeline_layout: VkPipelineLayout;
    pipeline: VkPipeline;
    compatible_render_pass: VkRenderPass;
    #insert -> string {
        #if OS == .ANDROID {
            assert(
                equal(path, "assets/shaders/triangle.slang") || ends_with(path, "triangle.slang"),
                "Android: no host-baked shader members for '%'", path,
            );
            return ANDROID_TRIANGLE_SHADER_MEMBERS;
        } else {
            blueprint := Shader(path);
            return emit_vulkan_shader_members(blueprint, stages);
        }
    }
}

#if OS != .ANDROID {

emit_vulkan_shader_members :: (shader: ShaderBlueprint, stages: []string) -> string {
    builder: String_Builder;

    for ep: shader.entry_points {
        if ep.type != .VERTEX_SHADER continue;
        if !stage_selected(ep.name, stages) continue;

        print_to_builder(*builder, "Vertex_t :: struct {\n");
        print_to_builder(*builder, "    GPU_USAGE :: BUFFER_USAGE.VERTEX;\n");
        for field: ep.inputs {
            print_to_builder(*builder, "    %: %;\n", field.name, type_info_source_name(field.type));
        }
        print_to_builder(*builder, "};\n\n");
        break;
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
    for ep: shader.entry_points {
        if !stage_selected(ep.name, stages) continue;
        if ep.type == .VERTEX_SHADER then vs_name = ep.name;
        if ep.type == .FRAGMENT_SHADER then fs_name = ep.name;
    }
    print_to_builder(*builder, "vs_entry :: \"%\";\n", vs_name);
    print_to_builder(*builder, "fs_entry :: \"%\";\n", fs_name);
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

stage_selected :: (entry_name: string, stages: []string) -> bool {
    for s: stages {
        if s == entry_name return true;
    }
    return false;
}

} // #if OS != .ANDROID

Spawn :: (dev: *VulkanDevice, $path: string, $stages: []string) -> VulkanShader(path, stages) {
    Shader_t :: VulkanShader(path, stages);
    shdr: Shader_t;
    shdr.device = dev;

    assert(Shader_t.spirv_raw.count > 0, "Spawn: empty SPIR-V for '%'", path);

    module_info: VkShaderModuleCreateInfo;
    module_info.codeSize = xx Shader_t.spirv_raw.count;
    module_info.pCode = cast(*u32) Shader_t.spirv_raw.data;
    vk_check(vkCreateShaderModule(dev.device, *module_info, null, *shdr.shader_module));

    push_constant_range: VkPushConstantRange;
    push_constant_range.stageFlags = .VERTEX_BIT;
    push_constant_range.offset = 0;
    push_constant_range.size = Shader_t.push_constant_bytes;

    layout_info: VkPipelineLayoutCreateInfo;
    if Shader_t.push_constant_bytes {
        layout_info.pushConstantRangeCount = 1;
        layout_info.pPushConstantRanges = *push_constant_range;
    }
    vk_check(vkCreatePipelineLayout(dev.device, *layout_info, null, *shdr.pipeline_layout));

    // Compatible RP matching FrameBuffer (R8G8B8A8 color + depth) for pipeline create.
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

Destroy :: (shdr: *VulkanShader($path, $stages)) {
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

VulkanPass :: struct(VulkanShader_t: Type) {
    queue: *VulkanQueue;
    shader: *VulkanShader_t;
}

Pass :: (q: *VulkanQueue, shdr: *VulkanShader($path, $stages)) -> [1]VulkanPass(VulkanShader(path, stages)) {
    assert(q.bound_framebuffer != null, "Pass: Bind a FrameBuffer before Pass");
    assert(q.render_pass_active, "Pass: render pass not active");

    vkCmdBindPipeline(q.cmd, .GRAPHICS, shdr.pipeline);

    tex := q.bound_framebuffer.textures[0];
    viewport: VkViewport;
    viewport.x = 0;
    viewport.y = 0;
    viewport.width = cast(float) tex.size.width;
    viewport.height = cast(float) tex.size.height;
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    vkCmdSetViewport(q.cmd, 0, 1, *viewport);

    scissor: VkRect2D;
    scissor.offset.x = 0;
    scissor.offset.y = 0;
    scissor.extent.width = tex.size.width;
    scissor.extent.height = tex.size.height;
    vkCmdSetScissor(q.cmd, 0, 1, *scissor);

    return .[.{queue = q, shader = shdr}];
}

VulkanQueue :: struct {
    device: *VulkanDevice;
    type: QUEUE_TYPE;
    command_pool: VkCommandPool;
    cmd: VkCommandBuffer;
    render_pass_active: bool;
    bound_framebuffer: *VulkanFrameBuffer;
    index_count: u32;
}

Queue :: (dev: *VulkanDevice, type: QUEUE_TYPE) -> VulkanQueue {
    assert(type == .GRAPHICS, "Only GRAPHICS queue implemented");

    pool, cmd := create_command_pool_and_buffer(dev);

    begin_info: VkCommandBufferBeginInfo;
    vk_check(vkBeginCommandBuffer(cmd, *begin_info));

    return VulkanQueue.{
        device = dev,
        type = type,
        command_pool = pool,
        cmd = cmd,
        render_pass_active = false,
        bound_framebuffer = null,
        index_count = 0,
    };
}

Submit :: (q: *VulkanQueue, wait: bool) {
    if q.render_pass_active {
        vkCmdEndRenderPass(q.cmd);
        q.render_pass_active = false;
    }
    vk_check(vkEndCommandBuffer(q.cmd));
    submit_work(q.device, q.cmd, wait);

    if q.command_pool {
        vkDestroyCommandPool(q.device.device, q.command_pool, null);
        q.command_pool = null;
        q.cmd = null;
    }
}

// ----------
// GPU Shader helper structs, functions and macros

Set :: (buf: *VulkanBuffer) #expand {
    Set(`it, buf);
}

Set :: (pass: VulkanPass($S), buf: *VulkanBuffer) {
    q := pass.queue;
    if buf.usage == .VERTEX {
        offsets := VkDeviceSize.[0];
        vkCmdBindVertexBuffers(q.cmd, 0, 1, *buf.buffer, offsets.data);
    } else if buf.usage == .INDEX {
        vkCmdBindIndexBuffer(q.cmd, buf.buffer, 0, .UINT32);
        q.index_count = cast(u32) (buf.size / size_of(u32));
    } else {
        assert(false, "Set(buffer): expected VERTEX or INDEX usage");
    }
}

Set :: (def: VulkanShaderUniformDefinition, val: $T) #expand {
    Set(`it, def, val);
}

Set :: (pass: VulkanPass($S), def: VulkanShaderUniformDefinition, val: $T) {
    assert(is_push_constant(def), "Set(uniform): UBO path not implemented yet");

    q := pass.queue;
    shdr := pass.shader;

    // Upload Matrix4 bytes as-is. Slang SPIR-V mul(MVP, v) matches Math::Matrix4
    // memory layout for this project; callers should not transpose before Set.
    vkCmdPushConstants(
        q.cmd,
        shdr.pipeline_layout,
        xx def.stage_flags,
        def.offset,
        xx size_of(T),
        *val,
    );
}

Record :: () #expand {
    Record(`it);
}

Record :: (pass: VulkanPass($S)) {
    q := pass.queue;
    assert(q.index_count > 0, "Record: no index buffer Set");
    vkCmdDrawIndexed(q.cmd, q.index_count, 1, 0, 0, 0);
}

#scope_file

vk_check :: (result: VkResult, loc := #caller_location) {
    if result != .SUCCESS {
        log_error("Fatal: VkResult is % (%) at %:%\n", result, cast(s32) result, loc.fully_pathed_filename, loc.line_number);
        exit(1);
    }
}

debug_message_callback :: (
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

update_depth_texture_on_size_changed :: (frm_buf: *VulkanFrameBuffer) {
    if !frm_buf.device || !frm_buf.device.device || frm_buf.textures.count == 0 return;
    tex := frm_buf.textures[0];
    if !tex return;
    if frm_buf.framebuffer
        && frm_buf.depth_tex.size.width == tex.size.width
        && frm_buf.depth_tex.size.height == tex.size.height return;

    for t: frm_buf.textures {
        assert(t.size.width == tex.size.width && t.size.height == tex.size.height, "Bind: framebuffer textures must match size");
    }

    vkDeviceWaitIdle(frm_buf.device.device);
    device := frm_buf.device.device;

    if frm_buf.framebuffer {
        vkDestroyFramebuffer(device, frm_buf.framebuffer, null);
        frm_buf.framebuffer = null;
    }
    destroy_image_resources(device, *frm_buf.depth_tex);
    frm_buf.depth_tex.device = frm_buf.device;
    frm_buf.depth_tex.size = tex.size;
    create_color_image(
        frm_buf.device,
        *frm_buf.depth_tex,
        frm_buf.depth_tex.vk_format,
        tex.size,
        .DEPTH_STENCIL_ATTACHMENT_BIT,
        depth_aspect_mask(frm_buf.depth_tex.vk_format),
    );

    views := VkImageView.[tex.view, frm_buf.depth_tex.view];
    fb_info: VkFramebufferCreateInfo;
    fb_info.renderPass = frm_buf.render_pass;
    fb_info.attachmentCount = 2;
    fb_info.pAttachments = views.data;
    fb_info.width = tex.size.width;
    fb_info.height = tex.size.height;
    fb_info.layers = 1;
    vk_check(vkCreateFramebuffer(device, *fb_info, null, *frm_buf.framebuffer));
}

image_usage_for_format :: (format: VkFormat) -> VkImageUsageFlags, VkImageAspectFlags {
    if format == .D32_SFLOAT_S8_UINT || format == .D32_SFLOAT
        || format == .D24_UNORM_S8_UINT || format == .D16_UNORM_S8_UINT || format == .D16_UNORM {
        return .DEPTH_STENCIL_ATTACHMENT_BIT, depth_aspect_mask(format);
    }
    return .COLOR_ATTACHMENT_BIT | .TRANSFER_SRC_BIT | .SAMPLED_BIT, .COLOR_BIT;
}

depth_aspect_mask :: (format: VkFormat) -> VkImageAspectFlags {
    aspect: VkImageAspectFlags = .DEPTH_BIT;
    if cast(u32) format >= cast(u32) VkFormat.D16_UNORM_S8_UINT {
        aspect |= .STENCIL_BIT;
    }
    return aspect;
}

create_color_image :: (
    dev: *VulkanDevice,
    tex: *VulkanTexture,
    vk_format: VkFormat,
    size: Size2D,
    usage: VkImageUsageFlags,
    aspect: VkImageAspectFlags,
) {
    image_info: VkImageCreateInfo;
    image_info.imageType = ._2D;
    image_info.format = vk_format;
    image_info.extent.width = size.width;
    image_info.extent.height = size.height;
    image_info.extent.depth = 1;
    image_info.mipLevels = 1;
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
    view_info.subresourceRange.levelCount = 1;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 1;
    view_info.image = tex.image;
    vk_check(vkCreateImageView(dev.device, *view_info, null, *tex.view));
}

destroy_image_resources :: (device: VkDevice, tex: *VulkanTexture) {
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