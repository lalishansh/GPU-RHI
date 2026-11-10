// Shared Cornell-box scene helpers for raster + compute examples.
// Room cube (camera inside), two floor cuboids, emissive ceiling quad.

CORNELL_W :: 800;
CORNELL_H :: 600;

Cornell_Vertex :: struct {
    Pos: Vector3;
    Color: Vector3;
    Normal: Vector3;
}

Cornell_Mesh :: struct {
    verts: [..] Cornell_Vertex;
    indices: [..] IndexU32_t;
}

cornell_camera_eye    :: () -> Vector3 { return .{0.0, 0.0, 0.55}; }
cornell_camera_target :: () -> Vector3 { return .{0.0, -0.1, -0.8}; }
cornell_camera_up     :: () -> Vector3 { return .{0.0, 1.0, 0.0}; }
cornell_light_pos     :: () -> Vector3 { return .{0.0, 0.92, 0.0}; }

cornell_mvp :: (aspect: float) -> Matrix4 {
    return cornell_mvp(aspect, cornell_camera_eye(), cornell_camera_target());
}

cornell_mvp :: (aspect: float, eye: Vector3, target: Vector3) -> Matrix4 {
    proj := make_projection_matrix(70.0 * PI / 180.0, aspect, 0.05, 20.0, depth_range_01 = true);
    view := make_look_at_matrix(eye, target, cornell_camera_up(), x_is_forward = false);
    return proj * view;
}

key_is_forward :: (k: u8) -> bool {
    return k == KEY_W || k == KEY_UP || k == KEY_ANDROID_W || k == KEY_ANDROID_DPAD_UP;
}
key_is_back :: (k: u8) -> bool {
    return k == KEY_S || k == KEY_DOWN || k == KEY_ANDROID_S || k == KEY_ANDROID_DPAD_DOWN;
}
key_is_left :: (k: u8) -> bool {
    return k == KEY_A || k == KEY_LEFT || k == KEY_ANDROID_A || k == KEY_ANDROID_DPAD_LEFT;
}
key_is_right :: (k: u8) -> bool {
    return k == KEY_D || k == KEY_RIGHT || k == KEY_ANDROID_D || k == KEY_ANDROID_DPAD_RIGHT;
}

cornell_apply_camera_keys :: (
    cam_pos: *Vector3,
    cam_fwd: Vector3,
    held_fwd: bool, held_back: bool, held_left: bool, held_right: bool,
    move_speed: float = 0.035,
) {
    world_up := Vector3.{0, 1, 0};
    right := normalize(cross(cam_fwd, world_up));
    if length(right) < 0.0001 {
        right = normalize(cross(cam_fwd, Vector3.{0, 0, 1}));
    }
    if held_fwd   cam_pos.* += cam_fwd * move_speed;
    if held_back  cam_pos.* -= cam_fwd * move_speed;
    if held_left  cam_pos.* -= right * move_speed;
    if held_right cam_pos.* += right * move_speed;
    cam_pos.x = clamp(cam_pos.x, -0.85, 0.85);
    cam_pos.y = clamp(cam_pos.y, -0.85, 0.85);
    cam_pos.z = clamp(cam_pos.z, -0.85, 0.85);
}

append_quad :: (
    mesh: *Cornell_Mesh,
    p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
    color: Vector3, nrm: Vector3,
) {
    base := cast(u32) mesh.verts.count;
    array_add(*mesh.verts, .{p0, color, nrm});
    array_add(*mesh.verts, .{p1, color, nrm});
    array_add(*mesh.verts, .{p2, color, nrm});
    array_add(*mesh.verts, .{p3, color, nrm});
    array_add(*mesh.indices, base + 0);
    array_add(*mesh.indices, base + 1);
    array_add(*mesh.indices, base + 2);
    array_add(*mesh.indices, base + 0);
    array_add(*mesh.indices, base + 2);
    array_add(*mesh.indices, base + 3);
}

// Axis-aligned box. inward=true → normals face inside (room walls).
append_box :: (
    mesh: *Cornell_Mesh,
    bmin: Vector3, bmax: Vector3,
    color: Vector3,
    inward := false,
) {
    x0 := bmin.x; y0 := bmin.y; z0 := bmin.z;
    x1 := bmax.x; y1 := bmax.y; z1 := bmax.z;
    s: float = ifx inward then -1.0 else 1.0;

    // +Z / -Z
    append_quad(mesh,
        .{x0,y0,z1}, .{x1,y0,z1}, .{x1,y1,z1}, .{x0,y1,z1},
        color, .{0, 0, s});
    append_quad(mesh,
        .{x1,y0,z0}, .{x0,y0,z0}, .{x0,y1,z0}, .{x1,y1,z0},
        color, .{0, 0, -s});
    // +X / -X
    append_quad(mesh,
        .{x1,y0,z1}, .{x1,y0,z0}, .{x1,y1,z0}, .{x1,y1,z1},
        color, .{s, 0, 0});
    append_quad(mesh,
        .{x0,y0,z0}, .{x0,y0,z1}, .{x0,y1,z1}, .{x0,y1,z0},
        color, .{-s, 0, 0});
    // +Y / -Y
    append_quad(mesh,
        .{x0,y1,z1}, .{x1,y1,z1}, .{x1,y1,z0}, .{x0,y1,z0},
        color, .{0, s, 0});
    append_quad(mesh,
        .{x0,y0,z0}, .{x1,y0,z0}, .{x1,y0,z1}, .{x0,y0,z1},
        color, .{0, -s, 0});
}

build_cornell_mesh :: () -> Cornell_Mesh {
    mesh: Cornell_Mesh;

    // Room cube — inward-facing so camera inside sees walls.
    // Classic-ish palette: red left, green right, white elsewhere.
    white := Vector3.{0.75, 0.75, 0.75};
    red   := Vector3.{0.75, 0.12, 0.12};
    green := Vector3.{0.12, 0.55, 0.12};

    // Floor / ceiling / back as white; left/right tinted via separate thin boxes
    // so each face can keep a constant color with append_box.
    append_box(*mesh, .{-1, -1, -1}, .{1, 1, 1}, white, inward = true);

    // Overpaint left (-X) and right (+X) with tinted inward faces (thin slabs).
    append_quad(*mesh,
        .{-0.999, -1, -1}, .{-0.999, -1, 1}, .{-0.999, 1, 1}, .{-0.999, 1, -1},
        red, .{1, 0, 0});
    append_quad(*mesh,
        .{0.999, -1, 1}, .{0.999, -1, -1}, .{0.999, 1, -1}, .{0.999, 1, 1},
        green, .{-1, 0, 0});

    // Tall cuboid (left of center) sitting on floor y=-1.
    append_box(*mesh, .{-0.65, -1.0, -0.55}, .{-0.20, 0.15, -0.05}, .{0.85, 0.85, 0.7});
    // Short wide cuboid (right of center).
    append_box(*mesh, .{0.10, -1.0, -0.10}, .{0.55, -0.35, 0.40}, .{0.7, 0.85, 0.85});

    // Emissive ceiling quad (on top face of room).
    emit := Vector3.{12.0, 12.0, 10.0};
    append_quad(*mesh,
        .{-0.35, 0.995, -0.25}, .{0.35, 0.995, -0.25},
        .{0.35, 0.995,  0.25}, .{-0.35, 0.995,  0.25},
        emit, .{0, -1, 0});

    return mesh;
}

Destroy :: (mesh: *Cornell_Mesh) {
    array_free(mesh.verts);
    array_free(mesh.indices);
}

copy_cornell_vertices :: (dst: [] $V, src: [] Cornell_Vertex) {
    assert(dst.count == src.count, "copy_cornell_vertices: count mismatch");
    for i: 0..src.count-1 {
        dst[i].Pos = src[i].Pos;
        dst[i].Color = src[i].Color;
        dst[i].Normal = src[i].Normal;
    }
}
