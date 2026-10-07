{
  # pkgsOld ? import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-25.11.tar.gz") { config = { allowUnfree = true; android_sdk.accept_license = true; }; },
  pkgs ? import <nixpkgs> { config = { allowUnfree = true; android_sdk.accept_license = true; }; }
}: let
androidComposition = pkgs.androidenv.composeAndroidPackages {
  platformVersions = [ "31" ]; # Android 12
  buildToolsVersions = [ "31.0.0" ];
  includeNDK = true;
  ndkVersion = "latest";
};
androidsdk = androidComposition.androidsdk;
in (with pkgs; buildFHSEnv {
  name = "jai-dev";
  targetPkgs = _:[
    glm
    libglvnd
    libglvnd.dev
    vulkan-headers
    vulkan-loader
    vulkan-validation-layers
    libX11
    libX11.dev
    xorgproto
    shader-slang
    glibc
    # pkgsOld.androidenv.androidPkgs.androidsdk
    # pkgsOld.androidenv.androidPkgs.platform-tools
    androidsdk
  ] ++ [
    jai gcc gf
  ] ++ [
    code-cursor
  ];
  profile = ''
    export LD_LIBRARY_PATH="${lib.makeLibraryPath [ libc libcxx vulkan-loader libglvnd libX11 libXext freetype ]}"
    export VK_LAYER_PATH="${vulkan-validation-layers}/share/vulkan/explicit_layer.d"
    export ANDROID_HOME=${androidsdk}/libexec/android-sdk
    export ANDROID_SDK_ROOT=$ANDROID_HOME

    # resolve whichever NDK version "latest" turned out to be
    export ANDROID_NDK_ROOT="$(ls -d $ANDROID_HOME/ndk/* | sort -V | tail -n1)"
    export ANDROID_NDK_HOME=$ANDROID_NDK_ROOT
    export ANDROID_NDK=$ANDROID_NDK_ROOT
    export NDK_TOOLCHAIN=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64
    export PATH=$NDK_TOOLCHAIN/bin:$PATH
    if [ "$EDITOR" != "cursor" ]; then export EDITOR=cursor; $EDITOR; fi
  '';
}).env
