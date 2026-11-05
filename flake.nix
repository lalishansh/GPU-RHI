{
  description = "Jai Language FHS Environment for Host, Android & Web";
  # nix develop # To create a new environment
  # nix develop --profile .nix-env # To create a new environment with a profile (new profiles on every run)
  # nix develop ./.nix-env # To enter/use the current/created profile
  # nix profile wipe-history --profile ./.nix-env && nix-collect-garbage # To wipe the old profiles and garbage collection on old profiles
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-newest.url = "github:nixos/nixpkgs/nixos-unstable-small";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, nixpkgs-newest, flake-utils }: flake-utils.lib.eachDefaultSystem (system: {
    devShells.default = let
      pkgs = import nixpkgs { inherit system; config = { allowUnfree = true; android_sdk.accept_license = true; }; };
      pkgs-newest = import nixpkgs-newest { inherit system; config.allowUnfree = true; };
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
        androidsdk
      ] ++ [
        jai gcc gdb gf
      ] ++ [
        pkgs-newest.code-cursor
      ] ++ [
        # to build __imgui-cpp-lib/examples/example_glfw_wgpu
        cmake ninja emscripten
      ];
      profile = ''
        export JAI_LD_LIBRARY_PATH="${lib.makeLibraryPath [ libc libcxx vulkan-loader libglvnd libX11 libXext freetype ]}"
        export VK_LAYER_PATH="${vulkan-validation-layers}/share/vulkan/explicit_layer.d"
        export ANDROID_HOME=${androidsdk}/libexec/android-sdk
        export ANDROID_SDK_ROOT=$ANDROID_HOME

        # resolve whichever NDK version "latest" turned out to be
        export ANDROID_NDK_ROOT="$(ls -d $ANDROID_HOME/ndk/* | sort -V | tail -n1)"
        export ANDROID_NDK_HOME=$ANDROID_NDK_ROOT
        export ANDROID_NDK=$ANDROID_NDK_ROOT
        export NDK_TOOLCHAIN=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64
        export PATH=$NDK_TOOLCHAIN/bin:$PATH
      '';
      runScript = "${lib.getExe pkgs-newest.code-cursor} .";
    }).env;
  });
}
