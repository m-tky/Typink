import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'providers.dart';

final workspacePathProvider = StateProvider<Directory?>((ref) => null);

class WorkspaceNotifier {
  final Ref ref;
  static const String _key = 'last_workspace_path';
  static const String _fileKey = 'last_opened_file_path';

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

  Future<void> saveLastFile(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fileKey, path);
  }

  Future<void> clearWorkspace() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    ref.read(workspacePathProvider.notifier).state = null;
  }

  Future<void> renameEntity(FileSystemEntity entity, String newName) async {
    final parent = entity.parent.path;
    final oldName = p.basenameWithoutExtension(entity.path);
    final extension = entity is File ? p.extension(entity.path) : '';
    final newPath = p.join(parent, newName + extension);

    if (await FileSystemEntity.type(newPath) != FileSystemEntityType.notFound) {
      throw Exception('Target name already exists');
    }

    // Rename the main entity
    await entity.rename(newPath);

    // Update active file provider if necessary
    final activeFile = ref.read(currentTypFileProvider);
    if (activeFile != null && activeFile.path == entity.path) {
      ref.read(currentTypFileProvider.notifier).state = File(newPath);
    }

    // Handle associated folder renaming and internal path updates for .typ files
    if (entity is File && (extension == '.typ' || extension == '.typst')) {
      // 1. Rename physical folders
      // Same directory folder (e.g. notes/chapter1/)
      final localFolder = Directory(p.join(parent, oldName));
      if (await localFolder.exists()) {
        await localFolder.rename(p.join(parent, newName));
      }

      // Folder in figures/ (e.g. notes/figures/chapter1/)
      final figuresFolder = Directory(p.join(parent, 'figures', oldName));
      if (await figuresFolder.exists()) {
        await figuresFolder.rename(p.join(parent, 'figures', newName));
      }

      // 2. Update paths INSIDE the renamed .typ file
      try {
        final file = File(newPath);
        String content = await file.readAsString();

        // Replace "figures/oldName/" with "figures/newName/"
        // and also handle "oldName/" if used directly
        final figuresPattern = RegExp('figures/$oldName/');
        final directPattern = RegExp(
            '"$oldName/'); // Look for "oldName/ to avoid accidental matches

        String newContent =
            content.replaceAll(figuresPattern, 'figures/$newName/');
        newContent = newContent.replaceAll(directPattern, '"$newName/');

        if (newContent != content) {
          await file.writeAsString(newContent);
          // If this is the active file, we might need to notify providers
          if (activeFile?.path == entity.path) {
            ref.read(rawContentProvider.notifier).state = newContent;
            ref.read(debouncedContentProvider.notifier).state = newContent;
          }
        }
      } catch (e) {
        debugPrint('Failed to update internal paths: $e');
      }
    }

    // Refresh the workspace state
    final currentDir = ref.read(workspacePathProvider);
    if (currentDir != null) {
      ref.read(workspacePathProvider.notifier).state =
          Directory(currentDir.path);
    }
  }

  Future<void> deleteEntity(FileSystemEntity entity) async {
    final parent = entity.parent.path;
    final oldName = p.basenameWithoutExtension(entity.path);
    final extension = entity is File ? p.extension(entity.path) : '';

    // Delete the main entity
    await entity.delete(recursive: true);

    // Update active file provider if necessary
    final activeFile = ref.read(currentTypFileProvider);
    if (activeFile != null && activeFile.path == entity.path) {
      ref.read(currentTypFileProvider.notifier).state = null;
    }

    // Handle associated folder deletion for .typ files
    if (entity is File && (extension == '.typ' || extension == '.typst')) {
      final localFolder = Directory(p.join(parent, oldName));
      if (await localFolder.exists()) {
        await localFolder.delete(recursive: true);
      }

      final figuresFolder = Directory(p.join(parent, 'figures', oldName));
      if (await figuresFolder.exists()) {
        await figuresFolder.delete(recursive: true);
      }
    }

    // Refresh
    final currentDir = ref.read(workspacePathProvider);
    if (currentDir != null) {
      ref.read(workspacePathProvider.notifier).state =
          Directory(currentDir.path);
    }
  }

  Future<void> createFile(String name, {String? parentPath}) async {
    final root = ref.read(workspacePathProvider);
    if (root == null) return;

    final targetDir = parentPath ?? root.path;
    final fileName = name.endsWith('.typ') ? name : '$name.typ';
    final file = File(p.join(targetDir, fileName));

    if (!await file.exists()) {
      await file.writeAsString('= $name\n\n');

      // 自動的にSVG用フォルダも同じ階層に作成する（オプション的に扱うことも可能ですが、利便性のため作成）
      final folderName = p.basenameWithoutExtension(fileName);
      final svgFolder = Directory(p.join(targetDir, folderName));
      if (!await svgFolder.exists()) {
        await svgFolder.create(recursive: true);
      }

      _refresh();
    }
  }

  Future<void> createFolder(String name, {String? parentPath}) async {
    final root = ref.read(workspacePathProvider);
    if (root == null) return;

    final targetDir = parentPath ?? root.path;
    final folder = Directory(p.join(targetDir, name));
    if (!await folder.exists()) {
      await folder.create(recursive: true);
      _refresh();
    }
  }

  Future<void> moveEntity(
      FileSystemEntity entity, String targetParentPath) async {
    final oldName = p.basename(entity.path);
    final oldNameNoExt = p.basenameWithoutExtension(entity.path);
    final newPath = p.join(targetParentPath, oldName);

    if (newPath == entity.path) return;
    if (await FileSystemEntity.type(newPath) != FileSystemEntityType.notFound) {
      throw Exception('Target already exists in destination');
    }

    // 1. メインのエンティティを移動
    await entity.rename(newPath);

    // 2. アクティブなファイルならプロバイダーを更新
    final activeFile = ref.read(currentTypFileProvider);
    if (activeFile != null && activeFile.path == entity.path) {
      ref.read(currentTypFileProvider.notifier).state = File(newPath);
    }

    // 3. .typ ファイルの場合、関連するフォルダも移動
    if (entity is File &&
        (p.extension(entity.path) == '.typ' ||
            p.extension(entity.path) == '.typst')) {
      final oldParent = entity.parent.path;

      // 同一階層のフォルダ (e.g. old/path/name/)
      final localFolder = Directory(p.join(oldParent, oldNameNoExt));
      if (await localFolder.exists()) {
        await localFolder.rename(p.join(targetParentPath, oldNameNoExt));
      }

      // figures/ 以下のフォルダ (e.g. old/path/figures/name/)
      final figuresFolder =
          Directory(p.join(oldParent, 'figures', oldNameNoExt));
      if (await figuresFolder.exists()) {
        final newFiguresParent = Directory(p.join(targetParentPath, 'figures'));
        if (!await newFiguresParent.exists()) {
          await newFiguresParent.create(recursive: true);
        }
        await figuresFolder.rename(p.join(newFiguresParent.path, oldNameNoExt));
      }
    }

    _refresh();
  }

  void _refresh() {
    final currentDir = ref.read(workspacePathProvider);
    if (currentDir != null) {
      ref.read(workspacePathProvider.notifier).state =
          Directory(currentDir.path);
    }
  }
}

final workspaceManagerProvider = Provider((ref) => WorkspaceNotifier(ref));
