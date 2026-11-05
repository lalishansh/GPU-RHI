// Extra shader stages (tessellation) — flag gate until hull/domain Spawn is supported.
// Incomplete TESS_SLANG hull/domain stubs crash slang reflection/link; do not Spawn yet.
main :: () {
    ctx := Context(flags = .ENABLE_DEBUG);
    defer Destroy(*ctx);
    dev := Device(*ctx);
    defer Destroy(*dev);

    if (ctx.flags & .ENABLE_TESSELLATION) != 0 {
        print("ENABLE_TESSELLATION set — hull/domain Spawn still deferred\n");
    } else {
        print("tessellation: Context without ENABLE_TESSELLATION; stages listed in TESS_SLANG for later\n");
        print("  entries: vs_main, hs_main, ds_main, fs_main\n");
    }
    _ := TESS_SLANG;
    _ := dev;
}

#import "Basic";
#import "String";
#import "GPU";
#load "../_common/shaders.jai";
