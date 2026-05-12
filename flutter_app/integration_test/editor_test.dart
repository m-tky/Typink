import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:typink/editor/headless_editor.dart';
import 'package:typink/frb_generated.dart/api.dart' as bridge;
import 'package:typink/frb_generated.dart/frb_generated.dart';
import 'package:typink/frb_generated.dart/vim_engine.dart' as v;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Editor correctly handles typing and clicking',
      (WidgetTester tester) async {
    await RustLib.init();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 400,
                child: HeadlessEditorView(
                  focusNode: FocusNode(),
                  textStyle:
                      const TextStyle(fontSize: 14, fontFamily: 'monospace'),
                  cursorColor: Colors.blue,
                  initialContent: "Hello\nWorld\n",
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify initial content
    expect(bridge.getEditorContent(), equals("Hello\nWorld\n"));

    // Find the editor
    final editorFinder = find.byType(HeadlessEditorView);
    expect(editorFinder, findsOneWidget);

    // Tap to focus
    await tester.tap(editorFinder);
    await tester.pumpAndSettle();

    // Verify initial cursor position (starts at 0)
    var view = bridge.getEditorView(
        startLine: BigInt.from(0), endLine: BigInt.from(10));
    expect(view.cursorGlobalU16.toInt(), equals(0));

    // Now test pointer click to move cursor
    // The top-left is Line 1. Line 2 is below it.
    final offset = tester.getTopLeft(editorFinder) + const Offset(50, 30);
    await tester.tapAt(offset);
    await tester.pumpAndSettle();

    // Verify cursor has moved down
    view = bridge.getEditorView(
        startLine: BigInt.from(0), endLine: BigInt.from(10));

    // It should have moved to the second line or somewhere > 0
    expect(view.cursorGlobalU16.toInt(), greaterThan(5));
    expect(
        view.mode, equals(v.VimMode.normal)); // Should still be in Normal mode
  });

  testWidgets('Editor handles Vim commands (dd, p)',
      (WidgetTester tester) async {
    await RustLib.init();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 400,
                child: HeadlessEditorView(
                  focusNode: FocusNode(),
                  textStyle:
                      const TextStyle(fontSize: 14, fontFamily: 'monospace'),
                  cursorColor: Colors.blue,
                  initialContent: "Line 1\nLine 2\nLine 3",
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final editorFinder = find.byType(HeadlessEditorView);
    await tester.tap(editorFinder);
    await tester.pumpAndSettle();

    // Send 'dd' - Note: in our KeyboardListener, we forward characters
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.pumpAndSettle();

    // Verify Line 1 is deleted
    expect(bridge.getEditorContent(), equals("Line 2\nLine 3"));

    // Send 'p' to paste
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pumpAndSettle();

    // Verify Line 1 is pasted below Line 2
    expect(bridge.getEditorContent(), equals("Line 2\nLine 1\nLine 3"));
  });
}
