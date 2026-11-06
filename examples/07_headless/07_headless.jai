// Headless offscreen render → PPM (host) / draw-only (WASM)
#if OS == .WASM {
    #program_export
    main :: () { headless_main(); }
} else {
    main :: () { headless_main(); }
}

headless_main :: () {
    #if OS == .LINUX {
        path := path_strip_filename(get_path_of_running_executable());
        set_working_directory(path);
    }

    ctx := Context(flags = .ENABLE_DEBUG);
    defer Destroy(*ctx);
    dev := Device(*ctx);
    defer Destroy(*dev);

    tex := Texture(*dev, Size2D.{640, 360});
    defer Destroy(*tex);
    fb := FrameBuffer(*tex);
    defer Destroy(*fb);

    shdr := Spawn(*dev, UNLIT_COLOR_SLANG, .["vs_main", "fs_main"]);
    defer Destroy(*shdr);

    verts := shdr.Vertex_t.[
        .{.{ 0.0,  0.8, 0}, .{1,0,0}, .{0,0,1}},
        .{.{-0.8, -0.8, 0}, .{0,1,0}, .{0,0,1}},
        .{.{ 0.8, -0.8, 0}, .{0,0,1}, .{0,0,1}},
    ];
    indices := IndexU32_t.[0, 1, 2];
    vbo := Buffer(*dev, verts); defer Destroy(*vbo);
    ibo := Buffer(*dev, indices); defer Destroy(*ibo);

    q := Queue(*dev, .GRAPHICS);
    Bind(*q, *fb);
    for Pass(*q, *shdr) {
        Set(*vbo); Set(*ibo);
        Set(shdr.MVP, Matrix4_Identity);
        Record();
    }
    Submit(*q, wait = true);

    #if OS != .WASM {
        bytes := Get(*tex); defer free(bytes.data);
        write_to_image(bytes, "07_headless.ppm", tex.size.x, tex.size.y);
    } else {
        print("07_headless: rendered %x% (no PPM on WASM)\n", tex.size.x, tex.size.y);
    }
}

#import "Basic";
#import "Math";
#import "String";
#import "GPU";
#if OS != .WASM {
    #import "File";
}
#if OS == .LINUX {
    #import "System";
}
#if OS != .WASM {
    #load "../_common/ppm.jai";
}
#load "../_common/shaders.jai";
