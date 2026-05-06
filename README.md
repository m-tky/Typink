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

Typink uses a hybrid architecture with a Rust core. **Nix** is required to manage the toolchain (Flutter SDK, Rust, Android NDK).

### 1. Environment Setup

Always enter the Nix shell from the project root before building or running:
```bash
nix-shell shell.nix
```

### 2. Linux Development

#### Build Rust Core
```bash
nix-shell shell.nix --run "cd rust && cargo build"
```

#### Run Application
```bash
# Note: LD_LIBRARY_PATH is required for the Linux app to find the Rust library
nix-shell shell.nix --run "cd flutter_app && export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:$(pwd)/../rust/target/debug; flutter run -d linux"
```

### 3. Android Development

#### Build Rust Core (Cross-Compile)
This script handles the cross-compilation for `arm64-v8a` and bundles the `.so` files into the Flutter project.
```bash
nix-shell shell.nix --run "cd rust && ./build_android.sh"
```

#### Run Application
```bash
nix-shell shell.nix --run "cd flutter_app && flutter run"
```

#### Build APK
```bash
nix-shell shell.nix --run "cd flutter_app && flutter build apk"
```
The optimized APK will be located at:
`flutter_app/build/app/outputs/flutter-apk/app-release.apk`

---

> [!TIP]
> If you encounter "file INSTALL cannot find" or other directory errors, run `flutter clean` in the `flutter_app` directory inside the nix-shell.

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
