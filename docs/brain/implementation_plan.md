# Implementation Plan - Phase 2: Headless Editor (Phased)

Transition `Typink` to a headless architecture using a phased approach to manage complexity.

## Proposed Steps

### Step 1: Basic Input & Rendering
- Implement `HeadlessEditorView` with basic key forwarding to Rust.
- Implement `HeadlessEditorPainter` for basic line-by-line text rendering using `TextPainter`.

### Step 2: Vim Mode Cursor Drawing
- Implement modal cursor rendering (Block for Normal/Visual, Line for Insert).
- Ensure cursor positioning is synchronized with Rust's `cursor_column_u16`.

### Step 3: Syntax Highlighting & UI Enhancements
- **Goal**: Render text with colors based on optimized Rust `HighlightSpan`s.
- **Vim UI**: Relative line numbers and whitespace symbols (implemented).
- **Optimization**: Use non-blocking/debounced highlighting in Rust to maintain typing speed.

### Step 4: IME Support (TextInputClient)
- **Goal**: Enable Japanese/Math input and multi-byte support.
- **Architecture**:
  - `HeadlessEditorView` will implement `TextInputClient`.
  - On focus, it opens a `TextInputConnection`.
  - `updateEditingValue` will calculate the diff and send it to Rust via `bridge.handleReplaceRange`.
  - Rust will convert UTF-16 offsets from Flutter to Rope character indices.

### Step 5: Optimized Syntax Highlighting
- **Implementation**:
  - Rust `Editor` maintains `cached_spans`.
  - `get_view` returns text + `cached_spans` (Fast/Sync).
  - `triggerHighlight` (Async) updates `cached_spans` in the background.
  - Flutter calls `triggerHighlight` debounced after typing.

### Step 6: Mouse Interaction & Integration Testing
- **Goal**: Allow users to click on the screen to reposition the Vim cursor, and automate UI testing.
- **Implementation**:
  - `HeadlessEditorPainter` will implement a reverse-mapping function `getGlobalOffsetForPosition(Offset)`.
  - `HeadlessEditorView` uses `GestureDetector.onTapUp` to capture `localPosition`, convert it via the painter logic, and send it to Rust via `bridge.handleEditorUpdateSelection`.
  - Create a Flutter integration test (`integration_test/editor_test.dart`) to test keystrokes and pointer clicks automatically against the real Rust binary.

### Step 7: Selection & Scrolling
- Support drawing visual selections and viewport-based rendering/scrolling.

---

## Proposed Changes (Immediate Focus: Steps 1 & 2)

### Flutter App

#### [NEW] [headless_editor.dart](file:///home/user/Code/rust/Typink/flutter_app/lib/editor/headless_editor.dart)
- `HeadlessEditorView` widget:
  - Listens for raw keyboard events.
  - Fetches `EditorView` from Rust on change.
  - Manages basic layout and the `CustomPaint` widget.

#### [NEW] [headless_editor_painter.dart](file:///home/user/Code/rust/Typink/flutter_app/lib/editor/headless_editor_painter.dart)
- `HeadlessEditorPainter`:
  - Renders text lines using `TextPainter`.
  - Draws the cursor based on `cursor_line` and `cursor_column_u16`.
  - Supports different cursor shapes for Vim modes.

#### [MODIFY] [typst_editor.dart](file:///home/user/Code/rust/Typink/flutter_app/lib/editor/typst_editor.dart)
- Integrate `HeadlessEditorView` as a core component.

## Verification Plan

### Manual Verification
- Verify that basic typing (ASCII) works.
- Verify that Vim movements (`h, j, k, l`) correctly move the cursor.
- Verify that switching modes (`i, Escape`) changes the cursor shape.
