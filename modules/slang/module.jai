#if OS == .WINDOWS {
    #load "windows.jai";
} else #if OS == .LINUX || OS == .WASM || OS == .ANDROID {
    // WASM/Android reuse Linux Slang declarations so #insert/#run reflection works
    // while cross-compiling (compile-time runs on the host).
    SLANG_FAILED :: (status: s32) -> bool {
        return status < 0;
    }

    SLANG_SUCCEEDED :: (status: s32) -> bool {
        return status >= 0;
    }

    SLANG_GET_RESULT_FACILITY :: (r: s32) -> s32 {
        return (r >> 16) & 0x7fff;
    }

    SLANG_GET_RESULT_CODE :: (r: s32) -> s32 {
        return r & 0xffff;
    }

    SLANG_MAKE_ERROR :: (fac: s32, code: s32) -> s32 {
        return (fac << 16) | code | cast(s32, 0x80000000);
    }

    SLANG_MAKE_SUCCESS :: (fac: s32, code: s32) -> s32 {
        return (fac << 16) | cast(s32, code);
    }

    #load "linux.jai";
} else #if OS == .MACOS {
    #load "macos.jai";
} else {
    #assert false "Unsupported OS for Slang";
}

#if OS == .WINDOWS {
    slang_compiler :: #library,no_dll,link_always "win/slang-compiler";
} else #if OS == .LINUX {
    // Drop no_dll so #run / #insert compile-time reflection can dlopen libslang.so.
    libslang :: #library,link_always "linux/libslang";
} else #if OS == .WASM {
    // Compile-time #run only on the host; omit link_always so .wasm does not link libslang.so.
    libslang :: #library "linux/libslang";
} else #if OS == .ANDROID {
    // Needed so compile-time #insert can call slang on the host.
    // build.jai filters this host .so out of the Android NDK link line.
    libslang :: #library "linux/libslang";
} else #if OS == .MACOS {
    libslang :: #library,link_always "mac/libslang";
}
