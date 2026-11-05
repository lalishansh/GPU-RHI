// GPU particles: compute update + raster draw
main :: () {
    ctx := Context(flags = .ENABLE_DEBUG);
    defer Destroy(*ctx);
    dev := Device(*ctx);
    defer Destroy(*dev);

    Particle :: struct {
        Pos: Vector3;
        Vel: Vector3;
        GPU_USAGE :: BUFFER_USAGE.STORAGE;
    }
    particles := Particle.[
        .{.{0, 1, 0}, .{0.1, 0.5, 0}},
        .{.{0.2, 1, 0}, .{-0.1, 0.4, 0.05}},
    ];
    buf := Buffer(*dev, particles);
    defer Destroy(*buf);

    cs := Spawn(*dev, PARTICLE_UPDATE_SLANG, .["cs_main"]);
    defer Destroy(*cs);

    cq := Queue(*dev, .COMPUTE);
    for Pass(*cq, *cs) {
        Set(*buf);
    }
    Submit(*cq, groups_x = 1);
    print("compute updated % particles (COMPUTE Queue + Submit)\n", particles.count);

    tex := Texture(*dev, Size2D.{512, 512});
    defer Destroy(*tex);
    fb := FrameBuffer(*tex);
    defer Destroy(*fb);
    gq := Queue(*dev, .GRAPHICS);
    Bind(*gq, *fb);
    Submit(*gq, wait = true);
    print("gpu_particles: compute+graphics queues exercised\n");
}

#import "Basic";
#import "Math";
#import "String";
#import "GPU";
#load "../_common/shaders.jai";
