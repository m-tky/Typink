part of 'headless_editor.dart';

mixin EditorImeHandler on EditorStateBase implements TextInputClient {
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
        composing: _composing,
      ));
      
      final cursorRect = _computeCaretRect();
      if (cursorRect != Rect.zero) {
        final dynamic connection = _connection;
        // Correct order: caret -> selection -> editable
        try { connection.setCaretRect(cursorRect); } catch (_) {}
        try { connection.setSelectionRects([cursorRect]); } catch (_) {}
        try { connection.setEditableRects([cursorRect]); } catch (_) {}
      }
    } else {
      _closeInputConnectionIfNeeded();
    }
  }

  void _closeInputConnectionIfNeeded() {
    _connection?.close();
    _connection = null;
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    if (_view == null) return;
    
    if (_view!.mode != VimMode.insert) {
      _updateConnectionState();
      return;
    }

    // 更新 composition 状態
    _composing = value.composing;
    final isComposing = _composing.isValid && !_composing.isCollapsed;
    ref.read(isComposingProvider.notifier).state = isComposing;

    if (_ignoreNextImeUpdate) {
      final now = DateTime.now();
      if (_lastModeChangeTime != null && now.difference(_lastModeChangeTime!) < const Duration(milliseconds: 150)) {
        _ignoreNextImeUpdate = false;
        _updateConnectionState();
        return;
      }
      _ignoreNextImeUpdate = false;
    }

    final oldText = bridge.getEditorContent();
    if (value.text == oldText) {
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
    debugPrint('IME Update: insertedText="$insertedText" at $start, oldEnd=$oldEnd');

    const pairs = {
      '(': ')',
      '[': ']',
      '{': '}',
      '"': '"',
      "'": "'",
      r'$': r'$',
      '*': '*',
    };

    if (insertedText.length == 1 && start < oldText.length && insertedText == oldText[start]) {
      if (pairs.values.contains(insertedText) || (insertedText == r'$' || insertedText == '*')) {
        try {
          bridge.handleEditorUpdateSelection(cursorU16: BigInt.from(start + 1));
          _refreshView(syncIme: true);
          return;
        } catch (e) {
          debugPrint('Failed overtyping: $e');
        }
      }
    }

    if (insertedText.length == 1 && pairs.containsKey(insertedText)) {
      final closing = pairs[insertedText]!;
      debugPrint('Auto-closing $insertedText with $closing');
      final afterCursor = (start < oldText.length) ? oldText[start] : "";
      final shouldAutoClose = afterCursor.isEmpty || RegExp(r'[\s)\]}*$_]').hasMatch(afterCursor);

      if (shouldAutoClose) {
        final pairText = insertedText + closing;
        try {
          bridge.handleEditorReplaceRange(
            startU16: BigInt.from(start),
            endU16: BigInt.from(oldEnd),
            text: pairText,
            cursorU16: BigInt.from(start + 1),
          );
          _refreshView(syncIme: false);
          _triggerHighlight();
          _updateConnectionState();
          
          _notifyChanged();
          return;
        } catch (e) {
          debugPrint('Failed auto-close: $e');
        }
      }
    }
    
    if (insertedText.isEmpty && oldText.length == value.text.length + 1) {
      final deletedChar = oldText[start];
      if (start < value.text.length) {
        final charAfter = value.text[start];
        if (pairs[deletedChar] == charAfter) {
          try {
            bridge.handleEditorReplaceRange(
              startU16: BigInt.from(start),
              endU16: BigInt.from(start + 1),
              text: "",
              cursorU16: BigInt.from(start),
            );
            _refreshView(syncIme: true);
            return;
          } catch (e) {}
        }
      }
      if (start > 0) {
        final charBefore = value.text[start - 1];
        if (pairs[charBefore] == deletedChar) {
          try {
            bridge.handleEditorReplaceRange(
              startU16: BigInt.from(start - 1),
              endU16: BigInt.from(start),
              text: "",
              cursorU16: BigInt.from(start - 1),
            );
            _refreshView(syncIme: true);
            return;
          } catch (e) {}
        }
      }
    }
    
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
      
      final cursorRect = _computeCaretRect();
      if (cursorRect != Rect.zero) {
        final dynamic connection = _connection;
        try { connection.setCaretRect(cursorRect); } catch (_) {}
        try { connection.setSelectionRects([cursorRect]); } catch (_) {}
        try { connection.setEditableRects([cursorRect]); } catch (_) {}
      }
      
      if (insertedText.isNotEmpty) {
        if (!tryAutoExpandSnippetSync()) {
          _triggerCompletion();
        }
      } else {
        setState(() {
          _completions = [];
          _completionIndex = -1;
        });
      }

      _notifyChanged();
    } catch (e) {
      debugPrint('Failed to update editing value: $e');
    }
  }

  @override void performAction(TextInputAction action) {}
  @override void performSelector(String selectorName) {}
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
}
