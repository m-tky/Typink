#!/usr/bin/env bash
set -e

# Configuration
PROJECT_NAME="typink_rust"
FLUTTER_ANDROID_DIR="../flutter_app/android/app/src/main/jniLibs"

# Build for each target
targets=("aarch64-linux-android")
abis=("arm64-v8a")

for i in "${!targets[@]}"; do
    target="${targets[$i]}"
    abi="${abis[$i]}"
    
    echo "Building for $target ($abi)..."
    
    # Check if target is already installed
    if rustc --print target-list | grep -q "^$target$"; then
        echo "Target $target is already available."
    elif command -v rustup >/dev/null 2>&1; then
        echo "Updating target via rustup..."
        if ! rustup target add $target; then
            echo "Warning: rustup failed to add target. Attempting to continue..."
        fi
    else
        echo "Note: Target $target management skipped (assuming managed by environment like Nix)."
    fi
    
    # Ensure NDK is available for cargo-ndk
    if [ -z "$ANDROID_NDK_HOME" ]; then
        echo "Error: ANDROID_NDK_HOME is not set."
        echo "Please ensure you are running this inside the provided nix-shell."
        exit 1
    fi

    # Build using cargo-ndk
    if ! command -v cargo-ndk >/dev/null 2>&1; then
        echo "Error: cargo-ndk not found."
        echo "On NixOS, please run this script inside 'nix-shell' using the provided shell.nix."
        echo "Example: nix-shell ../shell.nix --run './build_android.sh'"
        exit 1
    fi
    
    cargo ndk -t $target -o $FLUTTER_ANDROID_DIR build --release
    
    # Verification Steps
    LIB_PATH="$FLUTTER_ANDROID_DIR/$abi/lib$PROJECT_NAME.so"
    echo "Verifying $LIB_PATH..."
    
    # 1. ABI Check
    readelf -h "$LIB_PATH" | grep -E "Machine|Class"
    
    # 2. Dependency Check (NEEDED)
    echo "Checking dependencies..."
    readelf -d "$LIB_PATH" | grep NEEDED
    
    # 3. Symbol Check (Exported JNI/FRB symbols)
    echo "Verifying exported symbols..."
    # Check for init_app (our init) and some frb generated symbols
    nm -D "$LIB_PATH" | grep -E "init_app" || echo "Warning: init_app not found!"
done

echo "Android build complete!"
