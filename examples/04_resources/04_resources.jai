// NVRHI-style: Creating resources (2D / 3D / Cube + buffers)
#if OS == .WASM {
    #program_export
    main :: () { resources_main(); }
} else {
    main :: () { resources_main(); }
}

resources_main :: () {
    ctx := Context(flags = .ENABLE_DEBUG);
    defer Destroy(*ctx);
    dev := Device(*ctx);
    defer Destroy(*dev);

    color := Texture(*dev, Size2D.{1024, 1024},
        format = .R8G8B8A8_UNORM,
        locality = .CREATE_ON_DEVICE,
        usage = .COLOR_ATTACHMENT | .SAMPLED | .COPY_SRC,
        mips = 1,
        samples = 1,
    );
    defer Destroy(*color);

    depth := Texture(*dev, Size2D.{1024, 1024},
        format = .D32_SFLOAT,
        usage = .DEPTH_STENCIL,
    );
    defer Destroy(*depth);

    msaa := Texture(*dev, Size2D.{1024, 1024}, samples = 4);
    defer Destroy(*msaa);

    volume := Texture(*dev, Size3D.{64, 64, 64}, usage = .SAMPLED | .COPY_DST);
    defer Destroy(*volume);

    cube := Texture(*dev, SizeCube.{256}, usage = .SAMPLED | .COPY_DST);
    defer Destroy(*cube);

    shdr := Spawn(*dev, UNLIT_COLOR_SLANG, .["vs_main", "fs_main"]);
    defer Destroy(*shdr);

    verts := shdr.Vertex_t.[
        .{.{0,0,0}, .{1,0,0}, .{0,0,1}},
    ];
    vbo := Buffer(*dev, verts, locality = .CREATE_ON_DEVICE);
    defer Destroy(*vbo);

    indices := IndexU32_t.[0, 1, 2];
    ibo := Buffer(*dev, indices);
    defer Destroy(*ibo);

    print("2D %x% depth=% msaa=% vol=%x%x%x cube_face=% vbo=% ibo_count=%\n",
        color.size.x, color.size.y, depth.format, msaa.samples,
        volume.size.x, volume.size.y, volume.size.z, cube.size.face, vbo.size, ibo.count);
}

#import "Basic";
#import "String";
#import "GPU";
#load "../_common/shaders.jai";
