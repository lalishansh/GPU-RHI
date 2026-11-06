// Extra shader stages (tessellation) — requires ENABLE_TESSELLATION on Context.
main :: () {
    ctx := Context(flags = .ENABLE_DEBUG | .ENABLE_TESSELLATION);
    defer Destroy(*ctx);
    dev := Device(*ctx);
    defer Destroy(*dev);

    shdr := Spawn(*dev, TESS_SLANG, .["vs_main", "hs_main", "ds_main", "fs_main"]);
    defer Destroy(*shdr);

    print("tessellation VulkanShader: vs=% hs=% ds=% fs=%\n",
        shdr.vs_entry, shdr.hs_entry, shdr.ds_entry, shdr.fs_entry);
}

#import "Basic";
#import "String";
#import "GPU";
#load "../_common/shaders.jai";
