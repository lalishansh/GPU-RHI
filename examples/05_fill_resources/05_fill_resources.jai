// NVRHI-style: Filling resource data
#if OS == .WASM {
    #program_export
    main :: () { fill_resources_main(); }
} else {
    main :: () { fill_resources_main(); }
}

fill_resources_main :: () {
    ctx := Context(flags = .ENABLE_DEBUG);
    defer Destroy(*ctx);
    dev := Device(*ctx);
    defer Destroy(*dev);

    shdr := Spawn(*dev, UNLIT_COLOR_SLANG, .["vs_main", "fs_main"]);
    defer Destroy(*shdr);

    verts := shdr.Vertex_t.[
        .{.{-0.5, -0.5, 0}, .{1,0,0}, .{0,0,1}},
        .{.{ 0.5, -0.5, 0}, .{0,1,0}, .{0,0,1}},
        .{.{ 0.0,  0.5, 0}, .{0,0,1}, .{0,0,1}},
    ];
    vbo := Buffer(*dev, verts);
    defer Destroy(*vbo);
    Update(*vbo, verts);

    tex := Texture(*dev, Size2D.{4, 4}, locality = .CREATE_ON_HOST);
    defer Destroy(*tex);
    pixels: [4*4*4] u8;
    for 0..pixels.count-1 pixels[it] = cast(u8) ((it * 17) & 0xFF);
    Update(*tex, pixels);

    print("filled vbo (% bytes) and %x% texture\n", vbo.size, tex.size.x, tex.size.y);
}

#import "Basic";
#import "String";
#import "GPU";
#load "../_common/shaders.jai";
