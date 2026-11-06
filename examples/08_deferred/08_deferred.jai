// Deferred: G-buffer MRT + depth (GpuFrameBuffer(2, true))
main :: () {
    ctx := Context(flags = .ENABLE_DEBUG);
    defer Destroy(*ctx);
    dev := Device(*ctx);
    defer Destroy(*dev);

    albedo := Texture(*dev, Size2D.{1280, 720}, usage = .COLOR_ATTACHMENT | .SAMPLED);
    defer Destroy(*albedo);
    normals := Texture(*dev, Size2D.{1280, 720}, usage = .COLOR_ATTACHMENT | .SAMPLED);
    defer Destroy(*normals);
    depth := Texture(*dev, Size2D.{1280, 720}, format = .D32_SFLOAT, usage = .DEPTH_STENCIL);
    defer Destroy(*depth);

    gbuffer := FrameBuffer(.[*albedo, *normals], depth_texture = *depth);
    defer Destroy(*gbuffer);

    print("Deferred G-buffer: FrameBuffer(.[albedo, normals], depth_texture)\n");
}

#import "Basic";
#import "String";
#import "GPU";
