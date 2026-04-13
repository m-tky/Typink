import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'providers.dart';

final workspacePathProvider = StateProvider<Directory?>((ref) => null);

class WorkspaceNotifier {
  final Ref ref;
  static const String _key = 'last_workspace_path';

  WorkspaceNotifier(this.ref);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final lastPath = prefs.getString(_key);
    if (lastPath != null) {
      final dir = Directory(lastPath);
      if (await dir.exists()) {
        ref.read(workspacePathProvider.notifier).state = dir;
        await ref.read(persistenceProvider).loadNotebook(dir);
      }
    }
  }

  Future<void> openWorkspace(Directory dir) async {
    if (!await dir.exists()) await dir.create(recursive: true);
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, dir.path);
    
    ref.read(workspacePathProvider.notifier).state = dir;
    await ref.read(persistenceProvider).loadNotebook(dir);
  }

  Future<void> clearWorkspace() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    ref.read(workspacePathProvider.notifier).state = null;
  }
}

final workspaceManagerProvider = Provider((ref) => WorkspaceNotifier(ref));
