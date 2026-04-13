# Bridge Generation Fix

- [x] Investigate cause of bridge generation failure
  - [x] Read `rust/src/lib.rs`
  - [x] Read `flutter_rust_bridge.yaml`
  - [x] Read `generate_bridge.sh`
- [x] Fix `rust/src/lib.rs` and `flutter_rust_bridge.yaml`
- [x] Successfully run `./generate_bridge.sh`
- [x] Verify build

# Phase 2: Headless Editor (Phased)
- [x] Step 1 & 2: Basic Input & Modal Cursor Drawing
  - [x] Implement `HeadlessEditorPainter`
  - [x] Implement `HeadlessEditorView`
  - [x] Basic Key Forwarding
  - [x] Optimize Performance (Sync FFI + Disable Highlighting)
- [/] Step 3: Syntax Highlighting & UI Enhancements
  - [x] Basic Line Numbers
  - [x] Relative Line Numbers
  - [x] Newline/Wrap Symbols (Listchars)
  - [x] Optimized Highlight Architecture (Non-blocking)
  - [x] Apply highlighting in `HeadlessEditorPainter`
  - [x] Sync theme colors with Rust spans
- [x] Step 4: IME Support
  - [x] Implement `TextInputClient` in `HeadlessEditorView`
  - [x] Bridge `replaceRange` (Sync for buffer, Async for high-level tasks)
  - [x] Test Japanese/Math input
  - [x] Add automated Rust unit tests for IME and Vim logic (Verified navigation, edit, dd, yy, p)
- [/] Step 5: Mouse Interaction & Integration Testing
  - [x] Implement `GestureDetector.onTapUp` to map `localPosition` to `cursorGlobalU16`
  - [x] Support clicking past End-Of-Line (snap to EOL)
  - [/] Write Flutter Integration Tests (`integration_test`) to automate UI interaction
- [ ] Step 6: Selection & Scrolling
