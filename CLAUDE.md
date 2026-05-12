# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Typink is a scientific notebook app combining Typst typesetting with handwriting/diagramming. It uses a **Rust core** embedded in a **Flutter app** via `flutter_rust_bridge` (FRB v2.11.1). The Nix flake manages the entire toolchain (Flutter SDK, Rust, Android NDK).

---

## Build & Run

All commands require the Nix dev environment. Use the `Makefile` at the project root — it handles the full pipeline in a single `nix develop` invocation per target.

```bash
make help          # list all targets

# Linux
make run           # build Rust (debug) + flutter run -d linux
make build-linux   # build Rust (release) + flutter build linux --release

# Android (connected device required for dev-android)
make dev-android   # cross-compile Rust (arm64) + flutter run
make build-apk     # cross-compile Rust (arm64) + flutter build apk

# Bridge
make bridge        # regenerate Flutter↔Rust bridge (run after editing rust/src/api.rs)
```

The bridge regeneration script (`generate_bridge.sh`) deletes stale generated files, runs `flutter_rust_bridge_codegen generate`, then rebuilds Rust. Config is in `flutter_rust_bridge.yaml` (`rust_input: "crate::api"`).

**Packaging for distribution** (bypasses the dev shell, uses the flake's package definition):
```bash
nix build .    # produces ./result/bin/typink + ./result/lib/libtypink_rust.so
nix run .      # build and run immediately
```
This is what end users on NixOS consume. The `make build-linux` path produces a Flutter bundle for non-Nix Linux installs.

---

## Testing

```bash
make test              # run Rust + Flutter unit tests
make test-rust         # Rust unit tests only
make test-flutter      # Flutter unit tests only
make test-integration  # Flutter integration tests (requires device/emulator)

# Run a single Rust test by name
nix develop --command bash -c "cd rust && cargo test test_editor_insert_and_backspace"
```

If you get "file INSTALL cannot find" or directory errors, run `flutter clean` inside the nix shell.

---

## Architecture

### Rust crate (`rust/src/`)

| File | Responsibility |
|------|---------------|
| `api.rs` | All FFI entry points exposed to Flutter. Holds the global `EDITOR: Lazy<Mutex<HeadlessEditor>>` singleton. |
| `editor.rs` | `HeadlessEditor` — Rope-based buffer, undo/redo history, UTF-16↔char index conversion, highlight cache, completions. |
| `vim_engine.rs` | `VimEngine` — full modal editing state machine (Normal/Insert/Visual/VisualLine/VisualBlock/Replace/Search/Command). |
| `typst_engine.rs` | `TypinkWorld` — implements `typst::World` for in-memory compilation. Loads fonts from disk (Linux) or preloaded bytes (Android). |
| `highlighter.rs` | Walks the `typst-syntax` AST and emits `HighlightSpan`s with UTF-16 byte offsets. |
| `frb_generated.rs` | Auto-generated — **do not edit**. |

**Critical invariant**: All text positions crossing the FFI boundary are **UTF-16 indices** (Dart is UTF-16 internally). Conversion to Rope char indices happens in `HeadlessEditor::{utf16_idx_to_char_idx, char_idx_to_utf16_idx}`.

The Typst compile pipeline runs on its own thread with an 8 MB stack to prevent stack overflow from Typst's deep recursion.

### Flutter app (`flutter_app/lib/`)

| Path | Responsibility |
|------|---------------|
| `main.dart` | Entry point. Calls `RustLib.init()`, wraps everything in `ProviderScope`. Routes to `WorkspaceSelectorPage` or `TypstEditorPage` based on workspace state. |
| `frb_generated.dart/` | Auto-generated bridge — **do not edit**. |
| `editor/providers.dart` | Central Riverpod state: `HandwritingNotifier`, `PersistenceManager`, `AppSettings`, `typstCompileResultProvider` (the async compile pipeline). |
| `editor/headless_editor.dart` | `HeadlessEditorView` widget — implements `TextInputClient` for IME; forwards keys to Rust; uses `CustomPainter` for rendering. Split into parts: `editor_ime_handler.dart`, `editor_completion_handler.dart`. |
| `editor/typst_editor.dart` | `TypstEditorPage` — splits editor and Typst preview (PNG pages via `typstCompileResultProvider`). Handles PDF export, file switching, drawing insertion. |
| `editor/workspace_provider.dart` | `WorkspaceNotifier` — open/create/rename/move/delete `.typ` files and their associated figure folders. |
| `editor/drawing_pad.dart` + `handwriting_canvas.dart` | Drawing pad modal and canvas widget over the fixed 1333×1000 coordinate space. |

### State management (Riverpod)

The compile pipeline is reactive:
1. User types → `rawContentProvider` updated → `PersistenceManager` debounces a 3-second autosave
2. `debouncedContentProvider` triggers `typstCompileResultProvider` (FutureProvider)
3. That provider calls `bridge.compileTypst(content, extraFiles)` where `extraFiles` includes in-memory SVGs from `HandwritingNotifier` and scanned disk images
4. Results (PNG pages + diagnostics) flow back to the preview widget

### File format on disk

```
Notebook/
  main.typ          # Typst source
  main/             # Per-file figure directory (same name as .typ, no extension)
    fig1.svg        # SVG for Typst rendering
    fig1.json       # Stroke data for re-editing
  settings.json     # Serialized AppSettings
  snippets.json     # User-defined snippet overrides (optional)
  fonts/            # User-imported fonts (optional)
```

When a `.typ` file is renamed, `WorkspaceNotifier.renameEntity` also renames the associated figure folder and rewrites internal `image("...")` paths inside the file.

### Key design details

- **Atomic saves**: `PersistenceManager.saveTypst` writes to a `.tmp` file then renames it — protects against data loss on crash.
- **Version-gated saves**: Each keystroke increments `contentVersionProvider`; stale async saves are discarded before writing.
- **Font loading**: On Linux, `TypinkWorld` scans hardcoded paths including the project's `flutter_app/assets/fonts`. On Android, fonts are preloaded as bytes via `bridge.handleEditorInitFonts` before first compile.
- **Completion threading**: `get_completions` spawns a named thread with 8 MB stack and catches panics, returning an empty list on failure.
- **`jk` chord**: Typing `j` then `k` rapidly in Insert mode exits to Normal mode (like a vim escape alias).
