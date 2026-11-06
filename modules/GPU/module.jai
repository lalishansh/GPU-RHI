// GPU module — shared facade types + Vulkan host backend.
// Defaults always provided (never null optionals); DbC; reflection-first; static-first.

#import "Basic";
#import "Math";
#import "String";
#import "CrossWindow";

#if OS != .WASM {
    #import "Vulkan";
    #if OS == .LINUX {
        X11 :: #import "X11";
    }
    #if OS != .ANDROID {
        slang :: #import "slang";
    }
}

API :: enum u8 {
    VULKAN;
    WEBGPU;
}

Context_Flags :: enum_flags u32 {
    NONE                       :: 0;
    ENABLE_SURFACE             :: 1;
    ENABLE_DEBUG               :: 2;
    ENABLE_VALIDATION          :: 4;
    ENABLE_COMPUTE             :: 8;
    ENABLE_MESH_SHADERS        :: 16;
    ENABLE_GEOMETRY            :: 32;
    ENABLE_TESSELLATION        :: 64;
    ENABLE_RAY_QUERY           :: 128;
    ENABLE_RAY_TRACING         :: 256;
    ENABLE_DYNAMIC_RENDERING   :: 512;
    ENABLE_MULTIVIEW           :: 1024;
    ENABLE_TIMELINE_SEMAPHORES :: 2048;
}

Feature :: enum u32 {
    SURFACE;
    DEBUG;
    VALIDATION;
    COMPUTE;
    MESH_SHADERS;
    GEOMETRY;
    TESSELLATION;
    RAY_QUERY;
    RAY_TRACING;
    DYNAMIC_RENDERING;
    MULTIVIEW;
    TIMELINE_SEMAPHORES;
}

DataLocality :: enum u8 {
    CREATE_ON_HOST;
    CREATE_ON_DEVICE;
}

TextureFormat :: enum u8 {
    R8G8B8A8_UNORM;
    B8G8R8A8_UNORM;
    R32_SFLOAT;
    D32_SFLOAT;
    D24_UNORM_S8_UINT;
}

TextureUsage :: enum_flags u32 {
    NONE             :: 0;
    SAMPLED          :: 1;
    COLOR_ATTACHMENT :: 2;
    DEPTH_STENCIL    :: 4;
    STORAGE          :: 8;
    COPY_SRC         :: 16;
    COPY_DST         :: 32;
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
    COPY;
}

Size2D :: struct {
    x: u32 = 1;
    y: u32 = 1;
}

Size3D :: struct {
    x: u32 = 1;
    y: u32 = 1;
    z: u32 = 1;
}

SizeCube :: struct {
    face: u32 = 1;
}

Color4 :: struct {
    r: float = 0.0;
    g: float = 0.0;
    b: float = 0.2;
    a: float = 1.0;
}

DEFAULT_CLEAR_COLOR :: Color4.{0.0, 0.0, 0.2, 1.0};

Debug_Callback :: #type (message: string);

default_debug_callback :: (message: string) {
    print("[GPU-RHI DEBUG] %\n", message);
}

DEFAULT_DEBUG_CALLBACK :: default_debug_callback;

IndexU8_t  :: u8;
IndexU16_t :: u16;
IndexU32_t :: u32;

VULKAN_UNIFORM_PUSH_CONSTANT :: cast(u32) 0xFFFF_FFFF;

UniformDefinition :: struct {
    name: string;
    type: Type;
    offset: u32;
    set: u32;
    binding: u32;
    stage_flags: u32;
}

// Alias used by shader member emit / Set(uniform).
VulkanShaderUniformDefinition :: UniformDefinition;

is_push_constant :: (d: UniformDefinition) -> bool {
    return d.set == VULKAN_UNIFORM_PUSH_CONSTANT && d.binding == VULKAN_UNIFORM_PUSH_CONSTANT;
}

feature_to_flag :: (f: Feature) -> Context_Flags {
    if f == {
        case .SURFACE;              return .ENABLE_SURFACE;
        case .DEBUG;                return .ENABLE_DEBUG;
        case .VALIDATION;           return .ENABLE_VALIDATION;
        case .COMPUTE;              return .ENABLE_COMPUTE;
        case .MESH_SHADERS;         return .ENABLE_MESH_SHADERS;
        case .GEOMETRY;             return .ENABLE_GEOMETRY;
        case .TESSELLATION;         return .ENABLE_TESSELLATION;
        case .RAY_QUERY;            return .ENABLE_RAY_QUERY;
        case .RAY_TRACING;          return .ENABLE_RAY_TRACING;
        case .DYNAMIC_RENDERING;    return .ENABLE_DYNAMIC_RENDERING;
        case .MULTIVIEW;            return .ENABLE_MULTIVIEW;
        case .TIMELINE_SEMAPHORES;  return .ENABLE_TIMELINE_SEMAPHORES;
    }
    return .NONE;
}

is_vulkan_only_feature :: (f: Feature) -> bool {
    if f == {
        case .MESH_SHADERS; #through;
        case .GEOMETRY; #through;
        case .TESSELLATION; #through;
        case .RAY_QUERY; #through;
        case .RAY_TRACING; #through;
        case .DYNAMIC_RENDERING; #through;
        case .MULTIVIEW; #through;
        case .TIMELINE_SEMAPHORES;
            return true;
    }
    return false;
}

not_implemented :: (what: string, loc := #caller_location) {
    assert(false, "not implemented: % (at %:%)", what, loc.fully_pathed_filename, loc.line_number);
}

ray_tracing_not_ready :: (feature_name: string, loc := #caller_location) {
    log_error("Ray tracing example '%' is reserved for a later date (at %:%).\n",
        feature_name, loc.fully_pathed_filename, loc.line_number);
    exit(1);
}

#if OS == .WASM {
    #load "webgpu.jai";
} else {
    #load "slang_reflect.jai";
    #load "vulkan.jai";
}
