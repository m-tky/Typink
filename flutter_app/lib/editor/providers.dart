import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:typed_data';
import 'package:vector_math/vector_math_64.dart' hide Colors;
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

enum DrawingTool { pen, eraser, lasso }

/// 手書きの全体状態を保持するクラス
class HandwritingState {
  final Map<String, List<Stroke>> figures;
  final Map<String, Set<int>> selectedIndices;
  final Map<String, Matrix4?> activeTransforms;

  const HandwritingState({
    this.figures = const {},
    this.selectedIndices = const {},
    this.activeTransforms = const {},
  });

  HandwritingState copyWith({
    Map<String, List<Stroke>>? figures,
    Map<String, Set<int>>? selectedIndices,
    Map<String, Matrix4?>? activeTransforms,
  }) {
    return HandwritingState(
      figures: figures ?? this.figures,
      selectedIndices: selectedIndices ?? this.selectedIndices,
      activeTransforms: activeTransforms ?? this.activeTransforms,
    );
  }
}

/// 手書きの状態を管理する Notifier (複数図形対応)
class HandwritingNotifier extends StateNotifier<HandwritingState> {
  // 消しゴムの反応しきい値 (1333x1000 ローカル単位)
  static const double eraserTolerance = 20.0;

  // .json ファイルが存在するかどうかのフラグ (再編集可能か)
  final Map<String, bool> _editableMap = {};
  Map<String, bool> get editableMap => _editableMap;

  HandwritingNotifier() : super(const HandwritingState());

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
      // Trigger update
      state = state.copyWith();
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
      final currentList = List<Stroke>.from(state.figures[figureId] ?? []);
      _undoStacks[figureId] ??= [];
      _undoStacks[figureId]!.add(currentList);
      
      final newList = [...currentList, _currentStroke!];
      state = state.copyWith(
        figures: {...state.figures, figureId: newList},
      );
      
      _redoStacks[figureId] = [];
      _currentStroke = null;
    }
  }

  void undo(String figureId) {
    final stack = _undoStacks[figureId];
    if (stack != null && stack.isNotEmpty) {
      final currentList = List<Stroke>.from(state.figures[figureId] ?? []);
      _redoStacks[figureId] ??= [];
      _redoStacks[figureId]!.add(currentList);

      final previousFigures = stack.removeLast();
      state = state.copyWith(
        figures: {...state.figures, figureId: previousFigures},
        selectedIndices: {...state.selectedIndices, figureId: {}}, // Clear selection on undo
      );
    }
  }

  void redo(String figureId) {
    final stack = _redoStacks[figureId];
    if (stack != null && stack.isNotEmpty) {
      final currentList = List<Stroke>.from(state.figures[figureId] ?? []);
      _undoStacks[figureId] ??= [];
      _undoStacks[figureId]!.add(currentList);

      final nextFigures = stack.removeLast();
      state = state.copyWith(
        figures: {...state.figures, figureId: nextFigures},
      );
    }
  }

  void clear(String figureId) {
    final currentList = List<Stroke>.from(state.figures[figureId] ?? []);
    if (currentList.isNotEmpty) {
      _undoStacks[figureId] ??= [];
      _undoStacks[figureId]!.add(currentList);
      _redoStacks[figureId] = [];
      state = state.copyWith(
        figures: {...state.figures, figureId: []},
        selectedIndices: {...state.selectedIndices, figureId: {}},
      );
    }
  }

  String toJson() {
    final Map<String, dynamic> data = {};
    state.figures.forEach((id, strokes) {
      data[id] = strokes.map((s) => s.toJson()).toList();
    });
    return jsonEncode(data);
  }

  void fromJson(String source) {
    try {
      final Map<String, dynamic> data = jsonDecode(source);
      final Map<String, List<Stroke>> newFigures = Map.from(state.figures);
      data.forEach((id, strokesJson) {
        newFigures[id] = (strokesJson as List).map((s) => Stroke.fromJson(s)).toList();
        _editableMap[id] = true;
      });
      state = state.copyWith(figures: newFigures);
    } catch (e) {
      debugPrint('Failed to load strokes: $e');
    }
  }

  void markAsReadOnly(String figureId) {
    _editableMap[figureId] = false;
    state = state.copyWith();
  }

  bool isEditable(String figureId) => _editableMap[figureId] ?? true;

  void selectStrokesInPath(String figureId, List<Offset> lassoPoints, Size canvasSize) {
    if (lassoPoints.length < 3) return;

    final normalizedLasso = lassoPoints.map((p) => Offset(
      p.dx / canvasSize.width * canvasWidth,
      p.dy / canvasSize.height * canvasHeight,
    )).toList();

    final path = Path();
    path.moveTo(normalizedLasso.first.dx, normalizedLasso.first.dy);
    for (final p in normalizedLasso.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    path.close();

    final lassoRect = path.getBounds();
    final strokes = state.figures[figureId] ?? [];
    final selected = <int>{};

    for (int i = 0; i < strokes.length; i++) {
        final stroke = strokes[i];
        if (stroke.points.isEmpty) continue;

        // BBox optimization
        final strokeRect = _getStrokeBounds(stroke);
        if (!lassoRect.overlaps(strokeRect)) continue;

        // Detailed check
        bool anyPointInside = false;
        for (final p in stroke.points) {
          if (path.contains(p)) {
            anyPointInside = true;
            break;
          }
        }
        if (anyPointInside) {
          selected.add(i);
        }
    }

    state = state.copyWith(
      selectedIndices: {...state.selectedIndices, figureId: selected},
    );
  }

  Rect _getStrokeBounds(Stroke stroke) {
    if (stroke.points.isEmpty) return Rect.zero;
    double minX = stroke.points.first.dx;
    double minY = stroke.points.first.dy;
    double maxX = stroke.points.first.dx;
    double maxY = stroke.points.first.dy;
    for (final p in stroke.points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  void updateActiveTransform(String figureId, Matrix4? transform) {
    state = state.copyWith(
      activeTransforms: {...state.activeTransforms, figureId: transform},
    );
  }

  void commitTransform(String figureId) {
    final transform = state.activeTransforms[figureId];
    final selected = state.selectedIndices[figureId];
    if (transform == null || selected == null || selected.isEmpty) return;

    final currentFigures = List<Stroke>.from(state.figures[figureId] ?? []);
    _undoStacks[figureId] ??= [];
    _undoStacks[figureId]!.add(List<Stroke>.from(currentFigures));

    final newFigures = List<Stroke>.from(currentFigures);
    for (final index in selected) {
      final stroke = newFigures[index];
      final transformedPoints = stroke.points.map((p) {
        final vec = Vector3(p.dx, p.dy, 0);
        final tVec = transform.transform3(vec);
        return Offset(tVec.x, tVec.y);
      }).toList();
      newFigures[index] = stroke.copyWith(points: transformedPoints);
    }

    state = state.copyWith(
      figures: {...state.figures, figureId: newFigures},
      activeTransforms: {...state.activeTransforms, figureId: null},
    );
    _redoStacks[figureId] = [];
  }

  void clearSelection(String figureId) {
    state = state.copyWith(
      selectedIndices: {...state.selectedIndices, figureId: {}},
      activeTransforms: {...state.activeTransforms, figureId: null},
    );
  }

  void eraseAt(Offset point, Size canvasSize, String figureId, {double eraserWidth = 30.0}) {
    final normalizedPoint = Offset(
      point.dx / canvasSize.width * canvasWidth,
      point.dy / canvasSize.height * canvasHeight,
    );

    final currentList = state.figures[figureId];
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
      state = state.copyWith(
        figures: {...state.figures, figureId: newList},
        selectedIndices: {...state.selectedIndices, figureId: {}}, // Clear selection if something erased
      );
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
    final strokes = state.figures[figureId];
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
    final strokes = state.figures[figureId];
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

final activeFigureIdProvider = StateProvider<String?>((ref) => null);

final currentPageProvider = StateProvider<int>((ref) => 0);

/// エディタの現在のドキュメントバージョン (非同期同期用)
final docVersionProvider = StateProvider<int>((ref) => 0);

/// バージョン付きの診断情報
class VersionedDiagnostics {
  final int version;
  final List<bridge.TypstDiagnostic> items;

  VersionedDiagnostics({required this.version, required this.items});
  
  static VersionedDiagnostics empty() => VersionedDiagnostics(version: -1, items: []);
}

/// 最終入力時刻 (タイピング判定用)
final lastInputTimeProvider = StateProvider<DateTime>((ref) => DateTime.now());

/// IMEが組成中かどうか
final isComposingProvider = StateProvider<bool>((ref) => false);

/// 最新の診断情報（バージョン付き）
final versionedDiagnosticsProvider = StateProvider<VersionedDiagnostics>((ref) => VersionedDiagnostics.empty());

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
final splitOrientationProvider = StateProvider<SplitMode>((ref) => SplitMode.horizontal);
final splitRatioProvider = StateProvider<double>((ref) => 0.5);

enum ToolbarPosition { top, bottom, left, right }

const List<Color> defaultPalette = [
  Colors.black,
  Colors.red,
  Colors.blue,
  Colors.green,
  Color(0xFFF57C00), // Colors.orange[700]
  Colors.purple,
];

enum AppThemeMode {
  light,
  dark,
  catppuccin,
  oneDark,
  nightfox,
}

class AppSettings {
  final ToolbarPosition toolbarPosition;
  final List<Color> palette;
  final List<String> customFontPaths; // Relative paths to notebook dir
  final String activeFont;
  final String editorFont;
  final bool horizontalPreview;
  final bool relativeLineNumbers;
  final bool showWhitespace;
  final bool vimEnabled;
  final double fontSize;
  final AppThemeMode theme;

  const AppSettings({
    this.toolbarPosition = ToolbarPosition.bottom,
    this.palette = defaultPalette,
    this.customFontPaths = const [],
    this.activeFont = 'IBM Plex Sans',
    this.editorFont = 'Moralerspace Argon',
    this.horizontalPreview = false,
    this.relativeLineNumbers = false,
    this.showWhitespace = false,
    this.vimEnabled = true,
    this.fontSize = 14.0,
    this.theme = AppThemeMode.dark,
  });

  Map<String, dynamic> toJson() => {
    'toolbarPosition': toolbarPosition.index,
    'palette': palette.map((c) => c.value).toList(),
    'customFontPaths': customFontPaths,
    'activeFont': activeFont,
    'editorFont': editorFont,
    'horizontalPreview': horizontalPreview,
    'relativeLineNumbers': relativeLineNumbers,
    'showWhitespace': showWhitespace,
    'vimEnabled': vimEnabled,
    'fontSize': fontSize,
    'theme': theme.index,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    String font = json['activeFont'] ?? 'IBM Plex Sans';
    String eFont = json['editorFont'] ?? 'Moralerspace Argon';
    
    return AppSettings(
      toolbarPosition: ToolbarPosition.values[(json['toolbarPosition'] ?? 1).clamp(0, ToolbarPosition.values.length - 1)],
      palette: (json['palette'] as List?)?.map((v) => Color(v as int)).toList() ?? defaultPalette,
      customFontPaths: (json['customFontPaths'] as List?)?.cast<String>() ?? const [],
      activeFont: font,
      editorFont: eFont,
      horizontalPreview: json['horizontalPreview'] ?? false,
      relativeLineNumbers: json['relativeLineNumbers'] ?? false,
      showWhitespace: json['showWhitespace'] ?? false,
      vimEnabled: json['vimEnabled'] ?? true,
      fontSize: (json['fontSize'] ?? 14.0).toDouble(),
      theme: AppThemeMode.values[(json['theme'] ?? AppThemeMode.dark.index).clamp(0, AppThemeMode.values.length - 1)],
    );
  }

  AppSettings copyWith({
    ToolbarPosition? toolbarPosition,
    List<Color>? palette,
    List<String>? customFontPaths,
    String? activeFont,
    String? editorFont,
    bool? horizontalPreview,
    bool? relativeLineNumbers,
    bool? showWhitespace,
    bool? vimEnabled,
    double? fontSize,
    AppThemeMode? theme,
  }) {
    return AppSettings(
      toolbarPosition: toolbarPosition ?? this.toolbarPosition,
      palette: palette ?? this.palette,
      customFontPaths: customFontPaths ?? this.customFontPaths,
      activeFont: activeFont ?? this.activeFont,
      editorFont: editorFont ?? this.editorFont,
      horizontalPreview: horizontalPreview ?? this.horizontalPreview,
      relativeLineNumbers: relativeLineNumbers ?? this.relativeLineNumbers,
      showWhitespace: showWhitespace ?? this.showWhitespace,
      vimEnabled: vimEnabled ?? this.vimEnabled,
      fontSize: fontSize ?? this.fontSize,
      theme: theme ?? this.theme,
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
  void setEditorFont(String font) => state = state.copyWith(editorFont: font);
  void toggleHorizontalPreview() => state = state.copyWith(horizontalPreview: !state.horizontalPreview);
  void toggleRelativeLineNumbers() => state = state.copyWith(relativeLineNumbers: !state.relativeLineNumbers);
  void toggleShowWhitespace() => state = state.copyWith(showWhitespace: !state.showWhitespace);
  void toggleVimEnabled() => state = state.copyWith(vimEnabled: !state.vimEnabled);
  void setFontSize(double size) => state = state.copyWith(fontSize: size);
  void setTheme(AppThemeMode theme) => state = state.copyWith(theme: theme);
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>((ref) => SettingsNotifier());

final activeToolProvider = StateProvider<DrawingTool>((ref) => DrawingTool.pen);
final activeColorProvider = StateProvider<Color>((ref) => Colors.black);
final penWidthProvider = StateProvider<double>((ref) => 3.0);
final eraserWidthProvider = StateProvider<double>((ref) => 30.0);

final handwritingCanvasSizeProvider = StateProvider<Size>((ref) => const Size(800, 1000));

final handwritingActiveProvider = Provider<bool>((ref) => ref.watch(activeFigureIdProvider) != null);

final handwritingProvider = StateNotifierProvider<HandwritingNotifier, HandwritingState>((ref) {
  return HandwritingNotifier();
});

final handwritingSvgMapProvider = Provider<Map<String, String>>((ref) {
  final drawingState = ref.watch(handwritingProvider);
  final notifier = ref.read(handwritingProvider.notifier);
  final Map<String, String> svgMap = {};
  for (final id in drawingState.figures.keys) {
    svgMap[id] = notifier.toSvg(id);
  }
  return svgMap;
});

class Snippet {
  final String prefix;
  final String body;
  final String description;

  const Snippet({required this.prefix, required this.body, required this.description});

  factory Snippet.fromJson(String prefix, Map<String, dynamic> json) {
    return Snippet(
      prefix: prefix,
      body: json['body'] as String,
      description: json['description'] as String? ?? '',
    );
  }
}

final snippetsProvider = FutureProvider<List<Snippet>>((ref) async {
  final notebookDir = ref.watch(notebookPathProvider);
  final List<Snippet> allSnippets = [];

  // 1. Load bundled snippets from assets
  try {
    final bundleJson = await rootBundle.loadString('assets/snippets.json');
    final Map<String, dynamic> data = jsonDecode(bundleJson);
    data.forEach((k, v) => allSnippets.add(Snippet.fromJson(k, v)));
  } catch (e) {
    debugPrint('No bundled snippets found: $e');
  }

  // 2. Load user snippets from notebook directory
  if (notebookDir != null) {
    try {
      final userFile = File(p.join(notebookDir.path, 'snippets.json'));
      if (await userFile.exists()) {
        final userJson = await userFile.readAsString();
        final Map<String, dynamic> data = jsonDecode(userJson);
        data.forEach((k, v) => allSnippets.add(Snippet.fromJson(k, v)));
      }
    } catch (e) {
      debugPrint('Error loading user snippets: $e');
    }
  }

  return allSnippets;
});

String buildPreamble(String font) {
  return '''#set page(width: 210mm, height: 297mm, margin: 20mm)
#set text(font: ("$font", "IBM Plex Sans JP"))
''';
}

final typstCompileResultProvider = FutureProvider<bridge.TypstCompileResult>((ref) async {
  final userContent = ref.watch(debouncedContentProvider);
  final currentVersion = ref.read(docVersionProvider);
  
  if (userContent.isEmpty) return bridge.TypstCompileResult(pages: [], diagnostics: []);
  
  final settings = ref.watch(settingsProvider);
  final svgMap = ref.watch(handwritingSvgMapProvider);
  
  // watch を使うことで、ファイル切り替え時にこのプロバイダー自体が再評価されるようにする
  final currentFile = ref.watch(currentTypFileProvider);
  final fileNameNoExt = currentFile != null ? p.basenameWithoutExtension(currentFile.path) : 'figures';
  
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

  // 手書きデータを仮想ファイルシステムに追加
  svgMap.forEach((id, svg) {
    // 仮想パスを "現在のファイル名/図形ID.svg" に設定
    // これにより Typst 内の image("ファイル名/ID.svg") と一致する
    final virtualPath = '$fileNameNoExt/$id.svg';
    extraFiles.add(bridge.ExtraFile(name: virtualPath, data: Uint8List.fromList(svg.codeUnits)));
  });

  // ディスク上の画像ファイルもスキャンして追加 (貼り付けたPNGなど)
  if (currentFile != null) {
    try {
      final targetDir = Directory(p.join(currentFile.parent.path, fileNameNoExt));
      if (await targetDir.exists()) {
        await for (final entity in targetDir.list()) {
          if (entity is File) {
            final ext = p.extension(entity.path).toLowerCase();
            if (['.png', '.jpg', '.jpeg', '.svg'].contains(ext)) {
              final bytes = await entity.readAsBytes();
              final virtualPath = '$fileNameNoExt/${p.basename(entity.path)}';
              // 重複を避ける (メモリ上のSVGを優先)
              if (!extraFiles.any((f) => f.name == virtualPath)) {
                extraFiles.add(bridge.ExtraFile(name: virtualPath, data: bytes));
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
    extraFiles.add(bridge.ExtraFile(name: 'figures/dummy.svg', data: Uint8List.fromList('<svg xmlns="http://www.w3.org/2000/svg"/>'.codeUnits)));
  }
  
  final result = await bridge.compileTypst(content: fullContent, extraFiles: extraFiles);
  
  // Adjust line numbers for preamble
  final preamble = buildPreamble(settings.activeFont);
  final preambleLineCount = preamble.split('\n').length - 1; // Number of newlines in preamble

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
    ref.read(versionedDiagnosticsProvider.notifier).state = VersionedDiagnostics(
      version: currentVersion,
      items: adjustedDiagnostics,
    );
  });

  return result;
});

// documentTitleProvider replaced above

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

  Future<void> saveTypst(String content, {int? version, String? targetPath}) async {
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
        debugPrint('[SAVE] _lastSavedContent size: ${_lastSavedContent?.length}');

        // 1. Path check: Ensure we are still editing the same file
        final activePath = ref.read(currentTypFileProvider)?.path;
        if (activePath != path) {
           debugPrint('[SAVE] DISCARDED: Path mismatch ($path vs $activePath)');
           return;
        }

        // 2. Monotonic version check: Discard stale updates
        final lastCommitted = _lastCommittedVersions[path] ?? -1;
        if (reqVersion <= lastCommitted) {
           debugPrint('[SAVE] DISCARDED: Stale version ($reqVersion <= $lastCommitted)');
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
           debugPrint('[SAVE] BLOCKED: Extreme empty safeguard triggered for $path');
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

  Future<void> saveFigure(String id, String svg, String json, {String? targetDir}) async {
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
           debugPrint('[AUTOSAVE] Stale generation detected. Aborting save (target: $targetVersion, current: $currentVersion)');
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

final persistenceProvider = Provider((ref) => PersistenceManager(ref));
