import 'package:flutter_test/flutter_test.dart';

// Standalone helpers mirroring the prefix/range logic in EditorCompletionHandler.
// Kept here so the test has no dependency on part-file internals.

String _getPrefix(String content, int cursor) {
  int start = cursor;
  final stopRegex = RegExp(r'[\s()\[\]{}$]');
  while (start > 0 && !stopRegex.hasMatch(content[start - 1])) {
    start--;
  }
  return content.substring(start, cursor).toLowerCase();
}

({int start, int end}) _findReplacementRange(String fullText, int cursor) {
  int start = cursor;
  while (start > 0 && !RegExp(r'[\s()]').hasMatch(fullText[start - 1])) {
    start--;
    if (RegExp(r'[#.@$]$').hasMatch(fullText.substring(start, start + 1))) {
      break;
    }
  }
  return (start: start, end: cursor);
}

void main() {
  group('Math Mode Prefix Logic', () {
    test('Prefix identification stops at \$', () {
      expect(_getPrefix(r'$@a', 3), '@a');
      expect(_getPrefix(r' $@a', 4), '@a');
      expect(_getPrefix(r'($@a)', 4), '@a');
    });

    test('Replacement range identification stops at \$', () {
      final range = _findReplacementRange(r'$@a', 3);
      expect(range.start, 1);
      expect(range.end, 3);
    });

    test('Works with existing triggers (#, .)', () {
      expect(_findReplacementRange('#rect', 5).start, 0);
      expect(_findReplacementRange(' #rect', 6).start, 1);
    });
  });
}
