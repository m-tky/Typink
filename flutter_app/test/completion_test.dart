import 'package:flutter_test/flutter_test.dart';
import 'package:typink/editor/editor_completion_handler.dart';

// A mock class to expose the logic we want to test
class PrefixTester with EditorCompletionHandler {
  @override
  dynamic get ref => null;
  @override
  dynamic get bridge => null;
  @override
  dynamic get _view => null;

  // Re-expose the private logic for testing
  String getPrefix(String content, int cursor) {
    int start = cursor;
    final stopRegex = RegExp(r'[\s()\[\]{}$]'); 
    while (start > 0 && !stopRegex.hasMatch(content[start - 1])) {
      start--;
    }
    return content.substring(start, cursor).toLowerCase();
  }

  Range findReplacementRange(String fullText, int cursor) {
    int start = cursor;
    while (start > 0 && !RegExp(r'[\s()]').hasMatch(fullText[start - 1])) {
      start--;
      if (RegExp(r'[#.@$]$').hasMatch(fullText.substring(start, start + 1))) {
         break;
      }
    }
    return Range(start: start, end: cursor);
  }
}

class Range {
  final int start;
  final int end;
  Range({required this.start, required this.end});
  @override
  String toString() => 'Range($start, $end)';
}

void main() {
  final tester = PrefixTester();

  group('Math Mode Prefix Logic', () {
    test('Prefix identification stops at $', () {
      expect(tester.getPrefix('$@a', 3), '@a');
      expect(tester.getPrefix(' $@a', 4), '@a');
      expect(tester.getPrefix('($@a)', 4), '@a');
    });

    test('Replacement range identification stops at $', () {
      // In "$@a", cursor is at 3.
      // start should be 1 (index of @)
      final range = tester.findReplacementRange('$@a', 3);
      expect(range.start, 1);
      expect(range.end, 3);
    });

    test('Works with existing triggers (#, .)', () {
      expect(tester.findReplacementRange('#rect', 5).start, 0);
      expect(tester.findReplacementRange(' #rect', 6).start, 1);
    });
  });
}
