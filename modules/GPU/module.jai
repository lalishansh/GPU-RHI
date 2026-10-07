#import "Basic";
#import "Math";
#import "String";
#import "CrossWindow";

#if OS != .WASM {
    #import "Vulkan";
    Window :: #import "Window_Creation";
    #if OS == .LINUX {
        X11 :: #import "X11";
    } else #if OS == .ANDROID {
        Android :: #import "Android";
    }
    #if OS != .ANDROID {
        slang :: #import "slang";
    }
}

API :: enum u8 {
    VULKAN;
    WEBGPU;
}

Size2D :: struct {
    width: u32;
    height: u32;
}

BUFFER_USAGE :: enum u8 {
    VERTEX;
    INDEX;
    UNIFORM;
    STORAGE;
}

QUEUE_TYPE :: enum u8 {
    GRAPHICS;
    COMPUTE;
    TRANSFER;
}

TEXTURE_FORMAT :: enum u8 {
    R8;
    R8G8;
    R8G8B8;
    R8G8B8A8;
    R16;
    R16G16;
    R16G16B16;
    R16G16B16A16;
    R32;
    R32G32;
    R32G32B32;
    R32G32B32A32;
}

SHADER_STAGE :: enum {
    VERTEX;
    PIXEL;
    COMPUTE;
}

EntryPoint :: struct {
    stage: SHADER_STAGE;
    name: string;
}

f32 :: float32;
f64 :: float64;

float3 :: [3]f32;
float4 :: [4]f32;
float4x4 :: [4*4]f32;

IndexU8_t  :: u8;
IndexU16_t :: u16;
IndexU32_t :: u32;
IndexU64_t :: u64;

buffer_usage_for :: ($T: Type) -> BUFFER_USAGE {
    #if T == u32 {
        return .INDEX;
    } else #if #exists(T.GPU_USAGE) {
        return T.GPU_USAGE;
    } else {
        return .VERTEX;
    }
}

VULKAN_UNIFORM_PUSH_CONSTANT :: cast(u32) 0xFFFF_FFFF;

#if OS == .WASM {
    jsPerformanceNowMs :: () -> float64 #foreign;
    app_time :: () -> float64 { return jsPerformanceNowMs() / 1000.0; }
} else {
    app_time :: () -> float64 { return seconds_since_init(); }
}

#if OS == .WASM {
    // No libslang in .wasm — shaders are baked via #run,host + slangc → WGSL.
    #load "webgpu.jai";
} else #if OS == .ANDROID {
    // No slang_reflect / libslang in the APK — shaders are baked via #run,host + slangc.
    #load "vulkan.jai";
} else {
    #load "slang_reflect.jai";
    #load "vulkan.jai";
}
