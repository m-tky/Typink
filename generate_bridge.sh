#!/usr/bin/env zsh
# Typink Bridge Generation Script (Nix-based)
# This script regenerates the Flutter <-> Rust bridge using flutter_rust_bridge_codegen.

# 1. Ensure bridge tools are installed in your ~/.cargo/bin
# If not installed, run:
# nix-shell -p cargo --run "cargo install flutter_rust_bridge_codegen --version 1.82.6 && cargo install cargo-expand"

export PATH="$PATH:$HOME/.cargo/bin"

# 2. Run codegen inside nix-shell with all required dependencies
nix-shell -p cargo rustfmt flutter llvmPackages.libclang.lib openssl pkg-config gcc --run "
  # Find libclang.so dynamically to satisfy ffigen
  LLVM_LIB_PATH=\$(dirname \$(find /nix/store -maxdepth 4 -name libclang.so | head -n 1) | sed 's/\/lib\$//')
  
  # Purge stale bridge files to ensure complete re-generation
  rm -rf rust/src/bridge_generated.rs rust/src/frb_generated.rs flutter_app/lib/bridge_generated.dart flutter_app/lib/frb_generated.dart flutter_app/lib/bridge_definitions.dart

  flutter_rust_bridge_codegen generate

  echo \"Bridge generation complete!\"
  echo \"Starting Rust build for Linux (host)...\"
  cd rust && cargo build
  
  echo \"\nSuccess! To run on Linux, use:\"
  echo \"cd flutter_app && flutter run -d linux\"
"
