import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../frb_generated.dart/api.dart' as bridge;
import '../frb_generated.dart/vim_engine.dart' as v;

final vimModeProvider = StateProvider<v.VimMode>((ref) => v.VimMode.normal);

class VimNotifier {
  final Ref ref;
  VimNotifier(this.ref);

  // ignore: deprecated_member_use
  Future<void> handleKeyEvent(RawKeyEvent event, String content) async {
    // ignore: deprecated_member_use
    if (event is! RawKeyDownEvent) return;

    final key = _mapLogicalKey(event.logicalKey);
    if (key == null) return;

    final action = bridge.handleEditorKey(key: key);
    if (action != null) {
      ref.read(vimModeProvider.notifier).state = action.mode;
    }
  }

  String? _mapLogicalKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.escape) return 'Escape';
    if (key == LogicalKeyboardKey.backspace) return 'Backspace';
    if (key == LogicalKeyboardKey.enter) return 'Enter';

    final label = key.keyLabel;
    if (label.length == 1) return label;

    return null;
  }
}

final vimProvider = Provider((ref) => VimNotifier(ref));
