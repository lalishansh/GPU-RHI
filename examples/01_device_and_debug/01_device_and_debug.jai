// NVRHI-style: Creating the Device + Debug & Validation
#if OS == .WASM {
    #program_export
    main :: () { device_main(); }
} else {
    main :: () { device_main(); }
}

device_main :: () {
    #if OS == .WASM {
        ctx := Context(.WEBGPU, name = "GPU-RHI", flags = .ENABLE_DEBUG);
    } else {
        ctx := Context(
            .VULKAN,
            name = "GPU-RHI",
            flags = .ENABLE_DEBUG | .ENABLE_VALIDATION,
        );
    }
    defer Destroy(*ctx);

    dev := Device(*ctx);
    defer Destroy(*dev);

    print("Device ready: \"%\" via Context name=\"%\"\n", dev.name, ctx.name);
}

#import "Basic";
#import "String";
#import "GPU";
