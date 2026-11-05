// NVRHI-style: Creating the Device + Debug & Validation
main :: () {
    // Context($api) like pre-rewrite; Context() defaults to VULKAN.
    ctx := Context(
        .VULKAN,
        name = "GPU-RHI",
        flags = .ENABLE_DEBUG | .ENABLE_VALIDATION,
    );
    defer Destroy(*ctx);

    dev := Device(*ctx);
    defer Destroy(*dev);

    print("Device ready: \"%\" via Context name=\"%\" (VulkanContext)\n", dev.name, ctx.name);
}

#import "Basic";
#import "String";
#import "GPU";
