import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../frb_generated.dart/api.dart' as bridge;
import '../frb_generated.dart/frb_generated.dart';

/// 1つの筆跡（線）を表現するクラス
class Stroke {
  final List<Offset> points;
  final Color color;
  final double strokeWidth;

  Stroke({
    required this.points,
    this.color = Colors.black,
    this.strokeWidth = 3.0,
  });

  Stroke copyWith({List<Offset>? points}) {
    return Stroke(
      points: points ?? this.points,
      color: color,
      strokeWidth: strokeWidth,
    );
  }

  Map<String, dynamic> toJson() => {
    'points': points.map((p) => {'x': p.dx, 'y': p.dy}).toList(),
    'color': color.value,
    'width': strokeWidth,
  };

  factory Stroke.fromJson(Map<String, dynamic> json) {
    return Stroke(
      points: (json['points'] as List).map((p) => Offset(p['x'], p['y'])).toList(),
      color: Color(json['color']),
      strokeWidth: json['width'].toDouble(),
    );
  }
}

enum DrawingTool { pen, eraser }

/// 手書きの状態を管理する Notifier (複数図形対応)
class HandwritingNotifier extends StateNotifier<Map<String, List<Stroke>>> {
  // 消しゴムの反応しきい値 (1333x1000 ローカル単位)
  static const double eraserTolerance = 20.0;

  // .json ファイルが存在するかどうかのフラグ (再編集可能か)
  final Map<String, bool> _editableMap = {};
  Map<String, bool> get editableMap => _editableMap;

  HandwritingNotifier() : super({});

  // 1333 x 1000 units (4:3)
  static const double canvasWidth = 1333.0;
  static const double canvasHeight = 1000.0;

  // 履歴管理用 (ID 単位)
  final Map<String, List<List<Stroke>>> _undoStacks = {};
  final Map<String, List<List<Stroke>>> _redoStacks = {};
  
  Stroke? _currentStroke;
  Stroke? get currentStroke => _currentStroke;

  void updateStroke(Offset point, Size canvasSize) {
    if (_currentStroke != null) {
      final normalizedPoint = Offset(
        point.dx / canvasSize.width * canvasWidth,
        point.dy / canvasSize.height * canvasHeight,
      );
      final newPoints = List<Offset>.from(_currentStroke!.points)..add(normalizedPoint);
      _currentStroke = _currentStroke!.copyWith(points: newPoints);
      state = {...state};
    }
  }

  void startStroke(Offset point, Size canvasSize, {required Color color, required double width}) {
    final normalizedPoint = Offset(
      point.dx / canvasSize.width * canvasWidth,
      point.dy / canvasSize.height * canvasHeight,
    );
    _currentStroke = Stroke(points: [normalizedPoint], color: color, strokeWidth: width);
  }

  void endStroke(String figureId) {
    if (_currentStroke != null) {
      if (_currentStroke!.points.length < 2) {
        _currentStroke = null;
        return;
      }
      final currentList = List<Stroke>.from(state[figureId] ?? []);
      _undoStacks[figureId] ??= [];
      _undoStacks[figureId]!.add(currentList);
      
      final newList = [...currentList, _currentStroke!];
      state = {...state, figureId: newList};
      
      _redoStacks[figureId] = [];
      _currentStroke = null;
    }
  }

  void undo(String figureId) {
    final stack = _undoStacks[figureId];
    if (stack != null && stack.isNotEmpty) {
      final currentList = List<Stroke>.from(state[figureId] ?? []);
      _redoStacks[figureId] ??= [];
      _redoStacks[figureId]!.add(currentList);

      final previousState = stack.removeLast();
      state = {...state, figureId: previousState};
    }
  }

  void redo(String figureId) {
    final stack = _redoStacks[figureId];
    if (stack != null && stack.isNotEmpty) {
      final currentList = List<Stroke>.from(state[figureId] ?? []);
      _undoStacks[figureId] ??= [];
      _undoStacks[figureId]!.add(currentList);

      final nextState = stack.removeLast();
      state = {...state, figureId: nextState};
    }
  }

  void clear(String figureId) {
    final currentList = List<Stroke>.from(state[figureId] ?? []);
    if (currentList.isNotEmpty) {
      _undoStacks[figureId] ??= [];
      _undoStacks[figureId]!.add(currentList);
      _redoStacks[figureId] = [];
      state = {...state, figureId: []};
    }
  }

  String toJson() {
    final Map<String, dynamic> data = {};
    state.forEach((id, strokes) {
      data[id] = strokes.map((s) => s.toJson()).toList();
    });
    return jsonEncode(data);
  }

  void fromJson(String source) {
    try {
      final Map<String, dynamic> data = jsonDecode(source);
      final Map<String, List<Stroke>> newState = Map.from(state);
      data.forEach((id, strokesJson) {
        newState[id] = (strokesJson as List).map((s) => Stroke.fromJson(s)).toList();
        _editableMap[id] = true;
      });
      state = newState;
    } catch (e) {
      debugPrint('Failed to load strokes: $e');
    }
  }

  void markAsReadOnly(String figureId) {
    _editableMap[figureId] = false;
    state = {...state};
  }

  bool isEditable(String figureId) => _editableMap[figureId] ?? true;

  void eraseAt(Offset point, Size canvasSize, String figureId, {double eraserWidth = 30.0}) {
    final normalizedPoint = Offset(
      point.dx / canvasSize.width * canvasWidth,
      point.dy / canvasSize.height * canvasHeight,
    );

    final currentList = state[figureId];
    if (currentList == null || currentList.isEmpty) return;

    final newList = List<Stroke>.from(currentList);
    bool removed = false;

    // ヒットテスト: 点から各ストロークの各セグメントへの距離を計算
    for (int i = newList.length - 1; i >= 0; i--) {
      final stroke = newList[i];
      if (_isPointNearStroke(normalizedPoint, stroke, eraserWidth)) {
        _undoStacks[figureId] ??= [];
        _undoStacks[figureId]!.add(List<Stroke>.from(newList));
        newList.removeAt(i);
        removed = true;
        break; // 1回のタップで1つずつ消すのが自然
      }
    }

    if (removed) {
      state = {...state, figureId: newList};
      _redoStacks[figureId] = [];
    }
  }

  bool _isPointNearStroke(Offset p, Stroke stroke, double eraserWidth) {
    if (stroke.points.isEmpty) return false;
    for (int i = 0; i < stroke.points.length - 1; i++) {
      if (_distPointToSegment(p, stroke.points[i], stroke.points[i + 1]) < (stroke.strokeWidth / 2 + eraserWidth / 2)) {
        return true;
      }
    }
    return false;
  }

  double _distPointToSegment(Offset p, Offset a, Offset b) {
    final double l2 = (a.dx - b.dx) * (a.dx - b.dx) + (a.dy - b.dy) * (a.dy - b.dy);
    if (l2 == 0.0) return (p.dx - a.dx) * (p.dx - a.dx) + (p.dy - a.dy) * (p.dy - a.dy);
    double t = ((p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy)) / l2;
    t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
    final Offset projection = Offset(a.dx + t * (b.dx - a.dx), a.dy + t * (b.dy - a.dy));
    return (p.dx - projection.dx).abs() + (p.dy - projection.dy).abs(); // Simplified L1 for speed, or sqrt for L2
  }

  String toSvg(String figureId) {
    final strokes = state[figureId];
    if (strokes == null || strokes.isEmpty) return '';

    // バウンディングボックスの計算 (1333x1000 空間)
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;

    for (final stroke in strokes) {
      for (final p in stroke.points) {
        if (p.dx < minX) minX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy > maxY) maxY = p.dy;
      }
    }

    // パディングを追加してクロップ
    double padding = 10.0;
    double normMinX = minX - padding;
    double normMinY = minY - padding;
    double normMaxX = maxX + padding;
    double normMaxY = maxY + padding;

    double width = normMaxX - normMinX;
    double height = normMaxY - normMinY;

    final StringBuffer buffer = StringBuffer();
    // viewBox はコンテンツ範囲、width/height もコンテンツ実寸 (units)
    buffer.writeln('<svg viewBox="$normMinX $normMinY $width $height" width="$width" height="$height" xmlns="http://www.w3.org/2000/svg">');
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final colorHex = '#${stroke.color.value.toRadixString(16).padLeft(8, '0').substring(2)}';
      
      buffer.write('  <path d="M ${stroke.points.first.dx} ${stroke.points.first.dy} ');
      for (int i = 1; i < stroke.points.length; i++) {
        buffer.write('L ${stroke.points[i].dx} ${stroke.points[i].dy} ');
      }
      buffer.writeln('" fill="none" stroke="$colorHex" stroke-width="${stroke.strokeWidth}" stroke-linecap="round" stroke-linejoin="round" />');
    }
    buffer.writeln('</svg>');
    return buffer.toString();
  }

  double calculateRelativeWidth(String figureId) {
    final strokes = state[figureId];
    if (strokes == null || strokes.isEmpty) return 0.0;

    double minX = double.infinity;
    double maxX = double.negativeInfinity;
    for (final stroke in strokes) {
      for (final p in stroke.points) {
        if (p.dx < minX) minX = p.dx;
        if (p.dx > maxX) maxX = p.dx;
      }
    }
    return (maxX - minX) / canvasWidth;
  }
}

// --- Providers ---

final notebookPathProvider = StateProvider<Directory?>((ref) => null);

final currentTypFileProvider = StateProvider<File?>((ref) => null);

final noteNameProvider = Provider<String>((ref) {
  final file = ref.watch(currentTypFileProvider);
  if (file != null) return p.basenameWithoutExtension(file.path);
  final dir = ref.watch(notebookPathProvider);
  return dir != null ? p.basename(dir.path) : 'Untitled';
});

final rawContentProvider = StateProvider<String>((ref) => '''= Hello Typink!

This is a notebook powered by *Typst* and *Rust*.
このフォントは IBM Plex Sans (Proportional) です。

手書きとテキストが融合しています。''');

final debouncedContentProvider = StateProvider<String>((ref) => ref.read(rawContentProvider));

final activeFigureIdProvider = StateProvider<String?>((ref) => null);

enum ToolbarPosition { top, bottom, left, right }

const List<Color> defaultPalette = [
  Colors.black,
  Colors.red,
  Colors.blue,
  Colors.green,
  Color(0xFFF57C00), // Colors.orange[700]
  Colors.purple,
];

class AppSettings {
  final ToolbarPosition toolbarPosition;
  final List<Color> palette;
  final List<String> customFontPaths; // Relative paths to notebook dir
  final String activeFont;
  final bool horizontalPreview;
  final bool relativeLineNumbers;
  final bool showWhitespace;

  const AppSettings({
    this.toolbarPosition = ToolbarPosition.bottom,
    this.palette = defaultPalette,
    this.customFontPaths = const [],
    this.activeFont = 'Moralerspace Argon',
    this.horizontalPreview = false,
    this.relativeLineNumbers = false,
    this.showWhitespace = false,
  });

  Map<String, dynamic> toJson() => {
    'toolbarPosition': toolbarPosition.index,
    'palette': palette.map((c) => c.value).toList(),
    'customFontPaths': customFontPaths,
    'activeFont': activeFont,
    'horizontalPreview': horizontalPreview,
    'relativeLineNumbers': relativeLineNumbers,
    'showWhitespace': showWhitespace,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    String font = json['activeFont'] ?? 'Moralerspace Argon';
    // Migration from old names
    if (font == 'Moraler Space' || font == 'IBM Plex Sans' || font == 'Moralerspace') {
      font = 'Moralerspace Argon';
    }
    return AppSettings(
      toolbarPosition: ToolbarPosition.values[(json['toolbarPosition'] ?? 1).clamp(0, ToolbarPosition.values.length - 1)],
      palette: (json['palette'] as List?)?.map((v) => Color(v as int)).toList() ?? defaultPalette,
      customFontPaths: (json['customFontPaths'] as List?)?.cast<String>() ?? const [],
      activeFont: font,
      horizontalPreview: json['horizontalPreview'] ?? false,
      relativeLineNumbers: json['relativeLineNumbers'] ?? false,
      showWhitespace: json['showWhitespace'] ?? false,
    );
  }

  AppSettings copyWith({
    ToolbarPosition? toolbarPosition,
    List<Color>? palette,
    List<String>? customFontPaths,
    String? activeFont,
    bool? horizontalPreview,
    bool? relativeLineNumbers,
    bool? showWhitespace,
  }) {
    return AppSettings(
      toolbarPosition: toolbarPosition ?? this.toolbarPosition,
      palette: palette ?? this.palette,
      customFontPaths: customFontPaths ?? this.customFontPaths,
      activeFont: activeFont ?? this.activeFont,
      horizontalPreview: horizontalPreview ?? this.horizontalPreview,
      relativeLineNumbers: relativeLineNumbers ?? this.relativeLineNumbers,
      showWhitespace: showWhitespace ?? this.showWhitespace,
    );
  }
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier() : super(const AppSettings());

  void setToolbarPosition(ToolbarPosition pos) => state = state.copyWith(toolbarPosition: pos);
  
  void setPalette(List<Color> palette) => state = state.copyWith(palette: palette);
  void replacePaletteColor(int index, Color color) {
    final newList = List<Color>.from(state.palette);
    if (index >= 0 && index < newList.length) {
      newList[index] = color;
      state = state.copyWith(palette: newList);
    }
  }
  void resetPalette() => state = state.copyWith(palette: defaultPalette);

  void addFontPath(String relativePath) => state = state.copyWith(customFontPaths: {...state.customFontPaths, relativePath}.toList());
  void removeFontPath(String relativePath) => state = state.copyWith(customFontPaths: state.customFontPaths.where((p) => p != relativePath).toList());
  void setActiveFont(String font) => state = state.copyWith(activeFont: font);
  void toggleHorizontalPreview() => state = state.copyWith(horizontalPreview: !state.horizontalPreview);
  void toggleRelativeLineNumbers() => state = state.copyWith(relativeLineNumbers: !state.relativeLineNumbers);
  void toggleShowWhitespace() => state = state.copyWith(showWhitespace: !state.showWhitespace);
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>((ref) => SettingsNotifier());

final activeToolProvider = StateProvider<DrawingTool>((ref) => DrawingTool.pen);
final activeColorProvider = StateProvider<Color>((ref) => Colors.black);
final penWidthProvider = StateProvider<double>((ref) => 3.0);
final eraserWidthProvider = StateProvider<double>((ref) => 30.0);

final handwritingCanvasSizeProvider = StateProvider<Size>((ref) => const Size(800, 1000));

final handwritingActiveProvider = Provider<bool>((ref) => ref.watch(activeFigureIdProvider) != null);

final handwritingProvider = StateNotifierProvider<HandwritingNotifier, Map<String, List<Stroke>>>((ref) {
  return HandwritingNotifier();
});

final handwritingSvgMapProvider = Provider<Map<String, String>>((ref) {
  final stateMap = ref.watch(handwritingProvider);
  final notifier = ref.read(handwritingProvider.notifier);
  final Map<String, String> svgMap = {};
  for (final id in stateMap.keys) {
    svgMap[id] = notifier.toSvg(id);
  }
  return svgMap;
});

String buildPreamble(String font) {
  return '''#set page(width: 210mm, height: 297mm, margin: 20mm)
#set text(font: ("$font", "IBM Plex Sans JP"))
''';
}

final typstCompileResultProvider = FutureProvider<bridge.TypstCompileResult>((ref) async {
  final userContent = ref.watch(debouncedContentProvider);
  if (userContent.isEmpty) return bridge.TypstCompileResult(pages: [], errors: []);
  
  final settings = ref.watch(settingsProvider);
  final svgMap = ref.watch(handwritingSvgMapProvider);
  
  final fullContent = buildPreamble(settings.activeFont) + userContent;
  final extraFiles = <bridge.ExtraFile>[];
  
  // Add custom fonts
  final notebookDir = ref.read(notebookPathProvider);
  for (final relPath in settings.customFontPaths) {
    try {
      final absolutePath = notebookDir != null ? p.join(notebookDir.path, relPath) : relPath;
      final file = File(absolutePath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        extraFiles.add(bridge.ExtraFile(name: p.basename(absolutePath), data: bytes));
      }
    } catch (e) {
      debugPrint('Error loading font $relPath: $e');
    }
  }

  svgMap.forEach((id, svg) {
    extraFiles.add(bridge.ExtraFile(name: 'figures/$id.svg', data: Uint8List.fromList(svg.codeUnits)));
  });

  if (extraFiles.isEmpty && settings.customFontPaths.isEmpty) {
    extraFiles.add(bridge.ExtraFile(name: 'figures/dummy.svg', data: Uint8List.fromList('<svg xmlns="http://www.w3.org/2000/svg"/>'.codeUnits)));
  }
  return await bridge.compileTypst(content: fullContent, extraFiles: extraFiles);
});

final documentTitleProvider = Provider<String>((ref) {
  final file = ref.watch(currentTypFileProvider);
  if (file != null) return p.basename(file.path);
  return 'Untitled';
});

// --- Persistence Management ---

class PersistenceManager {
  final Ref ref;
  Timer? _typstSaveTimer;
  Timer? _settingsSaveTimer;

  PersistenceManager(this.ref);

  Future<void> saveTypst(String content) async {
    final dir = ref.read(notebookPathProvider);
    if (dir == null) return;
    
    final file = File(p.join(dir.path, 'main.typ'));
    await file.writeAsString(content);
    debugPrint('Saved Typst to ${file.path}');
  }

  Future<void> saveFigure(String id, String svg, String json) async {
    final dir = ref.read(notebookPathProvider);
    if (dir == null) return;

    final figuresDir = Directory(p.join(dir.path, 'figures'));
    if (!await figuresDir.exists()) await figuresDir.create(recursive: true);

    await File(p.join(figuresDir.path, '$id.svg')).writeAsString(svg);
    await File(p.join(figuresDir.path, '$id.json')).writeAsString(json);
    debugPrint('Saved Figure $id to disk');
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
    
    // Load main.typ
    final mainFile = File(p.join(dir.path, 'main.typ'));
    if (await mainFile.exists()) {
      final content = await mainFile.readAsString();
      ref.read(rawContentProvider.notifier).state = content;
      ref.read(debouncedContentProvider.notifier).state = content;
    }

    // Load figures
    final figuresDir = Directory(p.join(dir.path, 'figures'));
    if (await figuresDir.exists()) {
      final notifier = ref.read(handwritingProvider.notifier);
      await for (final file in figuresDir.list()) {
        if (file is File && file.path.endsWith('.json')) {
          final id = p.basenameWithoutExtension(file.path);
          final jsonStr = await file.readAsString();
          // id ごとに JSON を読み込む
          notifier.fromJson(jsonEncode({id: jsonDecode(jsonStr)}));
        } else if (file is File && file.path.endsWith('.svg')) {
          final id = p.basenameWithoutExtension(file.path);
          // 対応する .json がない場合は ReadOnly としてマーク (既存ロジック用)
          final jsonFile = File(p.join(figuresDir.path, '$id.json'));
          if (!await jsonFile.exists()) {
            notifier.markAsReadOnly(id);
          }
        }
      }
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
    // Typst 内容の自動保存 (500msのプレビュー更新とは別に、ディスク保存は3秒間隔に抑える)
    ref.listen(debouncedContentProvider, (previous, next) {
      _typstSaveTimer?.cancel();
      _typstSaveTimer = Timer(const Duration(seconds: 3), () {
        saveTypst(next);
      });
    });
    // 設定の自動保存
    ref.listen(settingsProvider, (previous, next) {
      saveSettings(next);
    });
  }

  Future<void> flush() async {
    final content = ref.read(debouncedContentProvider);
    await saveTypst(content);
    // 図形は保存時に書き込んでいるが、念のため全体保存も検討可
  }
}

final persistenceProvider = Provider((ref) => PersistenceManager(ref));
