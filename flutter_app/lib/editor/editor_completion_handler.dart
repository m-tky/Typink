part of 'headless_editor.dart';

mixin EditorCompletionHandler on EditorStateBase {
  @override
  void _triggerCompletion() {
    if (_view == null || _view!.mode != VimMode.insert) return;
    
    final content = bridge.getEditorContent();
    final cursorU16 = _view!.cursorGlobalU16.toInt();

    _completionTimer?.cancel();
    _completionTimer = Timer(const Duration(milliseconds: 100), () async {
      try {
        final results = await bridge.getCompletions(
          content: content,
          offsetU16: BigInt.from(cursorU16),
        );

        // 2. Fetch and merge Snippets
        final snippets = await ref.read(snippetsProvider.future);
        final prefix = _getCurrentWordPrefix(content: content, cursor: cursorU16);
        
        final snippetCompletions = snippets.where((s) => s.prefix.contains(prefix)).map((s) => bridge.TypstCompletion(
          label: s.prefix,
          apply: s.body,
          detail: s.description,
          kind: 'snippet',
        )).toList();

        if (mounted) {
          setState(() {
            _completions = [...snippetCompletions, ...results];
            _completionIndex = _completions.isNotEmpty ? 0 : -1;
          });
        }
      } catch (e) {
        debugPrint('Failed to fetch completions: $e');
      }
    });
  }

  void _applyCompletion(bridge.TypstCompletion completion) {
    if (_view == null) return;

    final fullText = bridge.getEditorContent();
    final cursor = _view!.cursorGlobalU16.toInt();
    
    int start = cursor;
    while (start > 0 && !RegExp(r'[\s()]').hasMatch(fullText[start - 1])) {
      start--;
      // If we hit a trigger-char at the start, stop there.
      // We stop at # (typst command), . (field), @ (cite/snippet), or $ (math)
      if (RegExp(r'[#.@$]$').hasMatch(fullText.substring(start, start + 1))) {
         break;
      }
    }

    final rawSnippet = completion.apply ?? completion.label;
    final regex = RegExp(r'\$\{(?:(?<index>\d+):)?(?<label>[^}]*)\}|\$(?<singleIndex>\d+)');
    final matches = regex.allMatches(rawSnippet).toList();
    
    final List<SnippetPlaceholder> placeholders = [];
    String cleanText = "";
    int lastMatchEnd = 0;
    
    for (final match in matches) {
      cleanText += rawSnippet.substring(lastMatchEnd, match.start);
      final label = match.namedGroup('label') ?? "";
      final indexStr = (match.namedGroup('index') ?? match.namedGroup('singleIndex')) ?? "0";
      final index = int.tryParse(indexStr) ?? 0;
      
      placeholders.add(SnippetPlaceholder(
        index: index,
        offset: cleanText.length,
        length: label.length,
        label: label,
      ));
      
      cleanText += label;
      lastMatchEnd = match.end;
    }
    cleanText += rawSnippet.substring(lastMatchEnd);

    placeholders.sort((a, b) {
      if (a.index == 0) return 1;
      if (b.index == 0) return -1;
      return a.index.compareTo(b.index);
    });

    try {
      bridge.handleEditorReplaceRange(
        startU16: BigInt.from(start),
        endU16: BigInt.from(cursor),
        text: cleanText,
        cursorU16: BigInt.from(start + cleanText.length), 
      );
      
      setState(() {
        _completions = [];
        _completionIndex = -1;
        _snippetPlaceholders = placeholders;
        _activeSnippetIndex = placeholders.isNotEmpty ? 0 : -1;
        _snippetBaseOffset = start;
      });

      _refreshView();
      _triggerHighlight();

      if (placeholders.isNotEmpty) {
        _jumpToSnippetPlaceholder(0, start);
      }
    } catch (e) {
      debugPrint('Failed to apply snippet: $e');
    }
  }

  void _jumpToSnippetPlaceholder(int pIndex, int baseOffset) {
    if (pIndex < 0 || pIndex >= _snippetPlaceholders.length) return;
    
    final p = _snippetPlaceholders[pIndex];
    final globalStart = baseOffset + p.offset;
    final globalEnd = globalStart + p.length;
    
    try {
      bridge.handleEditorUpdateSelection(cursorU16: BigInt.from(globalEnd));
      widget.focusNode.requestFocus();
      _refreshView();
    } catch (e) {
      debugPrint('Failed to jump to snippet placeholder: $e');
    }
  }

  String _getCurrentWordPrefix({String? content, int? cursor}) {
    final fullText = content ?? bridge.getEditorContent();
    final cursorIndex = cursor ?? _view!.cursorGlobalU16.toInt();
    int start = cursorIndex;
    final stopRegex = RegExp(r'[\s()\[\]{}$]'); // Added $ as bubble-stop
    while (start > 0 && !stopRegex.hasMatch(fullText[start - 1])) {
      start--;
    }
    return fullText.substring(start, cursorIndex).toLowerCase();
  }

  List<bridge.TypstCompletion> _getFilteredCompletions(String prefix) {
    if (prefix.isEmpty) return _completions;

    final scored = <MapEntry<bridge.TypstCompletion, int>>[];
    for (final c in _completions) {
      final label = c.label.toLowerCase();
      bool isPrefixTrigger = prefix.startsWith('#') || prefix.startsWith('.') || prefix.startsWith('@');
      String subPrefix = isPrefixTrigger ? prefix.substring(1) : prefix;
      String subLabel = label.startsWith('#') || label.startsWith('.') || label.startsWith('@') ? label.substring(1) : label;

      int score = -1;
      if (label == prefix || subLabel == subPrefix) {
        score = 100;
      } else if (label.startsWith(prefix) || subLabel.startsWith(subPrefix)) {
        score = 80;
      } else if (label.contains(prefix) || subLabel.contains(subPrefix)) {
        score = 60;
      } else {
        int j = 0;
        final target = isPrefixTrigger ? subPrefix : prefix;
        for (int i = 0; i < subLabel.length && j < target.length; i++) {
          if (subLabel[i] == target[j]) j++;
        }
        if (j == target.length) score = 40;
      }

      if (score > 0) {
        scored.add(MapEntry(c, score));
      }
    }

    scored.sort((a, b) {
      if (a.value != b.value) return b.value.compareTo(a.value);
      return a.key.label.toLowerCase().compareTo(b.key.label.toLowerCase());
    });

    return scored.map((e) => e.key).toList();
  }

  @override
  bool tryAutoExpandSnippetSync() {
    if (_view == null || _view!.mode != VimMode.insert) return false;

    final content = bridge.getEditorContent();
    final cursor = _view!.cursorGlobalU16.toInt();
    if (cursor < 2) return false;

    // Check last 2 characters for @ + char
    final prefix = content.substring(cursor - 2, cursor);
    if (!prefix.startsWith('@')) return false;

    final snippetsAsyncValue = ref.read(snippetsProvider);
    final snippets = snippetsAsyncValue.value;
    if (snippets == null) return false;

    final match = snippets.where((s) => s.prefix == prefix).firstOrNull;

    if (match != null) {
      // Trigger async expansion to avoid blocking IME pipeline
      scheduleMicrotask(() => expandSnippetAsync(match));
      return true;
    }
    return false;
  }

  @override
  Future<void> expandSnippetAsync(Snippet match) async {
    // Re-use _applyCompletion logic by creating a temporary bridge.TypstCompletion
    final completion = bridge.TypstCompletion(
      label: match.prefix,
      apply: match.body,
      detail: match.description,
      kind: 'snippet',
    );
    
    _applyCompletion(completion);
  }
}
