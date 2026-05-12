export 'handwriting_provider.dart';
export 'settings_provider.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../frb_generated.dart/api.dart' as bridge;
import '../frb_generated.dart/frb_generated.dart';
import 'handwriting_provider.dart';
import 'settings_provider.dart';

final currentTypFileProvider = StateProvider<File?>((ref) => null);

final selectedFileProvider = StateProvider<File?>((ref) => null);

final documentTitleProvider = Provider<String>((ref) {
  final file = ref.watch(selectedFileProvider);
  if (file != null) return p.basename(file.path);
  final dir = ref.watch(notebookPathProvider);
  return dir != null ? p.basename(dir.path) : 'Untitled';
});

// 現在のドキュメントの編集世代（Version）を追跡するプロバイダー
final contentVersionProvider = StateProvider<int>((ref) => 0);

final rawContentProvider = StateProvider<String>((ref) => '');

final debouncedContentProvider = StateProvider<String>((ref) => '');

final currentPageProvider = StateProvider<int>((ref) => 0);

/// エディタの現在のドキュメントバージョン (非同期同期用)
final docVersionProvider = StateProvider<int>((ref) => 0);

/// バージョン付きの診断情報
class VersionedDiagnostics {
  final int version;
  final List<bridge.TypstDiagnostic> items;

  VersionedDiagnostics({required this.version, required this.items});

  static VersionedDiagnostics empty() =>
      VersionedDiagnostics(version: -1, items: []);
}

/// 最終入力時刻 (タイピング判定用)
final lastInputTimeProvider = StateProvider<DateTime>((ref) => DateTime.now());

/// IMEが組成中かどうか
final isComposingProvider = StateProvider<bool>((ref) => false);

/// 最新の診断情報（バージョン付き）
final versionedDiagnosticsProvider =
    StateProvider<VersionedDiagnostics>((ref) => VersionedDiagnostics.empty());

enum LayoutMode {
  editorOnly,
  previewOnly,
  split,
}

enum SplitMode {
  horizontal,
  vertical,
}

final layoutModeProvider = StateProvider<LayoutMode>((ref) => LayoutMode.split);
final splitOrientationProvider =
    StateProvider<SplitMode>((ref) => SplitMode.horizontal);
final splitRatioProvider = StateProvider<double>((ref) => 0.5);

final typstCompileResultProvider =
    FutureProvider<bridge.TypstCompileResult>((ref) async {
  final userContent = ref.watch(debouncedContentProvider);
  final currentVersion = ref.read(docVersionProvider);

  if (userContent.isEmpty)
    return bridge.TypstCompileResult(pages: [], diagnostics: []);

  final settings = ref.watch(settingsProvider);
  final svgMap = ref.watch(handwritingSvgMapProvider);

  // watch を使うことで、ファイル切り替え時にこのプロバイダー自体が再評価されるようにする
  final currentFile = ref.watch(currentTypFileProvider);
  final fileNameNoExt = currentFile != null
      ? p.basenameWithoutExtension(currentFile.path)
      : 'figures';

  final fullContent = buildPreamble(settings.activeFont) + userContent;
  final extraFiles = <bridge.ExtraFile>[];

  // Add custom fonts
  final notebookDir = ref.read(notebookPathProvider);
  for (final relPath in settings.customFontPaths) {
    try {
      final absolutePath =
          notebookDir != null ? p.join(notebookDir.path, relPath) : relPath;
      final file = File(absolutePath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        extraFiles
            .add(bridge.ExtraFile(name: p.basename(absolutePath), data: bytes));
      }
    } catch (e) {
      debugPrint('Error loading font $relPath: $e');
    }
  }

  // 手書きデータを仮想ファイルシステムに追加
  svgMap.forEach((id, svg) {
    // 仮想パスを "現在のファイル名/図形ID.svg" に設定
    // これにより Typst 内の image("ファイル名/ID.svg") と一致する
    final virtualPath = '$fileNameNoExt/$id.svg';
    extraFiles.add(bridge.ExtraFile(
        name: virtualPath, data: Uint8List.fromList(svg.codeUnits)));
  });

  // ディスク上の画像ファイルもスキャンして追加 (貼り付けたPNGなど)
  if (currentFile != null) {
    try {
      final targetDir =
          Directory(p.join(currentFile.parent.path, fileNameNoExt));
      if (await targetDir.exists()) {
        await for (final entity in targetDir.list()) {
          if (entity is File) {
            final ext = p.extension(entity.path).toLowerCase();
            if (['.png', '.jpg', '.jpeg', '.svg'].contains(ext)) {
              final bytes = await entity.readAsBytes();
              final virtualPath = '$fileNameNoExt/${p.basename(entity.path)}';
              // 重複を避ける (メモリ上のSVGを優先)
              if (!extraFiles.any((f) => f.name == virtualPath)) {
                extraFiles
                    .add(bridge.ExtraFile(name: virtualPath, data: bytes));
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error scanning figures directory: $e');
    }
  }

  if (extraFiles.isEmpty && settings.customFontPaths.isEmpty) {
    extraFiles.add(bridge.ExtraFile(
        name: 'figures/dummy.svg',
        data: Uint8List.fromList(
            '<svg xmlns="http://www.w3.org/2000/svg"/>'.codeUnits)));
  }

  final result =
      await bridge.compileTypst(content: fullContent, extraFiles: extraFiles);

  // Adjust line numbers for preamble
  final preamble = buildPreamble(settings.activeFont);
  final preambleLineCount =
      preamble.split('\n').length - 1; // Number of newlines in preamble

  final adjustedDiagnostics = result.diagnostics.map((diag) {
    return bridge.TypstDiagnostic(
      message: diag.message,
      line: (diag.line - preambleLineCount).clamp(0, 1000000),
      column: diag.column,
      severity: diag.severity,
    );
  }).toList();

  // 以前の診断情報のバージョン管理のために、ここで provider 自体が完了したときに
  // versionedDiagnosticsProvider を更新する。
  Future.microtask(() {
    ref.read(versionedDiagnosticsProvider.notifier).state =
        VersionedDiagnostics(
      version: currentVersion,
      items: adjustedDiagnostics,
    );
  });

  return result;
});

// --- Persistence Management ---

class PersistenceManager {
  final Ref ref;
  Timer? _typstSaveTimer;
  Timer? _settingsSaveTimer;
  String? _lastSavedContent;

  // Robust state management
  String? _lastSavedPath;
  int _currentVersion = 0;
  final Map<String, int> _lastCommittedVersions = {};
  Future<void> _saveQueue = Future.value();

  PersistenceManager(this.ref);

  void updateLastSavedContent(String content, {String? path}) {
    _lastSavedContent = content;
    if (path != null) {
      _lastSavedPath = path;
      // When loading a file, we treat its initial state as committed version 0
      _lastCommittedVersions[path] = 0;
      _currentVersion = 0;
    }
  }

  Future<void> saveTypst(String content,
      {int? version, String? targetPath}) async {
    final currentFile = ref.read(currentTypFileProvider);
    if (currentFile == null) return;

    final path = targetPath ?? currentFile.path;
    final reqVersion = version ?? _currentVersion;

    // Mutex: Serialize I/O using a Future chain
    _saveQueue = _saveQueue.then((_) async {
      try {
        debugPrint('[SAVE] Attempting to save v$reqVersion for path: $path');
        debugPrint('[SAVE] Content length: ${content.length}');
        debugPrint('[SAVE] _lastSavedPath: $_lastSavedPath');
        debugPrint(
            '[SAVE] _lastSavedContent size: ${_lastSavedContent?.length}');

        // 1. Path check: Ensure we are still editing the same file
        final activePath = ref.read(currentTypFileProvider)?.path;
        if (activePath != path) {
          debugPrint('[SAVE] DISCARDED: Path mismatch ($path vs $activePath)');
          return;
        }

        // 2. Monotonic version check: Discard stale updates
        final lastCommitted = _lastCommittedVersions[path] ?? -1;
        if (reqVersion <= lastCommitted) {
          debugPrint(
              '[SAVE] DISCARDED: Stale version ($reqVersion <= $lastCommitted)');
          return;
        }

        // 3. Content change check
        if (content == _lastSavedContent && _lastSavedPath == path) {
          debugPrint('[SAVE] SKIPPED: Content identical');
          return;
        }

        // 4. Empty overwrite safeguard: EXTREME VERSION
        // If content is empty but file is NOT supposed to be empty (or we don't know yet)
        if (content.isEmpty && _lastSavedPath == path) {
          debugPrint(
              '[SAVE] BLOCKED: Extreme empty safeguard triggered for $path');
          return;
        }

        // 5. Atomic Write (Temp -> Rename)
        final tmpFile = File('$path.tmp');
        await tmpFile.writeAsString(content);
        await tmpFile.rename(path);

        _lastSavedContent = content;
        _lastSavedPath = path;
        _lastCommittedVersions[path] = reqVersion;
        debugPrint('[SAVE] SUCCESS: v$reqVersion to $path');
      } catch (e) {
        debugPrint('[SAVE] FAILED: $e');
      }
    });

    return _saveQueue;
  }

  Future<void> saveFigure(String id, String svg, String json,
      {String? targetDir}) async {
    final root = ref.read(notebookPathProvider);
    if (root == null) return;

    // targetDir が指定されていない場合は、デフォルトの figures/ を使用
    final Directory figuresDir;
    if (targetDir != null) {
      figuresDir = Directory(targetDir);
    } else {
      figuresDir = Directory(p.join(root.path, 'figures'));
    }

    if (!await figuresDir.exists()) await figuresDir.create(recursive: true);

    await File(p.join(figuresDir.path, '$id.svg')).writeAsString(svg);
    await File(p.join(figuresDir.path, '$id.json')).writeAsString(json);
    debugPrint('Saved Figure $id to ${figuresDir.path}');
  }

  Future<void> saveSettings(AppSettings settings) async {
    final dir = ref.read(notebookPathProvider);
    if (dir == null) return;

    final file = File(p.join(dir.path, 'settings.json'));
    await file.writeAsString(jsonEncode(settings.toJson()));
    debugPrint('Saved settings to disk');
  }

  Future<String?> copyFontToNotebook(String sourcePath) async {
    final dir = ref.read(notebookPathProvider);
    if (dir == null) return null;

    final fontsDir = Directory(p.join(dir.path, 'fonts'));
    if (!await fontsDir.exists()) await fontsDir.create(recursive: true);

    final fileName = p.basename(sourcePath);
    final relativePath = p.join('fonts', fileName);
    final targetPath = p.join(dir.path, relativePath);

    await File(sourcePath).copy(targetPath);
    return relativePath;
  }

  Future<void> loadNotebook(Directory dir) async {
    ref.read(notebookPathProvider.notifier).state = dir;

    // 内容の読み込みは、FileTree 経由で各 .typ ファイルが選択された時にのみ行われるように変更。
    // 起動時に特定のファイルを強制的に開くことはしない。

    // Load figures from all folders named like .typ files
    final notifier = ref.read(handwritingProvider.notifier);
    try {
      await for (final entity in dir.list()) {
        if (entity is Directory) {
          final folderName = p.basename(entity.path);
          // もし対応する .typ ファイルが存在するフォルダなら
          if (await File(p.join(dir.path, '$folderName.typ')).exists()) {
            await for (final file in entity.list()) {
              if (file is File && file.path.endsWith('.json')) {
                final jsonStr = await file.readAsString();
                notifier.fromJson(jsonStr);
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to load figures: $e');
    }

    // Load settings.json
    final settingsFile = File(p.join(dir.path, 'settings.json'));
    if (await settingsFile.exists()) {
      try {
        final json = jsonDecode(await settingsFile.readAsString());
        ref.read(settingsProvider.notifier).state = AppSettings.fromJson(json);
        debugPrint('Loaded settings from disk');
      } catch (e) {
        debugPrint('Failed to load settings: $e');
      }
    }
  }

  void setupAutoSave() {
    // Typst 内容の自動保存 (ディスク保存は3秒間隔に抑える)
    ref.listen(rawContentProvider, (previous, next) {
      // 世代（Version）をインクリメント
      ref.read(contentVersionProvider.notifier).update((v) => v + 1);
      final targetVersion = ref.read(contentVersionProvider);

      final currentFile = ref.read(currentTypFileProvider);
      if (currentFile == null) return;
      final targetPath = currentFile.path;

      _typstSaveTimer?.cancel();
      _typstSaveTimer = Timer(const Duration(seconds: 3), () {
        // 保存実行直前に現在の世代を確認。もし新しくなっていればこの保存は無効（Stale）。
        final currentVersion = ref.read(contentVersionProvider);
        if (targetVersion != currentVersion) {
          debugPrint(
              '[AUTOSAVE] Stale generation detected. Aborting save (target: $targetVersion, current: $currentVersion)');
          return;
        }

        saveTypst(next, version: targetVersion, targetPath: targetPath);
      });
    });
    // 設定の自動保存
    ref.listen(settingsProvider, (previous, next) {
      saveSettings(next);
    });
  }

  Future<void> flush() async {
    final content = ref.read(debouncedContentProvider);
    final currentFile = ref.read(currentTypFileProvider);
    if (currentFile != null) {
      await saveTypst(content);
    }
  }
}

final persistenceProvider = Provider((ref) {
  final manager = PersistenceManager(ref);
  manager.setupAutoSave();
  return manager;
});
