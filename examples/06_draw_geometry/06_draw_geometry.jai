// NVRHI-style: Drawing geometry — tetrahedron, MVP, camera, ambient + directional light
WINDOW_W :: 1280;
WINDOW_H :: 720;

main :: () {
    #if OS == .LINUX {
        path := path_strip_filename(get_path_of_running_executable());
        set_working_directory(path);
    }

    ctx := Context(flags = .ENABLE_DEBUG);
    defer Destroy(*ctx);
    dev := Device(*ctx);
    defer Destroy(*dev);

    tex := Texture(*dev, Size2D.{WINDOW_W, WINDOW_H});
    defer Destroy(*tex);
    depth := Texture(*dev, Size2D.{WINDOW_W, WINDOW_H}, format = .D32_SFLOAT, usage = .DEPTH_STENCIL);
    defer Destroy(*depth);
    fb := FrameBuffer(*tex, depth_texture = *depth, clear_color = .{0.05, 0.05, 0.08, 1});
    defer Destroy(*fb);

    shdr := Spawn(*dev, LIT_SLANG, .["vs_main", "fs_main"]);
    defer Destroy(*shdr);

    verts := shdr.Vertex_t.[
        .{.{ 1,  1,  1}, .{1, 0.2, 0.2}, .{ 1,  1,  1}},
        .{.{-1, -1,  1}, .{1, 0.2, 0.2}, .{ 1,  1,  1}},
        .{.{-1,  1, -1}, .{1, 0.2, 0.2}, .{ 1,  1,  1}},

        .{.{ 1,  1,  1}, .{0.2, 1, 0.2}, .{ 1, -1, -1}},
        .{.{-1,  1, -1}, .{0.2, 1, 0.2}, .{ 1, -1, -1}},
        .{.{ 1, -1, -1}, .{0.2, 1, 0.2}, .{ 1, -1, -1}},

        .{.{ 1,  1,  1}, .{0.2, 0.2, 1}, .{-1,  1, -1}},
        .{.{ 1, -1, -1}, .{0.2, 0.2, 1}, .{-1,  1, -1}},
        .{.{-1, -1,  1}, .{0.2, 0.2, 1}, .{-1,  1, -1}},

        .{.{-1, -1,  1}, .{1, 1, 0.2}, .{-1, -1,  1}},
        .{.{ 1, -1, -1}, .{1, 1, 0.2}, .{-1, -1,  1}},
        .{.{-1,  1, -1}, .{1, 1, 0.2}, .{-1, -1,  1}},
    ];
    indices := IndexU32_t.[0,1,2, 3,4,5, 6,7,8, 9,10,11];

    vbo := Buffer(*dev, verts);
    defer Destroy(*vbo);
    ibo := Buffer(*dev, indices);
    defer Destroy(*ibo);

    aspect := cast(float) WINDOW_W / cast(float) WINDOW_H;
    proj := make_projection_matrix(70.0 * PI / 180.0, aspect, 0.1, 100.0, depth_range_01 = true);
    eye := Vector3.{2.5, 1.8, 2.5};
    target := Vector3.{0, 0, 0};
    up := Vector3.{0, 1, 0};
    view := make_look_at_matrix(eye, target, up, x_is_forward = false);
    model := Matrix4_Identity;
    mvp := proj * view * model;

    light_dir := Vector3.{0.4, -1.0, 0.3};
    ambient: float = 0.15;

    q := Queue(*dev, .GRAPHICS);
    Bind(*q, *fb);
    for Pass(*q, *shdr) {
        Set(*vbo);
        Set(*ibo);
        Set(shdr.MVP, mvp);
        Set(shdr.LightDir, light_dir);
        Set(shdr.Ambient, ambient);
        Record();
    }
    Submit(*q, wait = true);

    bytes := Get(*tex);
    defer free(bytes.data);
    write_to_image(bytes, "06_draw_geometry.ppm", WINDOW_W, WINDOW_H);
}

#import "Basic";
#import "File";
#import "Math";
#import "String";
#import "GPU";
#if OS == .LINUX {
    #import "System";
}
#load "../_common/ppm.jai";
#load "../_common/shaders.jai";
