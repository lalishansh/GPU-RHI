// NVRHI-style: Graphics pipeline (embedded shader + pass)
main :: () {
    ctx := Context(flags = .ENABLE_DEBUG);
    defer Destroy(*ctx);
    dev := Device(*ctx);
    defer Destroy(*dev);

    tex := Texture(*dev, Size2D.{800, 600});
    defer Destroy(*tex);
    fb := FrameBuffer(*tex);
    defer Destroy(*fb);

    shdr := Spawn(*dev, UNLIT_COLOR_SLANG, .["vs_main", "fs_main"]);
    defer Destroy(*shdr);

    print("Pipeline GpuShader($source,$stages), vs=% fs=%\n", shdr.vs_entry, shdr.fs_entry);

    q := Queue(*dev, .GRAPHICS);
    Bind(*q, *fb);
    Submit(*q, wait = true);
}

#import "Basic";
#import "String";
#import "GPU";
#load "../_common/shaders.jai";
