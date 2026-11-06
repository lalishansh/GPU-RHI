// Threaded rendering: one graphics queue per thread-slot
main :: () {
    ctx := Context(flags = .ENABLE_DEBUG);
    defer Destroy(*ctx);
    dev := Device(*ctx);
    defer Destroy(*dev);

    THREADS :: 4;
    for 0..THREADS-1 {
        q := Queue(*dev, .GRAPHICS);
        defer Destroy(*q);
        print("thread-slot % → graphics queue (api from Device)\n", it);
    }
    print("threaded_rendering: % typed graphics queues\n", THREADS);
}

#import "Basic";
#import "String";
#import "GPU";
