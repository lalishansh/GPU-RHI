// RT (later): Dispatching the Rays
main :: () {

    ray_tracing_not_ready("rt03_dispatch_rays");

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
