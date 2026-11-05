// NVRHI-style: Surface (swapchain stand-in)
main :: () {
    ctx := Context(flags = .ENABLE_DEBUG | .ENABLE_SURFACE);
    defer Destroy(*ctx);
    require_feature(*ctx, .SURFACE);

    dev := Device(*ctx);
    defer Destroy(*dev);

    srf := Surface(*dev, 1280, 720);
    defer Destroy(*srf);

    backbuffer := Texture(*dev, Size2D.{srf.width, srf.height}, usage = .COLOR_ATTACHMENT | .SAMPLED | .COPY_SRC);
    defer Destroy(*backbuffer);
    fb := FrameBuffer(*backbuffer);
    defer Destroy(*fb);

    print("Surface %x% ready (Present deferred until window backend)\n", srf.width, srf.height);
}

#import "Basic";
#import "String";
#import "GPU";
