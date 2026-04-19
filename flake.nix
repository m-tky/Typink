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

        devShell = pkgs.mkShell {
          buildInputs = with pkgs; [
            git
            pkg-config
            cmake
            ninja
            gcc
            # Use stable flutter (3.24.5) to avoid engine.realm issues in unstable
            pkgs-stable.flutter
            steam-run
            jdk17
            unzip
            which
            zenity
            rust
            cargo-ndk
            cacert
            glib
            gtk3
            pango
            cairo
            gdk-pixbuf
            atk
            dbus
            libxcrypt-legacy
            libGL
            libuuid
            zlib
          ];

          shellHook = ''
            export ANDROID_HOME=${sdk}/share/android-sdk
            export ANDROID_SDK_ROOT=$ANDROID_HOME
            export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/27.0.12077973
            export JAVA_HOME=${pkgs.jdk17}
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export PATH=$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/emulator:$PATH
            export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath (with pkgs; [ stdenv.cc.cc.lib libGL libuuid zlib glib gtk3 pango cairo gdk-pixbuf atk dbus libxcrypt-legacy ])}:''${LD_LIBRARY_PATH:-}
            
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
            pkgs.gtk3
            pkgs.pango
            pkgs.cairo
            pkgs.gdk-pixbuf
            pkgs.atk
            pkgs.dbus
            pkgs.libGL
            pkgs.libuuid
            pkgs.zlib
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
