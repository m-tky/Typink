{
  pkgs ? import <nixpkgs> {
    config = {
      allowUnfree = true;
      android_sdk.accept_license = true;
    };
  },
}:

let
  fenix = import (fetchTarball "https://github.com/nix-community/fenix/archive/main.tar.gz") { };
  rustToolchain = fenix.combine [
    fenix.stable.cargo
    fenix.stable.rustc
    fenix.stable.rust-src
    fenix.targets.aarch64-linux-android.stable.rust-std
    fenix.targets.x86_64-linux-android.stable.rust-std
  ];

  androidComposition = pkgs.androidenv.composeAndroidPackages {
    platformVersions = [
      "29"
      "31"
      "33"
      "34"
      "35"
      "36"
    ];
    buildToolsVersions = [
      "33.0.1"
      "34.0.0"
      "35.0.0"
    ];
    includeEmulator = false;
    includeSources = false;
    includeSystemImages = false;
    includeNDK = true;
    ndkVersions = [
      "27.0.12077973"
      "28.2.13676358"
    ];
    cmakeVersions = [ "3.22.1" ];
  };
in
pkgs.mkShell {
  buildInputs = with pkgs; [
    rustToolchain
    cargo-ndk
    flutter
    zenity
    jdk17
    androidComposition.androidsdk

    # Linux Desktop Dependencies
    pkg-config
    gtk3
    cmake
    ninja
    at-spi2-core
    libdatrie
    libepoxy
    libthai
    libxkbcommon
    pcre
    xorg.libXdmcp
    xorg.libXtst
    xclip
    wl-clipboard
  ];

  shellHook = ''
    echo "=== Typink Android Build Shell ==="
    echo "Run './build_android.sh' from the rust/ directory to compile libraries."
    export JAVA_HOME=${pkgs.jdk17}
    export ANDROID_HOME=${androidComposition.androidsdk}/libexec/android-sdk
    export ANDROID_SDK_ROOT=$ANDROID_HOME
    export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/27.0.12077973
    export NIXPKGS_ACCEPT_ANDROID_SDK_LICENSE=1
    export PATH="$PATH:$ANDROID_HOME/tools:$ANDROID_HOME/platform-tools:$ANDROID_NDK_HOME"
  '';
}
