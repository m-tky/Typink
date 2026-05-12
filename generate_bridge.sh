#!/usr/bin/env bash
# Regenerates the Flutter <-> Rust bridge via flutter_rust_bridge_codegen.
# Requires flutter_rust_bridge_codegen in ~/.cargo/bin:
#   cargo install flutter_rust_bridge_codegen --version 2.11.1

export PATH="$PATH:$HOME/.cargo/bin"

CMDS='
  rm -rf rust/src/bridge_generated.rs \
         rust/src/frb_generated.rs \
         flutter_app/lib/bridge_generated.dart \
         flutter_app/lib/frb_generated.dart \
         flutter_app/lib/bridge_definitions.dart

  flutter_rust_bridge_codegen generate

  echo "Bridge generation complete. Building Rust for Linux..."
  cd rust && cargo build
  echo "Done. Run: make run"
'

if [ -n "$IN_NIX_SHELL" ]; then
  bash -c "$CMDS"
else
  nix develop --command bash -c "$CMDS"
fi
