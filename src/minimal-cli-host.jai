WINDOW_WIDTH  :: 1920;
WINDOW_HEIGHT :: 1080;

main :: () {
    #if OS == .LINUX {
        // Android module already sets cwd to externalDataPath; WASM has no exe path.
        path := path_strip_filename(get_path_of_running_executable());
        set_working_directory(path);
    }

    ctx := Context();
    defer Destroy(*ctx);

    dev := Device(*ctx);
    defer Destroy(*dev);

    tex := Texture(*dev, Size2D.{WINDOW_WIDTH, WINDOW_HEIGHT});
    defer Destroy(*tex);

    shdr := Spawn(*dev, "assets/shaders/triangle.slang", .["vs_main", "fs_main"]);
    defer Destroy(*shdr);

    verts := shdr.Vertex_t.[
        .{.{ 1.0,  1.0, 0.0}, .{1.0, 0.0, 0.0}},
        .{.{-1.0,  1.0, 0.0}, .{0.0, 1.0, 0.0}},
        .{.{ 0.0, -1.0, 0.0}, .{0.0, 0.0, 1.0}},
    ];
    indices := IndexU32_t.[0, 1, 2];

    vtx_data := Buffer(*dev, verts);
    defer Destroy(*vtx_data);
    idx_data := Buffer(*dev, indices);
    defer Destroy(*idx_data);

    frm_buf := FrameBuffer(*tex);
    defer Destroy(*frm_buf);

    // Render
    q := Queue(*dev, .GRAPHICS);

    Bind(*q, *frm_buf);
    for Pass(*q, *shdr) {
        Set(*vtx_data);
        Set(*idx_data);

        mvp: Matrix4;
        mvp = make_translation_matrix4(Vector3.{0, 0, 0});
        Set(shdr.MVP, mvp);
        Record();

        mvp = make_translation_matrix4(Vector3.{-0.2, -0.2, 0.1});
        Set(shdr.MVP, mvp);
        Record();

        mvp = make_translation_matrix4(Vector3.{+0.2, -0.2, 0.2});
        Set(shdr.MVP, mvp);
        Record();

        mvp = make_translation_matrix4(Vector3.{-0.2, +0.2, 0.3});
        Set(shdr.MVP, mvp);
        Record();

        mvp = make_translation_matrix4(Vector3.{+0.2, +0.2, 0.4});
        Set(shdr.MVP, mvp);
        Record();
    }

    Submit(*q, wait = true);

    bytes := Get(*tex);
    defer free(bytes.data);
    write_to_image(bytes, "triangle.ppm", WINDOW_WIDTH, WINDOW_HEIGHT);
}

write_to_image :: (bytes: [] u8, filename: string, width: u32, height: u32) {
    assert(bytes.count >= cast(s64) (width * height * 4), "write_to_image: buffer too small");

    builder: String_Builder;
    defer reset(*builder);
    append(*builder, "P6\n");
    print_to_builder(*builder, "% %\n255\n", width, height);

    pixel_count := cast(s64) (width * height);
    for i: 0..pixel_count - 1 {
        base := i * 4;
        append(*builder, bytes[base + 0]);
        append(*builder, bytes[base + 1]);
        append(*builder, bytes[base + 2]);
    }

    if write_entire_file(filename, *builder) {
        print("Wrote % (%x%)\n", filename, width, height);
    } else {
        log_error("Failed to write %\n", filename);
    }
}

#import "Basic";
#import "File";
#import "Math";
#import "String";
#import "GPU";
#if OS == .LINUX {
    #import "System";
}
