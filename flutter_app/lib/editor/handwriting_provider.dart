import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;
import 'dart:convert';
import 'dart:io';

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
      points:
          (json['points'] as List).map((p) => Offset(p['x'], p['y'])).toList(),
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
  final Map<String, String> svgCache;

  const HandwritingState({
    this.figures = const {},
    this.selectedIndices = const {},
    this.activeTransforms = const {},
    this.svgCache = const {},
  });

  HandwritingState copyWith({
    Map<String, List<Stroke>>? figures,
    Map<String, Set<int>>? selectedIndices,
    Map<String, Matrix4?>? activeTransforms,
    Map<String, String>? svgCache,
  }) {
    return HandwritingState(
      figures: figures ?? this.figures,
      selectedIndices: selectedIndices ?? this.selectedIndices,
      activeTransforms: activeTransforms ?? this.activeTransforms,
      svgCache: svgCache ?? this.svgCache,
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
      final newPoints = List<Offset>.from(_currentStroke!.points)
        ..add(normalizedPoint);
      _currentStroke = _currentStroke!.copyWith(points: newPoints);
      // Trigger update (does NOT touch svgCache to avoid unnecessary SVG rebuilds)
      state = state.copyWith();
    }
  }

  void startStroke(Offset point, Size canvasSize,
      {required Color color, required double width}) {
    final normalizedPoint = Offset(
      point.dx / canvasSize.width * canvasWidth,
      point.dy / canvasSize.height * canvasHeight,
    );
    _currentStroke =
        Stroke(points: [normalizedPoint], color: color, strokeWidth: width);
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
      _updateSvgCache(figureId);
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
        selectedIndices: {
          ...state.selectedIndices,
          figureId: {}
        }, // Clear selection on undo
      );
      _updateSvgCache(figureId);
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
      _updateSvgCache(figureId);
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
      _updateSvgCache(figureId);
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
      final Map<String, String> newSvgCache = Map.from(state.svgCache);
      data.forEach((id, strokesJson) {
        newFigures[id] =
            (strokesJson as List).map((s) => Stroke.fromJson(s)).toList();
        _editableMap[id] = true;
        newSvgCache[id] = _computeSvg(id, newFigures[id]!);
      });
      state = state.copyWith(figures: newFigures, svgCache: newSvgCache);
    } catch (e) {
      debugPrint('Failed to load strokes: $e');
    }
  }

  void markAsReadOnly(String figureId) {
    _editableMap[figureId] = false;
    state = state.copyWith();
  }

  bool isEditable(String figureId) => _editableMap[figureId] ?? true;

  void selectStrokesInPath(
      String figureId, List<Offset> lassoPoints, Size canvasSize) {
    if (lassoPoints.length < 3) return;

    final normalizedLasso = lassoPoints
        .map((p) => Offset(
              p.dx / canvasSize.width * canvasWidth,
              p.dy / canvasSize.height * canvasHeight,
            ))
        .toList();

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
    _updateSvgCache(figureId);
  }

  void clearSelection(String figureId) {
    state = state.copyWith(
      selectedIndices: {...state.selectedIndices, figureId: {}},
      activeTransforms: {...state.activeTransforms, figureId: null},
    );
  }

  void eraseAt(Offset point, Size canvasSize, String figureId,
      {double eraserWidth = 30.0}) {
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
        selectedIndices: {
          ...state.selectedIndices,
          figureId: {}
        }, // Clear selection if something erased
      );
      _redoStacks[figureId] = [];
      _updateSvgCache(figureId);
    }
  }

  bool _isPointNearStroke(Offset p, Stroke stroke, double eraserWidth) {
    if (stroke.points.isEmpty) return false;
    for (int i = 0; i < stroke.points.length - 1; i++) {
      if (_distPointToSegment(p, stroke.points[i], stroke.points[i + 1]) <
          (stroke.strokeWidth / 2 + eraserWidth / 2)) {
        return true;
      }
    }
    return false;
  }

  double _distPointToSegment(Offset p, Offset a, Offset b) {
    final double l2 =
        (a.dx - b.dx) * (a.dx - b.dx) + (a.dy - b.dy) * (a.dy - b.dy);
    if (l2 == 0.0)
      return (p.dx - a.dx) * (p.dx - a.dx) + (p.dy - a.dy) * (p.dy - a.dy);
    double t =
        ((p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy)) / l2;
    t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
    final Offset projection =
        Offset(a.dx + t * (b.dx - a.dx), a.dy + t * (b.dy - a.dy));
    return (p.dx - projection.dx).abs() +
        (p.dy - projection.dy).abs(); // Simplified L1 for speed, or sqrt for L2
  }

  /// Computes the SVG string for [figureId] from the given [strokes] list,
  /// without reading or writing [state]. Used internally for cache updates.
  String _computeSvg(String figureId, List<Stroke> strokes) {
    if (strokes.isEmpty) return '';

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
    buffer.writeln(
        '<svg viewBox="$normMinX $normMinY $width $height" width="$width" height="$height" xmlns="http://www.w3.org/2000/svg">');
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final colorHex =
          '#${stroke.color.value.toRadixString(16).padLeft(8, '0').substring(2)}';

      buffer.write(
          '  <path d="M ${stroke.points.first.dx} ${stroke.points.first.dy} ');
      for (int i = 1; i < stroke.points.length; i++) {
        buffer.write('L ${stroke.points[i].dx} ${stroke.points[i].dy} ');
      }
      buffer.writeln(
          '" fill="none" stroke="$colorHex" stroke-width="${stroke.strokeWidth}" stroke-linecap="round" stroke-linejoin="round" />');
    }
    buffer.writeln('</svg>');
    return buffer.toString();
  }

  /// Updates [state.svgCache] for [figureId] using the current [state.figures].
  void _updateSvgCache(String figureId) {
    final svg = _computeSvg(figureId, state.figures[figureId] ?? []);
    state = state.copyWith(
      svgCache: {...state.svgCache, figureId: svg},
    );
  }

  /// Returns the cached SVG for [figureId], or an empty string if not cached.
  String toSvg(String figureId) {
    return state.svgCache[figureId] ?? '';
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

final activeFigureIdProvider = StateProvider<String?>((ref) => null);

final activeToolProvider = StateProvider<DrawingTool>((ref) => DrawingTool.pen);
final activeColorProvider = StateProvider<Color>((ref) => Colors.black);
final penWidthProvider = StateProvider<double>((ref) => 3.0);
final eraserWidthProvider = StateProvider<double>((ref) => 30.0);

final handwritingCanvasSizeProvider =
    StateProvider<Size>((ref) => const Size(800, 1000));

final handwritingActiveProvider =
    Provider<bool>((ref) => ref.watch(activeFigureIdProvider) != null);

final handwritingProvider =
    StateNotifierProvider<HandwritingNotifier, HandwritingState>((ref) {
  return HandwritingNotifier();
});

/// Returns the cached SVG map from [HandwritingState.svgCache].
/// Only rebuilds when a stroke operation finishes (endStroke, undo, redo,
/// clear, commitTransform, eraseAt, fromJson) — not on every pointer move.
final handwritingSvgMapProvider = Provider<Map<String, String>>((ref) {
  return ref.watch(handwritingProvider).svgCache;
});

const List<Color> defaultPalette = [
  Colors.black,
  Colors.red,
  Colors.blue,
  Colors.green,
  Color(0xFFF57C00), // Colors.orange[700]
  Colors.purple,
];
