// Slang features: embedded modules, entries, matrices
main :: () {
    ctx := Context(flags = .ENABLE_DEBUG);
    defer Destroy(*ctx);
    dev := Device(*ctx);
    defer Destroy(*dev);

    shdr := Spawn(*dev, LIT_SLANG, .["vs_main", "fs_main"]);
    defer Destroy(*shdr);

    print("slang_features:\n");
    print("  - GpuShader($source, $stages)\n");
    print("  - uniforms Set(shdr.MVP / LightDir / Ambient)\n");
    print("  - matrix layout contract: row-major\n");
}

#import "Basic";
#import "String";
#import "GPU";
#load "../_common/shaders.jai";
