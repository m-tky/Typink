import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../frb_generated.dart/api.dart' as bridge;
import '../frb_generated.dart/editor.dart';
import '../frb_generated.dart/vim_engine.dart';
import 'headless_editor_painter.dart';
import 'vim_provider.dart';
import 'providers.dart';

class HeadlessEditorView extends ConsumerStatefulWidget {
  final FocusNode focusNode;
  final TextStyle textStyle;
  final Color cursorColor;
  final String initialContent;

  const HeadlessEditorView({
    super.key,
    required this.focusNode,
    required this.textStyle,
    required this.cursorColor,
    required this.initialContent,
  });

  @override
  ConsumerState<HeadlessEditorView> createState() => _HeadlessEditorViewState();
}

class _HeadlessEditorViewState extends ConsumerState<HeadlessEditorView>
    with TextInputClient {
  EditorView? _view;
  bool _isLoading = true;
  TextInputConnection? _connection;
  bool _ignoreNextImeUpdate = false;
  DateTime? _lastModeChangeTime;
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    _initContent();
    widget.focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_handleFocusChange);
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  void _handleFocusChange() {
    if (widget.focusNode.hasFocus) {
      _updateConnectionState();
    } else {
      _closeInputConnectionIfNeeded();
    }
  }

  void _closeInputConnectionIfNeeded() {
    _connection?.close();
    _connection = null;
  }

  void _updateConnectionState() {
    if (!widget.focusNode.hasFocus || _view == null) return;

    if (_view!.mode == VimMode.insert) {
      if (_connection == null || !_connection!.attached) {
        _connection = TextInput.attach(this, const TextInputConfiguration(
          enableDeltaModel: false,
          inputType: TextInputType.multiline,
          inputAction: TextInputAction.newline,
        ));
        _connection!.show();
      }
      final fullText = bridge.getEditorContent();
      _connection!.setEditingState(TextEditingValue(
        text: fullText,
        selection: TextSelection.collapsed(offset: _view!.cursorGlobalU16.toInt()),
      ));
    } else {
      _closeInputConnectionIfNeeded();
    }
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    if (_view == null) return;
    
    if (_view!.mode != VimMode.insert) {
      // If we are not in insert mode, do not allow text changes via IME.
      // However, we MUST sync the IME state back to ensure it doesn't get stuck.
      _updateConnectionState();
      return;
    }

    if (_ignoreNextImeUpdate) {
      final now = DateTime.now();
      if (_lastModeChangeTime != null && now.difference(_lastModeChangeTime!) < const Duration(milliseconds: 150)) {
        // This is likely the exact key that triggered the mode change
        _ignoreNextImeUpdate = false;
        _updateConnectionState();
        return;
      }
      _ignoreNextImeUpdate = false;
    }

    final oldText = bridge.getEditorContent();
    if (value.text == oldText) {
      // If only selection changed (e.g. mouse click within IME, or arrow keys during composition)
      if (value.selection.isValid && value.selection.isCollapsed) {
        int offset = value.selection.baseOffset;
        if (offset != _view!.cursorGlobalU16.toInt()) {
          try {
            bridge.handleEditorUpdateSelection(cursorU16: BigInt.from(offset));
            _refreshView(syncIme: false);
          } catch (e) {
            debugPrint('Failed to update selection: $e');
          }
        }
      }
      return;
    }

    // Basic diffing to find what changed
    int start = 0;
    while (start < oldText.length && start < value.text.length && oldText[start] == value.text[start]) {
      start++;
    }
    
    int oldEnd = oldText.length;
    int newEnd = value.text.length;
    while (oldEnd > start && newEnd > start && oldText[oldEnd - 1] == value.text[newEnd - 1]) {
      oldEnd--;
      newEnd--;
    }
    
    final insertedText = value.text.substring(start, newEnd);
    
    int? cursorU16;
    if (value.selection.isValid && value.selection.isCollapsed) {
      cursorU16 = value.selection.baseOffset;
    }
    
    try {
      bridge.handleEditorReplaceRange(
        startU16: BigInt.from(start),
        endU16: BigInt.from(oldEnd),
        text: insertedText,
        cursorU16: cursorU16 != null ? BigInt.from(cursorU16) : null,
      );
      _refreshView(syncIme: false);
      _triggerHighlight();
    } catch (e) {
      debugPrint('Failed to update editing value: $e');
    }
  }

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

  @override void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override void showAutofillHints() {}
  @override void insertTextPlaceholder(Size size) {}
  @override void removeTextPlaceholder() {}
  @override void showToolbar() {}
  @override void hideToolbar() {}
  @override AutofillScope? get autofillScope => null;
  @override AutofillScope? get currentAutofillScope => null;
  @override TextEditingValue? get currentTextEditingValue => null;
  @override void didChangeInputControl(TextInputControl? oldControl, TextInputControl? newControl) {}
  @override void insertContent(KeyboardInsertedContent content) {}
  @override void connectionClosed() {}
  @override void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override void showAutocorrectionPromptRect(int start, int end) {}

  void _initContent() {
    try {
      bridge.setEditorContent(content: widget.initialContent);
      bridge.handleEditorTriggerHighlight();
      _refreshView();
    } catch (e) {
      debugPrint('Failed to initialize content: $e');
    }
  }

  void _refreshView({bool syncIme = true}) {
    try {
      final view = bridge.getEditorView(startLine: BigInt.from(0), endLine: BigInt.from(1000));
      if (mounted) {
        setState(() {
          _view = view;
          _isLoading = false;
        });
        if (syncIme) {
          _updateConnectionState();
        }
        // Sync Vim mode for the status bar
        ref.read(vimModeProvider.notifier).state = view.mode;
      }
    } catch (e) {
      debugPrint('Failed to fetch editor view: $e');
    }
  }

  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final key = _mapKeyEvent(event);
    debugPrint('Key pressed: ${event.logicalKey.debugName}, Character: ${event.character}, Mapped: $key');
    
    if (key == null) return;

    if (_view?.mode == VimMode.insert) {
      // In Insert mode, we let the IME (TextInputClient) handle all text input.
      // We only forward control keys that the IME doesn't natively handle for Vim modes.
      // 'Backspace' and 'Enter' are handled by the IME/TextInputClient updates.
      if (['Escape', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].contains(key)) {
        _processKey(key);
      }
      return;
    }

    _processKey(key);
  }

  void _processKey(String key) {
    try {
      final oldMode = _view?.mode;
      bridge.handleEditorKey(key: key);
      _refreshView();
      _triggerHighlight();
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
    if (lk == LogicalKeyboardKey.enter) return 'Enter';
    if (lk == LogicalKeyboardKey.tab) return 'Tab';
    if (lk == LogicalKeyboardKey.arrowLeft) return 'ArrowLeft';
    if (lk == LogicalKeyboardKey.arrowRight) return 'ArrowRight';
    if (lk == LogicalKeyboardKey.arrowUp) return 'ArrowUp';
    if (lk == LogicalKeyboardKey.arrowDown) return 'ArrowDown';
    
    if (event is KeyDownEvent && event.character != null && event.character!.isNotEmpty) {
      return event.character;
    }
    
    // For simple letters, use the key label
    final label = lk.keyLabel;
    if (label.length == 1) {
      // In Normal/Visual mode, Vim commands are case-sensitive.
      // Usually, 'd' is lowercase. Shift+'d' is 'D'.
      // Flutter's keyLabel for 'd' is often 'D', but 'event.character' is lowercase 'd'.
      // If event.character was null, we fallback to label.
      return (_view?.mode == VimMode.insert) ? label : label.toLowerCase();
    }
    
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _view == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final hasFocus = widget.focusNode.hasFocus;
    final settings = ref.watch(settingsProvider);

    final painter = HeadlessEditorPainter(
      view: _view!,
      textStyle: widget.textStyle,
      cursorColor: widget.cursorColor,
      settings: settings,
    );

    return KeyboardListener(
      focusNode: widget.focusNode,
      onKeyEvent: _handleKey,
      autofocus: true,
      child: GestureDetector(
        onTapUp: (details) {
          widget.focusNode.requestFocus();
          _updateConnectionState();
          setState(() {}); // Rebuild to show focus border
          
          final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
          if (renderBox != null) {
            final globalU16 = painter.getGlobalOffsetForPosition(details.localPosition, renderBox.size);
            if (globalU16 != null) {
              try {
                bridge.handleEditorUpdateSelection(cursorU16: BigInt.from(globalU16));
                _refreshView(syncIme: true);
              } catch (e) {
                debugPrint('Failed to set cursor from pointer: $e');
              }
            }
          }
        },
        child: Container(
          decoration: BoxDecoration(
            color: Colors.transparent, // Ensure it's hit-testable
            border: Border.all(
              color: hasFocus ? widget.cursorColor.withOpacity(0.5) : Colors.transparent,
              width: 1,
            ),
          ),
          width: double.infinity,
          height: double.infinity,
          child: CustomPaint(
            painter: painter,
          ),
        ),
      ),
    );
  }
}
