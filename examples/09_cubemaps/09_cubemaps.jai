// Cubemap via SizeCube → GpuTextureCube
main :: () {
    ctx := Context(flags = .ENABLE_DEBUG);
    defer Destroy(*ctx);
    dev := Device(*ctx);
    defer Destroy(*dev);

    env := Texture(*dev, SizeCube.{512}, usage = .SAMPLED | .COPY_DST);
    defer Destroy(*env);

    print("Cubemap face=% (6 faces)\n", env.size.face);
}

#import "Basic";
#import "String";
#import "GPU";
