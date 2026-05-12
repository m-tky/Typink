{
  description = "Typink development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    android-nixpkgs = {
      url = "github:tadfisher/android-nixpkgs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-stable, flake-utils, fenix, android-nixpkgs }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };

        pkgs-stable = import nixpkgs-stable {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };

        rustToolchain = fenix.packages.${system}.stable.withComponents [
          "cargo"
          "rustc"
          "rust-src"
          "rust-std"
          "clippy"
          "rustfmt"
        ];
        
        rust = fenix.packages.${system}.combine [
          rustToolchain
          fenix.packages.${system}.targets.aarch64-linux-android.stable.rust-std
          fenix.packages.${system}.targets.x86_64-linux-android.stable.rust-std
        ];

        sdk = android-nixpkgs.sdk.${system} (sdkPkgs: with sdkPkgs; [
          build-tools-33-0-1
          build-tools-34-0-0
          build-tools-35-0-0
          cmdline-tools-latest
          emulator
          platform-tools
          platforms-android-31
          platforms-android-32
          platforms-android-33
          platforms-android-34
          platforms-android-35
          platforms-android-36
          ndk-27-0-12077973
          ndk-28-2-13676358
        ]);

        devShell = pkgs-stable.mkShell {
          buildInputs = [
            pkgs-stable.git
            pkgs-stable.gnumake
            pkgs-stable.pkg-config
            pkgs-stable.cmake
            pkgs-stable.ninja
            pkgs-stable.gcc
            # Use stable flutter (3.24.5) to avoid engine.realm issues in unstable
            pkgs-stable.flutter
            pkgs-stable.steam-run
            pkgs-stable.jdk17
            pkgs-stable.unzip
            pkgs-stable.which
            pkgs-stable.zenity
            rust
            pkgs-stable.cargo-ndk
            pkgs-stable.cacert
            pkgs-stable.glib
            pkgs-stable.gtk3
            pkgs-stable.pango
            pkgs-stable.cairo
            pkgs-stable.gdk-pixbuf
            pkgs-stable.atk
            pkgs-stable.dbus
            pkgs-stable.libxcrypt-legacy
            pkgs-stable.libGL
            pkgs-stable.libuuid
            pkgs-stable.zlib
            pkgs-stable.fontconfig
            pkgs-stable.freetype
            pkgs-stable.libxkbcommon
            pkgs-stable.util-linux # for libmount
            pkgs-stable.libglvnd
            pkgs-stable.at-spi2-core
            pkgs-stable.libdatrie
            pkgs-stable.libepoxy
            pkgs-stable.libthai
            pkgs-stable.pcre
            pkgs-stable.xorg.libXdmcp
            pkgs-stable.xorg.libXtst
            pkgs-stable.xclip
            pkgs-stable.wl-clipboard
            pkgs-stable.openssl
            pkgs-stable.llvmPackages.libclang
          ];

          shellHook = ''
            export ANDROID_HOME=${sdk}/share/android-sdk
            export ANDROID_SDK_ROOT=$ANDROID_HOME
            export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/27.0.12077973
            export JAVA_HOME=${pkgs-stable.jdk17}
            export SSL_CERT_FILE=${pkgs-stable.cacert}/etc/ssl/certs/ca-bundle.crt
            export PATH=$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/emulator:$PATH
            export LD_LIBRARY_PATH=${pkgs-stable.lib.makeLibraryPath (with pkgs-stable; [ stdenv.cc.cc.lib libGL libuuid zlib glib gtk3 pango cairo gdk-pixbuf atk dbus libxcrypt-legacy fontconfig util-linux libglvnd mesa ])}:''${LD_LIBRARY_PATH:-}
            export LIBGL_DRIVERS_PATH=${pkgs-stable.mesa.drivers}/lib/dri
            export __GLX_VENDOR_LIBRARY_NAME=mesa
            export LIBCLANG_PATH="${pkgs-stable.llvmPackages.libclang.lib}/lib"
            
            echo "=== Typink Development Environment (Flake - Stable Flutter) ==="
            echo "Android SDK: $ANDROID_HOME"
          '';
        };

        typink-rust = pkgs.rustPlatform.buildRustPackage {
          pname = "typink_rust";
          version = "0.1.0";
          src = ./rust;
          cargoLock = {
            lockFile = ./rust/Cargo.lock;
          };
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.fontconfig pkgs.freetype ];
          doCheck = false;
        };

        typink = pkgs-stable.flutter.buildFlutterApplication {
          pname = "typink";
          version = "1.0.0";
          src = ./flutter_app;
          pubspecLock = pkgs.lib.importJSON ./flutter_app/pubspec.lock.json;
          
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [
            pkgs-stable.gtk3
            pkgs-stable.pango
            pkgs-stable.cairo
            pkgs-stable.gdk-pixbuf
            pkgs-stable.atk
            pkgs-stable.dbus
            pkgs-stable.libGL
            pkgs-stable.libuuid
            pkgs-stable.zlib
            pkgs-stable.fontconfig
            pkgs-stable.freetype
            pkgs-stable.libxkbcommon
            pkgs-stable.util-linux
            pkgs-stable.libglvnd
          ];
          
          postInstall = ''
            mkdir -p $out/lib
            # Ensure the Rust library is bundled correctly
            # On Linux, Flutter expects libraries in the same directory as the executable or in a 'lib' subdirectory
            # CMakeLists.txt sets RPATH to $ORIGIN/lib
            cp ${typink-rust}/lib/libtypink_rust.so $out/lib/
          '';
        };
      in
      {
        devShells.default = devShell;
        packages = {
          default = typink;
          typink = typink;
          typink-rust = typink-rust;
        };
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/typink";
        };
      }
    );
}
