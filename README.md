# Typink

**Typink** is a professional-grade scientific notebook application that seamlessly integrates **Typst**'s powerful typesetting with stable **handwriting** and diagramming capabilities.

## Key Features

- **Stable Diagramming (Option C)**: A dedicated Drawing Pad with a fixed 1333x1000 coordinate system, ensuring your diagrams never distort or drift.
- **Translucent UI**: Draw directly over your Typst preview with a translucent canvas for perfect alignment.
- **Professional Persistence**: Automatic saving of strokes as JSON (for editing) and SVG (for display). Robust data protection with AppLifecycle-aware flushing.
- **Multi-File Management**: A built-in sidebar to manage multiple `.typ` files within a single synced project.
- **Scientific PDF Export**: One-click professional PDF generation with timestamped filenames.

## Architecture

Typink uses a hybrid architecture:
- **Frontend**: Flutter (Riverpod for state, `re_editor` for Typst editing).
- **Engine**: Rust (Typst engine integration via `flutter_rust_bridge`).

### File Structure
```
Notebook/
  main.typ       # Main Typst document
  figures/       # Auto-managed directory
    fig1.svg     # Image for Typst rendering
    fig1.json    # Stroke data for re-editing
```

## Build Instructions

### Prerequisites
- **Nix** (Recommended for Linux/NixOS users)
- **Flutter SDK**
- **Rust Toolchain**
- **Podman** (For Android builds)

### 1. Code Generation
To regenerate the Rust-Dart bridge, use the following official command (requires `nix-shell` and local `flutter_rust_bridge_codegen`):

```bash
nix-shell -p cargo cargo-expand flutter rustfmt libclang.lib --run "export LLVM_ROOT=\$(nix-build '<nixpkgs>' -A libclang.lib --no-out-link); export LIBCLANG_PATH=\$LLVM_ROOT/lib; ~/.cargo/bin/flutter_rust_bridge_codegen --rust-input rust/src/api.rs --dart-output flutter_app/lib/bridge_generated.dart --dart-decl-output flutter_app/lib/bridge_definitions.dart --rust-output rust/src/bridge_generated.rs --rust-crate-dir rust --dart-root flutter_app --llvm-path \$LLVM_ROOT"
```

### 2. Run Locally (Linux)
```bash
cd flutter_app
nix-shell -p flutter --run "export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:$(pwd)/../rust/target/debug; flutter run -d linux"
```

### 3. Build for Android
Use the provided build container scripts:
```bash
./build-container/scripts/build_android.sh
```

## User Guide

### Dynamic Handwriting
1. Click the **"Insert Drawing"** icon in the toolbar.
2. The **Drawing Pad** modal opens. Sketch your diagram.
3. Click **"Save & Close"**.
4. Typink automatically calculates the content density and suggests a width (40% / 70% / 100%) for the `#figure` tag in Typst.

### PDF Export
Click the **PDF icon** in the top right.
- **Linux**: Saved to `~/Documents/Typink/`
- **Android**: Saved to your `Downloads` directory.

### Syncthing Integration
Typink is designed to work with Syncthing. Files are saved in a clean `.typ` + `figures/` directory structure, making conflict resolution and cross-device sync straightforward.
