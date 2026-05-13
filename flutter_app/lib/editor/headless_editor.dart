library headless_editor;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pasteboard/pasteboard.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../frb_generated.dart/api.dart' as bridge;
import '../frb_generated.dart/editor.dart';
import '../frb_generated.dart/vim_engine.dart';
import 'headless_editor_painter.dart';
import 'vim_provider.dart';
import 'providers.dart';
import '../frb_generated.dart/typst_engine.dart' as typst;
import 'editor_theme_mixin.dart';
import 'theme_provider.dart';

part 'editor_ime_handler.dart';
part 'editor_completion_handler.dart';

class HeadlessEditorView extends ConsumerStatefulWidget {
  final FocusNode focusNode;
  final TextStyle textStyle;
  final Color cursorColor;
  final String initialContent;
  final String? currentPath;
  final ValueChanged<String>? onChanged;

  const HeadlessEditorView({
    super.key,
    required this.focusNode,
    required this.textStyle,
    required this.cursorColor,
    required this.initialContent,
    this.currentPath,
    this.onChanged,
  });

  @override
  ConsumerState<HeadlessEditorView> createState() => HeadlessEditorViewState();
}

abstract class EditorStateBase extends ConsumerState<HeadlessEditorView>
    with EditorThemeMixin {
  bool _isLoading = true;
  TextInputConnection? _connection;
  bool _ignoreNextImeUpdate = false;
  DateTime? _lastModeChangeTime;
  String? _lastNotifiedContent;
  int _baseLineIndex = 0;
  double _currentVerticalOffset = 0;
  Timer? _highlightTimer;
  Timer? _completionTimer;
  List<bridge.TypstCompletion> _completions = [];
  EditorView? _view;
  TextRange _composing = TextRange.empty;
  final ScrollController _scrollController = ScrollController();
  final LayerLink _cursorLayerLink = LayerLink();
  final Map<String, String> _docCache = {};
  int _completionIndex = -1;
  double _viewportHeight = 0;
  double _viewportWidth = 0;
  double _lastHeight = 0;
  bool _ctrlPressed = false;
  bool _shiftPressed = false;
  final ScrollController _completionScrollController = ScrollController();
  Timer? _debounceTimer;
  String? _currentPath;

  // States for jk chord
  DateTime? _lastJTime;

  // Snippet state
  List<SnippetPlaceholder> _snippetPlaceholders = [];
  int _activeSnippetIndex = -1;
  int? _snippetBaseOffset;

  void _refreshView({bool syncIme = true, bool debounced = false});
  void _triggerHighlight();
  void _triggerCompletion();
  bool tryAutoExpandSnippetSync();
  Future<void> expandSnippetAsync(Snippet match);

  Rect _lastCaretRect = Rect.zero;

  @override
  TextStyle get editorTextStyle => widget.textStyle;
  @override
  double get editorFontSize => widget.textStyle.fontSize ?? 14.0;
  @override
  double get editorLineHeight => widget.textStyle.height ?? 1.4;

  @override
  SyntaxTheme get activeSyntaxTheme =>
      ref.read(activeThemeDetailedProvider).syntaxTheme;

  void _notifyChanged() {
    if (widget.onChanged == null) return;
    final content = bridge.getEditorContent();
    if (content != _lastNotifiedContent) {
      _lastNotifiedContent = content;
      widget.onChanged!(content);
    }
  }

  Rect _computeCaretRect() {
    if (_view == null || !mounted) return _lastCaretRect;

    final double charHeight =
        widget.textStyle.fontSize! * (widget.textStyle.height ?? 1.4);
    const double leftMargin = 40.0;
    const double rightPadding = 8.0;

    final cursorLineIdx = _view!.cursorLine.toInt();
    int localLineIdx = cursorLineIdx - _baseLineIndex;

    // If not in current view, we try to use last known or return lastKnown
    if (localLineIdx < 0 || localLineIdx >= _view!.lines.length)
      return _lastCaretRect;

    final line = _view!.lines[localLineIdx];
    final textPainter = TextPainter(
      text: buildTextSpan(line),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout(
        maxWidth:
            (_viewportWidth - leftMargin - rightPadding).clamp(0.0, 10000.0));

    final int charIdx = _view!.cursorColumnU16.toInt();
    final int textLength = textPainter.text?.toPlainText().length ?? 0;
    final bool isAtLineEnd = charIdx >= textLength;
    final int lookupIdx =
        isAtLineEnd ? (textLength - 1).clamp(0, textLength) : charIdx;

    double cursorX = 0;
    double cursorY = 0;
    double cursorHeight = charHeight;

    if (textLength > 0) {
      final boxes = textPainter.getBoxesForSelection(
        TextSelection(
            baseOffset: lookupIdx,
            extentOffset: (lookupIdx + 1).clamp(0, textLength)),
      );
      if (boxes.isNotEmpty) {
        final box = boxes.first;
        cursorX = isAtLineEnd ? box.right : box.left;
        cursorY = box.top;
        cursorHeight = box.bottom - box.top;
      }
    }

    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return _lastCaretRect;

    final double localY = (cursorLineIdx - _baseLineIndex) * charHeight +
        _currentVerticalOffset +
        cursorY;
    final offset =
        renderBox.localToGlobal(Offset(leftMargin + cursorX, localY));

    _lastCaretRect = Rect.fromLTWH(offset.dx, offset.dy, 2, cursorHeight);
    return _lastCaretRect;
  }

  int _calculateSnippetBaseOffset() {
    return _snippetBaseOffset ?? _view?.cursorGlobalU16.toInt() ?? 0;
  }
}

class HeadlessEditorViewState extends EditorStateBase
    with EditorThemeMixin, EditorImeHandler, EditorCompletionHandler {
  int _contentVersion = 0;
  final Completer<void> _initCompleter = Completer<void>();

  void load(String path) async {
    _contentVersion++;
    final v = _contentVersion;

    final extension = p.extension(path).toLowerCase();
    if (extension != '.typ' && extension != '.typst') {
      debugPrint('Ignoring non-typ file load request: $path');
      return;
    }

    try {
      debugPrint('[LOAD] Starting load for $path (v$v)');
      // Ensure initialization is complete before loading
      await _initCompleter.future;
      if (v != _contentVersion) {
        debugPrint('[LOAD] ABORTED (v$v): superseded by newer version');
        return;
      }

      final content = await bridge.handleEditorLoad(path: path);
      if (v != _contentVersion) {
        debugPrint(
            '[LOAD] ABORTED (v$v) after Rust load: superseded by newer version');
        return;
      }

      _currentPath = path;
      debugPrint('[LOAD] Content from Rust (v$v) length: ${content.length}');

      // Increment content generation version to invalidate all current debounce timers
      ref.read(contentVersionProvider.notifier).update((v) => v + 1);

      ref.read(rawContentProvider.notifier).state = content;
      ref.read(debouncedContentProvider.notifier).state = content;
      ref.read(persistenceProvider).updateLastSavedContent(content, path: path);

      _refreshView();
      _triggerHighlight();
    } catch (e) {
      debugPrint('[LOAD] FAILED (v$v): $e');
    }
  }

  Future<void> insertText(String text,
      {bool insertAfterCurrentLine = false}) async {
    if (_view == null) return;

    BigInt insertionPoint = _view!.cursorGlobalU16;

    if (insertAfterCurrentLine) {
      final fullContent = bridge.getEditorContent();
      final cursorIdx = insertionPoint.toInt();

      // カーソル位置以降で最初の改行（\n）を探す
      int nextNewline = fullContent.indexOf('\n', cursorIdx);
      if (nextNewline != -1) {
        // 改行が見つかったら、その直後を挿入ポイントにする
        insertionPoint = BigInt.from(nextNewline + 1);
      } else {
        // 改行がない（最終行）場合は、ファイルの末尾にする
        insertionPoint = BigInt.from(fullContent.length);
        // 最終行に改行がない場合は、挿入するテキストの前に改行が必要
        if (!fullContent.endsWith('\n')) {
          text = '\n' + text;
        }
      }
    }

    try {
      bridge.handleEditorReplaceRange(
        startU16: insertionPoint,
        endU16: insertionPoint,
        text: text,
        cursorU16: insertionPoint + BigInt.from(text.length),
      );
      _refreshView();
      _triggerHighlight();

      _notifyChanged();
    } catch (e) {
      debugPrint('Failed to insert text: $e');
    }
  }

  Future<void> save() async {
    final path = _currentPath;
    if (path == null) return;
    try {
      await bridge.handleEditorSave(path: path);
      if (widget.onChanged != null) {
        widget.onChanged!(bridge.getEditorContent());
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File saved successfully')),
      );
    } catch (e) {
      debugPrint('Failed to save file: $e');
    }
  }

  Future<void> exportPdf(String path) async {
    try {
      await bridge.handleEditorExportPdf(path: path);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('PDF exported to $path')),
      );
    } catch (e) {
      debugPrint('Failed to export PDF: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Export failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _initContent();
    widget.focusNode.addListener(_handleFocusChange);
    _scrollController.addListener(_handleScroll);
  }

  void _handleScroll() {
    _refreshView(syncIme: false);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_handleFocusChange);
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _completionScrollController.dispose();
    _closeInputConnectionIfNeeded();
    _highlightTimer?.cancel();
    super.dispose();
  }

  void _handleFocusChange() {
    if (widget.focusNode.hasFocus) {
      _updateConnectionState();
    } else {
      // Don't close connection if we are in Insert mode,
      // as it might clear OS-level IME state like Japanese input mode or composition.
      if (_view?.mode != VimMode.insert) {
        _closeInputConnectionIfNeeded();
      }
    }
  }

  void _closeInputConnectionIfNeeded() {
    _connection?.close();
    _connection = null;
  }

  void _handleVimSignal(String signal) {
    switch (signal) {
      case 'save':
      case 'save_and_quit':
        save();
        if (signal == 'save_and_quit') {
          // In a real app, we'd close the editor here.
          debugPrint('Quit signal received after save');
        }
        break;
      case 'quit':
        debugPrint('Quit signal received');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Quit command received (Close editor)')),
        );
        break;
      case 'compile':
        // Force immediate compilation by triggering onChanged
        if (widget.onChanged != null) {
          widget.onChanged!(bridge.getEditorContent());
        }
        break;
      case 'scroll_center':
        _scrollCenter();
        break;
    }
  }

  void _scrollCenter() {
    if (_view == null || !_scrollController.hasClients) return;
    final double charHeight =
        widget.textStyle.fontSize! * (widget.textStyle.height ?? 1.4);
    final cursorY = _view!.cursorLine.toDouble() * charHeight;
    final targetOffset = (cursorY - (_viewportHeight / 2) + (charHeight / 2))
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(targetOffset,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  @override
  void _triggerHighlight() {
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 300), () {
      try {
        bridge.handleEditorTriggerHighlight();
        _refreshView(syncIme: false);
      } catch (e) {
        debugPrint('Failed to trigger highlighting: $e');
      }
    });
  }

  @override
  void performAction(TextInputAction action) {
    // We let updateEditingValue handle the newline insertion as text.
    // Explicitly forwarding 'Enter' here causes double-input on many platforms.
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutofillHints() {}
  @override
  void insertTextPlaceholder(Size size) {}
  @override
  void removeTextPlaceholder() {}
  @override
  void showToolbar() {}
  @override
  void hideToolbar() {}
  @override
  AutofillScope? get autofillScope => null;
  @override
  AutofillScope? get currentAutofillScope => null;
  @override
  TextEditingValue? get currentTextEditingValue => null;
  @override
  void didChangeInputControl(
      TextInputControl? oldControl, TextInputControl? newControl) {}
  @override
  void insertContent(KeyboardInsertedContent content) {}
  @override
  void connectionClosed() {}
  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  Future<void> _initContent() async {
    final v = _contentVersion;
    debugPrint('[INIT] Starting _initContent (v$v)');
    try {
      _currentPath =
          widget.currentPath ?? ref.read(currentTypFileProvider)?.path;

      // Android / Platform initialization
      bridge.handleEditorInitJniSafety();

      // Load bundled fonts for Typst (critical for Android)
      final List<typst.FontFileData> fontData = [];
      final fontAssets = [
        'assets/fonts/Moralerspace.ttf',
        'assets/fonts/IBMPlexSans-Regular.otf',
        'assets/fonts/IBMPlexSansJP-Regular.otf',
        'assets/fonts/NewComputerModernMath.otf',
        'assets/fonts/HaranoAjiGothic-Bold.otf',
        'assets/fonts/HaranoAjiGothic-ExtraLight.otf',
        'assets/fonts/HaranoAjiGothic-Heavy.otf',
        'assets/fonts/HaranoAjiGothic-Light.otf',
        'assets/fonts/HaranoAjiGothic-Medium.otf',
        'assets/fonts/HaranoAjiGothic-Normal.otf',
        'assets/fonts/HaranoAjiGothic-Regular.otf',
        'assets/fonts/HaranoAjiMincho-Bold.otf',
        'assets/fonts/HaranoAjiMincho-ExtraLight.otf',
        'assets/fonts/HaranoAjiMincho-Heavy.otf',
        'assets/fonts/HaranoAjiMincho-Light.otf',
        'assets/fonts/HaranoAjiMincho-Medium.otf',
        'assets/fonts/HaranoAjiMincho-Regular.otf',
        'assets/fonts/HaranoAjiMincho-SemiBold.otf',
      ];

      for (final asset in fontAssets) {
        try {
          final bytes = await rootBundle.load(asset);
          fontData.add(typst.FontFileData(
            path: asset,
            bytes: bytes.buffer.asUint8List(),
          ));
        } catch (e) {
          debugPrint('[INIT] Failed font asset $asset: $e');
        }
      }

      if (fontData.isNotEmpty) {
        bridge.handleEditorInitFonts(fonts: fontData);
      }

      // Check if this initialization has been superseded by a load() call
      if (v != _contentVersion) {
        debugPrint('[INIT] ABORTED (v$v): superseded by load');
        if (!_initCompleter.isCompleted) _initCompleter.complete();
        return;
      }

      debugPrint(
          '[INIT] Setting initial content (v$v) length: ${widget.initialContent.length}');
      bridge.setEditorContent(content: widget.initialContent);
      bridge.handleEditorTriggerHighlight();

      // Initial Vim mode check
      final settings = ref.read(settingsProvider);
      if (!settings.vimEnabled) {
        bridge.handleEditorKey(key: 'i');
      }

      _refreshView();
    } catch (e) {
      debugPrint('[INIT] FAILED (v$v): $e');
    } finally {
      if (!_initCompleter.isCompleted) {
        debugPrint('[INIT] Completing _initCompleter (v$v)');
        _initCompleter.complete();
      }
    }
  }

  @override
  void _refreshView({bool syncIme = true, bool debounced = false}) {
    if (debounced) {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 100),
          () => _refreshView(syncIme: syncIme));
      return;
    }
    try {
      final double charHeight =
          widget.textStyle.fontSize! * (widget.textStyle.height ?? 1.4);
      final double scrollOffset =
          _scrollController.hasClients ? _scrollController.offset : 0.0;

      final double preciseStartLine =
          (scrollOffset / charHeight).clamp(0.0, 1000000.0);
      final int baseLineIndex = preciseStartLine.floor();
      final double verticalOffset =
          -(preciseStartLine - baseLineIndex) * charHeight;

      final int visibleLines =
          (_viewportHeight > 0 ? (_viewportHeight / charHeight).ceil() : 50) +
              5;

      final view = bridge.getEditorView(
          startLine: BigInt.from(baseLineIndex),
          endLine: BigInt.from(baseLineIndex + visibleLines));

      if (mounted) {
        if (view.yankText != null) {
          Clipboard.setData(ClipboardData(text: view.yankText!));
        }

        setState(() {
          _view = view;
          _isLoading = false;
          _baseLineIndex = baseLineIndex;
          _currentVerticalOffset = verticalOffset;
        });

        ref.read(cursorPositionProvider.notifier).state = (
          _view!.cursorLine.toInt() + 1,
          _view!.cursorColumnU16.toInt() + 1,
        );

        if (syncIme) {
          _updateConnectionState();
        }

        // Auto-scroll to cursor if it moved out of viewport
        _scrollToCursorIfNeeded();

        // Sync Vim mode for the status bar
        ref.read(vimModeProvider.notifier).state = view.mode;

        // Handle signals from Vim (save, quit, etc.)
        if (view.signal != null) {
          _handleVimSignal(view.signal!);
        }
      }
    } catch (e) {
      debugPrint('Failed to fetch editor view: $e');
    }
  }

  void _ensureInsertModeIfVimDisabled() {
    final settings = ref.read(settingsProvider);
    if (!settings.vimEnabled && _view?.mode != VimMode.insert) {
      _processKey('i');
    }
  }

  void _scrollToCursorIfNeeded() {
    if (_view == null || !_scrollController.hasClients) return;

    final double charHeight =
        widget.textStyle.fontSize! * (widget.textStyle.height ?? 1.4);
    final cursorY = _view!.cursorLine.toDouble() * charHeight;
    final scrollOffset = _scrollController.offset;

    if (cursorY < scrollOffset) {
      _scrollController.jumpTo(cursorY);
    } else if (cursorY + charHeight > scrollOffset + _viewportHeight) {
      _scrollController.jumpTo(cursorY + charHeight - _viewportHeight);
    }
  }

  void sendEsc() {
    _processKey('Escape');
  }

  Rect getGlobalCursorRect() {
    return _computeCaretRect();
  }

  void _handleKey(KeyEvent event) {
    if (event is KeyUpEvent) return;

    final key = _mapKeyEvent(event);
    debugPrint(
        'Key pressed: ${event.logicalKey.debugName}, Character: ${event.character}, Mapped: $key');

    if (key == null) return;

    // Detect 'jk' chord
    if (key == 'k' && _lastJTime != null) {
      final now = DateTime.now();
      if (now.difference(_lastJTime!).inMilliseconds < 300) {
        _lastJTime = null; // Consume the chord

        if (_view?.mode == VimMode.insert) {
          // In insert mode, we need to delete the 'j' that was just inserted.
          // Since we are using bridge.handleEditorKey for 'j', it's already in the buffer.
          _processKey('Backspace');
        }
        _processKey('Escape');
        return;
      }
    }

    // Track 'j' for potential chord
    if (key == 'j') {
      _lastJTime = DateTime.now();
    } else {
      _lastJTime = null;
    }

    final settings = ref.read(settingsProvider);
    if (!settings.vimEnabled) {
      if (key == 'Escape') return;
      if (_view?.mode != VimMode.insert) {
        _processKey('i');
      }
    }

    if (_view?.mode == VimMode.insert) {
      // Handle completion selection
      if (_completions.isNotEmpty) {
        final prefix = _getCurrentWordPrefix();
        final filtered = _getFilteredCompletions(prefix);

        if (filtered.isNotEmpty) {
          if (key == 'Tab') {
            // If completion window is open, Tab applies the completion (like Enter)
            final activeIndex = _completionIndex.clamp(0, filtered.length - 1);
            _applyCompletion(filtered[activeIndex]);
            return;
          } else if (key == 'Enter') {
            final activeIndex = _completionIndex.clamp(0, filtered.length - 1);
            _applyCompletion(filtered[activeIndex]);
            return;
          } else if (key == 'Escape') {
            setState(() {
              _completions = [];
              _completionIndex = -1;
            });
            // Do not return here; allow Escape to reach the editor to exit insert mode
          }
        }
      }

      // Handle Snippet navigation
      if (_snippetPlaceholders.isNotEmpty) {
        if (key == 'Tab') {
          _activeSnippetIndex++;
          if (_activeSnippetIndex >= _snippetPlaceholders.length) {
            // End of snippet
            _snippetPlaceholders = [];
            _activeSnippetIndex = -1;
          } else {
            // Find the start of the snippet to calculate absolute offsets correctly
            // This is a bit simplified, ideally we track the snippet's base start.
            // For now, we'll try to estimate or if the cursor is near the expected range.
            _jumpToSnippetPlaceholder(
                _activeSnippetIndex, _calculateSnippetBaseOffset());
          }
          _refreshView();
          return;
        } else if (key == 'Escape') {
          _snippetPlaceholders = [];
          _activeSnippetIndex = -1;
          _refreshView();
          // Do not return here; allow Escape to reach the editor to exit insert mode
        }
      }

      // In Insert mode, we let the IME (TextInputClient) handle all text input.
      // We only forward control keys that the IME doesn't natively handle for Vim modes.
      // Backspace/Delete are added here to ensure they work on desktop platforms.
      final isControlOrAlt = _ctrlPressed ||
          HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isAltPressed;
      final isSpecialKey = [
        'Escape',
        'ArrowLeft',
        'ArrowRight',
        'ArrowUp',
        'ArrowDown',
        'Backspace',
        'Delete',
        'Enter',
        'Tab'
      ].contains(key);

      if (isSpecialKey || isControlOrAlt) {
        _processKey(key);
      }
      return;
    }

    _processKey(key);
  }

  Future<void> _processKey(String key) async {
    try {
      final oldMode = _view?.mode;

      // Apply modifiers
      String finalKey = key;
      final isControl =
          _ctrlPressed || HardwareKeyboard.instance.isControlPressed;
      final isShift = _shiftPressed || HardwareKeyboard.instance.isShiftPressed;
      final isAlt = HardwareKeyboard.instance.isAltPressed;

      if (_completions.isNotEmpty) {
        final prefix = _getCurrentWordPrefix();
        final filtered = _getFilteredCompletions(prefix);

        if (key == 'Escape') {
          setState(() {
            _completions = [];
            _completionIndex = -1;
          });
          return;
        }

        if (key == 'Tab' || key == 'ArrowDown') {
          if (filtered.isNotEmpty) {
            setState(() {
              _completionIndex = (_completionIndex + 1) % filtered.length;
            });
            _scrollCompletionToVisible(_completionIndex);
            return;
          }
        }

        if (key == 'ArrowUp') {
          if (filtered.isNotEmpty) {
            setState(() {
              _completionIndex =
                  (_completionIndex - 1 + filtered.length) % filtered.length;
            });
            _scrollCompletionToVisible(_completionIndex);
            return;
          }
        }

        if (key == 'Enter') {
          if (_completionIndex >= 0 && _completionIndex < filtered.length) {
            _applyCompletion(filtered[_completionIndex]);
            return;
          }
        }
      }

      if (isControl && key != 'Control') {
        finalKey = 'Control+$key';
      }
      if (isShift &&
          key != 'Shift' &&
          !finalKey.startsWith('Control+') &&
          key.length > 1) {
        finalKey = 'Shift+$finalKey';
      }
      if (isAlt && key != 'Alt') {
        finalKey = 'Alt+$finalKey';
      }

      // Reset virtual modifiers after use
      if (_ctrlPressed || _shiftPressed) {
        setState(() {
          _ctrlPressed = false;
          _shiftPressed = false;
        });
      }

      // If it's Alt+Arrow, it's for page navigation in the preview.
      // We don't want to move the Vim cursor or trigger re-compilation.
      if (finalKey.startsWith('Alt+') && finalKey.contains('Arrow')) {
        return;
      }

      if (finalKey.toLowerCase() == 'control+v' ||
          finalKey == 'p' ||
          finalKey == 'P') {
        if (await _syncSystemClipboardToVim()) {
          // Image handled, skip standard text paste
          _refreshView();
          _triggerHighlight();
          if (widget.onChanged != null) {
            widget.onChanged!(bridge.getEditorContent());
          }
          return;
        }

        // If it's Control+v and not an image, and we are in Insert mode,
        // we should perform a standard text paste.
        if (finalKey.toLowerCase() == 'control+v' &&
            _view?.mode == VimMode.insert) {
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          if (data != null && data.text != null) {
            insertText(data.text!);
          }
          return;
        }
      }

      bridge.handleEditorKey(key: finalKey);
      _refreshView();
      _triggerHighlight();

      _notifyChanged();

      if (oldMode != VimMode.insert && _view?.mode == VimMode.insert) {
        _ignoreNextImeUpdate = true;
        _lastModeChangeTime = DateTime.now();
      }
    } catch (e) {
      debugPrint('Failed to handle key: $e');
    }
  }

  String? _mapKeyEvent(KeyEvent event) {
    final lk = event.logicalKey;
    if (lk == LogicalKeyboardKey.escape) return 'Escape';
    if (lk == LogicalKeyboardKey.backspace) return 'Backspace';
    if (lk == LogicalKeyboardKey.delete) return 'Delete';
    if (lk == LogicalKeyboardKey.enter) return 'Enter';
    if (lk == LogicalKeyboardKey.tab) return 'Tab';
    if (lk == LogicalKeyboardKey.arrowLeft) return 'ArrowLeft';
    if (lk == LogicalKeyboardKey.arrowRight) return 'ArrowRight';
    if (lk == LogicalKeyboardKey.arrowUp) return 'ArrowUp';
    if (lk == LogicalKeyboardKey.arrowDown) return 'ArrowDown';

    final isModifierPressed = HardwareKeyboard.instance.isControlPressed ||
        _ctrlPressed ||
        HardwareKeyboard.instance.isAltPressed;

    if (event is! KeyUpEvent &&
        event.character != null &&
        event.character!.isNotEmpty &&
        !isModifierPressed) {
      return event.character;
    }

    // For simple letters, use the key label
    final label = lk.keyLabel;
    if (label.length == 1) {
      // In Insert mode, we let characters bubble to the IME
      if (_view?.mode == VimMode.insert) return null;

      // In Normal/Visual mode, canonicalize to lowercase unless Shift is pressed
      final isShift = HardwareKeyboard.instance.isShiftPressed || _shiftPressed;
      return isShift ? label.toUpperCase() : label.toLowerCase();
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _view == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final hasFocus = widget.focusNode.hasFocus;
    final charHeight =
        widget.textStyle.fontSize! * (widget.textStyle.height ?? 1.4);
    final double scrollOffset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;
    final double preciseStartLine =
        (scrollOffset / charHeight).clamp(0.0, 1000000.0);
    final int baseLineIndex = preciseStartLine.floor();
    final double verticalOffset =
        -(preciseStartLine - baseLineIndex) * charHeight;
    final int totalLines = bridge.handleEditorGetTotalLines().toInt();
    final settings = ref.watch(settingsProvider);

    // 診断情報とバージョン同期
    final diagnostics = ref.watch(versionedDiagnosticsProvider);
    final currentVersion = ref.watch(docVersionProvider);
    final lastInputTime = ref.watch(lastInputTimeProvider);
    final isComposing = ref.watch(isComposingProvider);
    final activeTheme = ref.watch(activeThemeDetailedProvider);

    // Auto-sync Vim mode if disabled
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureInsertModeIfVimDisabled();
    });

    final painter = HeadlessEditorPainter(
      view: _view!,
      fontSize: editorFontSize,
      lineHeight: editorLineHeight,
      textStyle: widget.textStyle,
      cursorColor: widget.cursorColor,
      settings: settings,
      verticalOffset: verticalOffset,
      baseLineIndex: baseLineIndex,
      diagnostics: diagnostics,
      currentVersion: currentVersion,
      lastInputTime: lastInputTime,
      isComposing: isComposing,
      activeTheme: activeTheme,
    );

    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: (node, event) {
        if (event is KeyUpEvent) return KeyEventResult.ignored;
        final key = _mapKeyEvent(event);
        if (key == null) return KeyEventResult.ignored;

        // Keys we definitely want to capture and prevent from bubbling (focus traversal etc)
        const keysToCapture = [
          'Tab',
          'ArrowUp',
          'ArrowDown',
          'ArrowLeft',
          'ArrowRight',
          'Enter',
          'Escape',
          'Backspace',
          'Delete'
        ];

        // In Insert mode, we are VERY selective to avoid blocking the IME
        if (_view?.mode == VimMode.insert) {
          final isModifier = HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isAltPressed ||
              _ctrlPressed;
          if (keysToCapture.contains(key) || isModifier) {
            _handleKey(event);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        // In other modes (Normal, Visual), we handle everything that _mapKeyEvent recognized
        _handleKey(event);
        return KeyEventResult.handled;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          if ((constraints.maxHeight - _viewportHeight).abs() > 10 ||
              (constraints.maxWidth - _viewportWidth).abs() > 10) {
            _viewportHeight = constraints.maxHeight;
            _viewportWidth = constraints.maxWidth;
            _refreshView(debounced: true);
          }

          return GestureDetector(
            onTapUp: (details) {
              widget.focusNode.requestFocus();
              _updateConnectionState();

              final globalU16 = _getGlobalOffsetForPosition(
                  details.localPosition, constraints.biggest);
              if (globalU16 != null) {
                try {
                  bridge.handleEditorUpdateSelection(
                      cursorU16: BigInt.from(globalU16));
                  _refreshView(syncIme: true);
                } catch (e) {
                  debugPrint('Failed to set cursor from pointer: $e');
                }
              }
            },
            child: Container(
              color: Colors.transparent,
              child: Stack(
                children: [
                  // The actual scrollable area
                  Scrollbar(
                    controller: _scrollController,
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: CompositedTransformTarget(
                        link: _cursorLayerLink,
                        child: SizedBox(
                          height: totalLines * charHeight +
                              (_viewportHeight - charHeight)
                                  .clamp(0, 1000000), // Full overscroll
                          width: constraints.maxWidth,
                        ),
                      ),
                    ),
                  ),
                  // The custom painter is fixed, we handle virtualization in _refreshView
                  IgnorePointer(
                    child: CustomPaint(
                      size: Size(constraints.maxWidth, constraints.maxHeight),
                      painter: painter,
                    ),
                  ),
                  // Command-line overlay
                  if (_view?.commandText != null)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surface
                              .withOpacity(0.9),
                          border: Border(
                            top: BorderSide(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withOpacity(0.5),
                            ),
                          ),
                        ),
                        child: Text(
                          _view!.commandText!,
                          style: widget.textStyle.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  // Completion Overlay
                  if (_completions.isNotEmpty)
                    _buildCompletionsOverlay(constraints, charHeight),

                  // Mobile Vim Toolbar
                  if (Theme.of(context).platform == TargetPlatform.android ||
                      Theme.of(context).platform == TargetPlatform.iOS)
                    _buildMobileVimToolbar(constraints),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMobileVimToolbar(BoxConstraints constraints) {
    return Positioned(
      bottom: (_view?.commandText != null) ? 40 : 16,
      left: 16,
      right: 16,
      child: Center(
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(30),
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildModifierBtn('Ctrl', _ctrlPressed,
                      () => setState(() => _ctrlPressed = !_ctrlPressed)),
                  _buildModifierBtn('Shift', _shiftPressed,
                      () => setState(() => _shiftPressed = !_shiftPressed)),
                  const VerticalDivider(width: 16),
                  _buildToolbarBtn('Esc', () => _processKey('Escape')),
                  _buildToolbarBtn(':', () => _processKey(':')),
                  _buildToolbarBtn('i', () => _processKey('i')),
                  _buildToolbarBtn('v', () => _processKey('v')),
                  _buildToolbarBtn('Tab', () => _processKey('Tab')),
                  _buildToolbarBtn('Ent', () => _processKey('Enter')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModifierBtn(String label, bool active, VoidCallback onPressed) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  void _scrollCompletionToVisible(int index) {
    if (!_completionScrollController.hasClients) return;

    const double itemHeight = 24.0;
    const double viewportHeight = 250.0;
    const double padding = 4.0;

    final scrollOffset = _completionScrollController.offset;
    final itemTop = index * itemHeight + padding;
    final itemBottom = itemTop + itemHeight;
    final double bufferHeight = 2 * itemHeight;

    if (itemTop - bufferHeight < scrollOffset) {
      _completionScrollController.animateTo(
        (itemTop - bufferHeight)
            .clamp(0.0, _completionScrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    } else if (itemBottom + bufferHeight > scrollOffset + viewportHeight) {
      _completionScrollController.animateTo(
        (itemBottom + bufferHeight - viewportHeight)
            .clamp(0.0, _completionScrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

  Widget _buildToolbarBtn(String label, VoidCallback onPressed) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  Widget _buildCompletionsOverlay(
      BoxConstraints constraints, double charHeight) {
    final prefix = _getCurrentWordPrefix();
    final filteredCompletions = _getFilteredCompletions(prefix);

    if (filteredCompletions.isEmpty) return const SizedBox.shrink();

    // Ensure _completionIndex is within bounds for the filtered list
    final activeIndex =
        _completionIndex.clamp(0, filteredCompletions.length - 1);
    final selectedItem = filteredCompletions[activeIndex];

    // Caching documentation
    final String cacheKey =
        "${selectedItem.label}|${selectedItem.kind}|${selectedItem.detail ?? ''}";
    if (selectedItem.detail != null && selectedItem.detail!.isNotEmpty) {
      _docCache[cacheKey] = selectedItem.detail!;
    }
    final String? doc = _docCache[cacheKey];

    // Precise cursor positioning
    final cursorPixelPos = _getCursorPixelPosition(constraints);
    if (cursorPixelPos == null) return const SizedBox.shrink();

    // Note: CompositedTransformFollower will handle the base position.
    // We just need the offset relative to the target (the whole editor area).
    // The cursorPixelPos is absolute in the editor's child space.

    final double cursorX = cursorPixelPos.dx + 40; // 40 is leftMargin
    final double cursorY = cursorPixelPos.dy + _currentVerticalOffset;

    final double overlayWidth =
        (doc != null && doc.isNotEmpty && constraints.maxWidth > 550)
            ? 550
            : 200;

    return CompositedTransformFollower(
      link: _cursorLayerLink,
      showWhenUnlinked: false,
      offset: Offset(
        cursorX.clamp(
            0.0,
            (constraints.maxWidth - overlayWidth)
                .clamp(0.0, constraints.maxWidth)),
        (cursorY + charHeight + 4).clamp(0.0,
            (constraints.maxHeight - 200).clamp(0.0, constraints.maxHeight)),
      ),
      child: Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.surface.withOpacity(0.95),
        surfaceTintColor: Theme.of(context).colorScheme.surfaceTint,
        shadowColor: Colors.black.withOpacity(0.5),
        clipBehavior: Clip.antiAlias,
        child: Container(
          constraints: const BoxConstraints(maxHeight: 300),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Candidate List
              Container(
                width: 200, // Reduced fixed width for list
                decoration: BoxDecoration(
                  border: Border(
                      right: BorderSide(
                          color:
                              Theme.of(context).dividerColor.withOpacity(0.1))),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: filteredCompletions.length,
                  itemBuilder: (context, index) {
                    final item = filteredCompletions[index];
                    final isSelected = index == activeIndex;
                    return InkWell(
                      onTap: () {
                        setState(() {
                          _completionIndex = index;
                        });
                        _applyCompletion(item);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        color: isSelected
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                        child: Row(
                          children: [
                            _buildKindIcon(item.kind),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                item.label,
                                style: TextStyle(
                                  color: isSelected
                                      ? Theme.of(context)
                                          .colorScheme
                                          .onPrimaryContainer
                                      : null,
                                  fontSize: 12, // Slightly smaller font
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              // Documentation Pane - Only show if we have enough width
              if (doc != null && doc.isNotEmpty && constraints.maxWidth > 550)
                Flexible(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 350),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceVariant
                          .withOpacity(0.2),
                      border: Border(
                          left: BorderSide(
                              color: Theme.of(context)
                                  .dividerColor
                                  .withOpacity(0.05))),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        doc,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.5,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKindIcon(String kind) {
    final color = _getKindColor(kind);
    final svg = _getKindSvg(kind);

    return Container(
      width: 16,
      height: 16,
      alignment: Alignment.center,
      child: SvgPicture.string(
        svg,
        width: 14,
        height: 14,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      ),
    );
  }

  Color _getKindColor(String kind) {
    switch (kind.toLowerCase()) {
      case 'function':
        return Colors.purple;
      case 'constant':
        return Colors.orange;
      case 'variable':
        return Colors.blue;
      case 'symbol':
        return Colors.green;
      case 'snippet':
        return Colors.pinkAccent;
      case 'module':
        return Colors.cyan;
      case 'keyword':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String _getKindSvg(String kind) {
    // Basic SVG shapes or simple paths for kinds
    switch (kind.toLowerCase()) {
      case 'function':
        return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2L4.5 20.29L5.21 21L12 18L18.79 21L19.5 20.29L12 2Z"/></svg>';
      case 'variable':
        return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M12 8v8M8 12h8"/></svg>';
      case 'constant':
        return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"/><path d="M9 9l6 6M15 9l-6 6"/></svg>';
      case 'symbol':
        return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3l1.91 5.86H20l-4.92 3.57L16.99 19L12 15.42L7.01 19l1.91-6.57L4 8.86h6.09L12 3z"/></svg>';
      case 'snippet':
        return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"></path></svg>';
      default:
        return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M16 18l6-6-6-6M8 6l-6 6 6 6"/></svg>';
    }
  }

  Offset? _getCursorPixelPosition(BoxConstraints constraints) {
    if (_view == null) return null;

    // Find the line containing the cursor
    RenderLine? activeLine;
    for (final line in _view!.lines) {
      if (line.startU16.toInt() <= _view!.cursorGlobalU16.toInt() &&
          line.endU16.toInt() >= _view!.cursorGlobalU16.toInt()) {
        activeLine = line;
        break;
      }
    }
    if (activeLine == null) return null;

    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    textPainter.text = buildTextSpan(activeLine);

    const double leftMargin = 40.0;
    const double rightPadding = 8.0;
    textPainter.layout(
        maxWidth: constraints.maxWidth - leftMargin - rightPadding);

    final charIdx = _view!.cursorColumnU16.toInt();
    final textLength = textPainter.text?.toPlainText().length ?? 0;

    final bool isAtLineEnd = charIdx >= textLength;
    final int lookupIdx =
        isAtLineEnd ? (textLength - 1).clamp(0, textLength) : charIdx;

    double cursorX = 0;
    double cursorY = 0;

    if (textLength > 0) {
      final boxes = textPainter.getBoxesForSelection(
        TextSelection(
            baseOffset: lookupIdx,
            extentOffset: (lookupIdx + 1).clamp(0, textLength)),
      );

      if (boxes.isNotEmpty) {
        final box = boxes.first;
        cursorX = isAtLineEnd ? box.right : box.left;
        cursorY = box.top;
      }
    }

    // Account for line-specific Y-offset
    double cumulativeY = 0;
    final targetLine = _view!.cursorLine.toInt();
    final startVisibleLine = _view!.startLine.toInt();

    // We need to estimate the Y-position of the active line relative to the viewport top
    // Since we are virtualized, we can sum the heights of preceding visible lines
    for (int i = 0; i < (targetLine - startVisibleLine); i++) {
      if (i < _view!.lines.length) {
        final line = _view!.lines[i];
        final tp = TextPainter(textDirection: TextDirection.ltr);
        tp.text = buildTextSpan(line);
        tp.layout(maxWidth: constraints.maxWidth - leftMargin - rightPadding);
        cumulativeY += tp.height;
      }
    }

    return Offset(cursorX, cumulativeY + cursorY);
  }

  int? _getGlobalOffsetForPosition(Offset position, Size size) {
    if (_view == null) return null;

    double currentY = 0; // Relative to visible start
    const double leftMargin = 40.0;
    const double rightPadding = 8.0;

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    for (int i = 0; i < _view!.lines.length; i++) {
      final line = _view!.lines[i];
      textPainter.text = buildTextSpan(line);
      textPainter.layout(maxWidth: size.width - leftMargin - rightPadding);

      final double lineHeightPixels = textPainter.height;

      if (position.dy >= currentY &&
              position.dy < currentY + lineHeightPixels ||
          (i == _view!.lines.length - 1 && position.dy >= currentY)) {
        final localOffset =
            Offset(position.dx - leftMargin, position.dy - currentY);
        final textPosition = textPainter.getPositionForOffset(localOffset);

        return line.startU16.toInt() + textPosition.offset;
      }

      currentY += lineHeightPixels;
    }

    return null;
  }

  Future<bool> _syncSystemClipboardToVim() async {
    try {
      // 1. Check for image in clipboard
      debugPrint('Syncing clipboard... Checking for image.');
      Uint8List? imageBytes = await Pasteboard.image;
      if (imageBytes != null)
        debugPrint('Image found via Pasteboard: ${imageBytes.length} bytes');

      // Fallback for Linux (Wayland: wl-paste, X11: xclip)
      if (imageBytes == null && Platform.isLinux) {
        debugPrint(
            'Pasteboard.image returned null on Linux. Trying fallbacks.');
        // Try wl-paste (Wayland) with multiple types
        try {
          for (final mime in ['image/png', 'image/jpeg', 'image/webp']) {
            final result = await Process.run(
                'wl-paste', ['-t', mime, '--no-newline'],
                stdoutEncoding: null);
            if (result.exitCode == 0) {
              imageBytes = Uint8List.fromList(result.stdout as List<int>);
              debugPrint(
                  'Image found via wl-paste ($mime): ${imageBytes.length} bytes');
              break;
            }
          }
        } catch (e) {
          debugPrint('wl-paste fallback failed: $e');
        }

        // Try xclip (X11) if wl-paste failed
        if (imageBytes == null) {
          try {
            for (final mime in ['image/png', 'image/jpeg', 'image/webp']) {
              final result = await Process.run(
                  'xclip', ['-selection', 'clipboard', '-t', mime, '-o'],
                  stdoutEncoding: null);
              if (result.exitCode == 0) {
                imageBytes = Uint8List.fromList(result.stdout as List<int>);
                debugPrint(
                    'Image found via xclip ($mime): ${imageBytes.length} bytes');
                break;
              }
            }
          } catch (e) {
            debugPrint('xclip fallback failed: $e');
          }
        }
      }

      final effectivePath = widget.currentPath ?? _currentPath;
      if (imageBytes != null && effectivePath != null) {
        debugPrint('Saving image to disk... effectivePath: $effectivePath');
        final currentFile = File(effectivePath);
        final fileNameNoExt = p.basenameWithoutExtension(currentFile.path);
        final targetDir =
            Directory(p.join(currentFile.parent.path, fileNameNoExt));

        if (!await targetDir.exists()) {
          await targetDir.create(recursive: true);
        }

        final id = 'pasted_${DateTime.now().millisecondsSinceEpoch}';
        final imageFile = File(p.join(targetDir.path, '$id.png'));
        await imageFile.writeAsBytes(imageBytes);

        final snippet =
            '\n#figure(\n  image("$fileNameNoExt/$id.png", width: 80%),\n  caption: [Pasted Image $id],\n)\n';
        insertText(snippet, insertAfterCurrentLine: true);
        return true; // Handled as image
      }

      // 2. Fallback to text
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data != null && data.text != null) {
        bridge.handleEditorSetVimRegister(text: data.text!);
      }
    } catch (e) {
      debugPrint('Failed to sync system clipboard to Vim: $e');
    }
    return false;
  }

  Future<void> _jumpToSnippetPlaceholder(int index, int baseOffset) async {
    if (index < 0 || index >= _snippetPlaceholders.length) return;

    final p = _snippetPlaceholders[index];
    final globalStart = baseOffset + p.offset;
    final globalEnd = globalStart + p.length;

    try {
      // Move cursor to the end of the placeholder
      bridge.handleEditorUpdateSelection(cursorU16: BigInt.from(globalEnd));

      // If the placeholder has text (length > 0), select it
      // Note: Our bridge doesn't support range selection yet, but moving cursor works.

      _refreshView();
    } catch (e) {
      debugPrint('Failed to jump to snippet placeholder: $e');
    }
  }
}

class SnippetPlaceholder {
  final int index;
  final int offset;
  final int length;
  final String label;

  SnippetPlaceholder({
    required this.index,
    required this.offset,
    required this.length,
    required this.label,
  });
}
