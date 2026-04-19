import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:typed_data';
import 'package:vector_math/vector_math_64.dart' hide Colors;
import 'providers.dart';

/// 実際に描画を行う Painter
class HandwritingPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Set<int> selectedIndices;
  final Matrix4? activeTransform;
  final List<Offset>? lassoPoints;
  final Stroke? currentStroke;
  final Offset? cursorPosition;
  final double? cursorRadius;
  final bool showEraserCursor;

  HandwritingPainter({
    required this.strokes,
    this.selectedIndices = const {},
    this.activeTransform,
    this.lassoPoints,
    this.currentStroke,
    this.cursorPosition,
    this.cursorRadius,
    this.showEraserCursor = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    // 保存済みのストロークを描画
    for (int i = 0; i < strokes.length; i++) {
      final stroke = strokes[i];
      final isSelected = selectedIndices.contains(i);
      
      paint.color = isSelected ? Colors.blue : stroke.color;
      paint.strokeWidth = stroke.strokeWidth;
      
      if (isSelected && activeTransform != null) {
        // 変形中のプレビュー表示
        final transformedPoints = stroke.points.map((p) {
          final vec = Vector3(p.dx, p.dy, 0);
          final tVec = activeTransform!.transform3(vec);
          return Offset(tVec.x, tVec.y);
        }).toList();
        _drawStrokeNormalized(canvas, transformedPoints, size, paint);
        
        // 元のストロークを薄く表示
        paint.color = paint.color.withOpacity(0.3);
        _drawStrokeNormalized(canvas, stroke.points, size, paint);
      } else {
        _drawStrokeNormalized(canvas, stroke.points, size, paint);
      }
    }

    // ラッソ描画
    if (lassoPoints != null && lassoPoints!.length > 1) {
      final lassoPath = Path();
      lassoPath.moveTo(lassoPoints!.first.dx, lassoPoints!.first.dy);
      for (final p in lassoPoints!.skip(1)) {
        lassoPath.lineTo(p.dx, p.dy);
      }
      
      canvas.drawPath(lassoPath, Paint()
        ..color = Colors.blue.withOpacity(0.2)
        ..style = PaintingStyle.fill
      );
      canvas.drawPath(lassoPath, Paint()
        ..color = Colors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
      );
    }

    // 変形ハンドルとバウンディングボックスの描画
    if (selectedIndices.isNotEmpty && activeTransform == null) {
        _drawSelectionUI(canvas, size);
    }

    // 消しゴムのカーソルを描画
    if (showEraserCursor && cursorPosition != null && cursorRadius != null) {
      final cursorPaint = Paint()
        ..color = Colors.blue.withOpacity(0.2)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(cursorPosition!, cursorRadius!, cursorPaint);
      
      final outlinePaint = Paint()
        ..color = Colors.blue.withOpacity(0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(cursorPosition!, cursorRadius!, outlinePaint);
    }
  }

  void _drawStrokeNormalized(Canvas canvas, List<Offset> points, Size size, Paint paint) {
    if (points.isEmpty) return;
    
    final pixelPoints = points.map((p) => Offset(
      p.dx / HandwritingNotifier.canvasWidth * size.width, 
      p.dy / HandwritingNotifier.canvasHeight * size.height,
    )).toList();

    if (pixelPoints.length == 1) {
      canvas.drawCircle(pixelPoints.first, paint.strokeWidth / 2, paint..style = PaintingStyle.fill);
      paint.style = PaintingStyle.stroke;
      return;
    }

    final path = Path();
    path.moveTo(pixelPoints.first.dx, pixelPoints.first.dy);
    for (int i = 1; i < pixelPoints.length; i++) {
      path.lineTo(pixelPoints[i].dx, pixelPoints[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  void _drawSelectionUI(Canvas canvas, Size size) {
    final selectedStrokes = <Stroke>[];
    for (final index in selectedIndices) {
      if (index < strokes.length) selectedStrokes.add(strokes[index]);
    }
    if (selectedStrokes.isEmpty) return;

    // 計算 (Normalized units)
    double minX = double.infinity, minY = double.infinity, maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final s in selectedStrokes) {
      for (final p in s.points) {
        if (p.dx < minX) minX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy > maxY) maxY = p.dy;
      }
    }

    // Convert to pixel units
    final rect = Rect.fromLTRB(
      minX / HandwritingNotifier.canvasWidth * size.width,
      minY / HandwritingNotifier.canvasHeight * size.height,
      maxX / HandwritingNotifier.canvasWidth * size.width,
      maxY / HandwritingNotifier.canvasHeight * size.height,
    );

    final paint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    
    canvas.drawRect(rect.inflate(4), paint);

    // Handles
    final handlePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final handleOutline = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final handleSize = 8.0;
    final corners = [
      rect.inflate(4).topLeft,
      rect.inflate(4).topRight,
      rect.inflate(4).bottomLeft,
      rect.inflate(4).bottomRight,
    ];

    for (final corner in corners) {
      canvas.drawRect(Rect.fromCenter(center: corner, width: handleSize, height: handleSize), handlePaint);
      canvas.drawRect(Rect.fromCenter(center: corner, width: handleSize, height: handleSize), handleOutline);
    }
  }

  @override
  bool shouldRepaint(covariant HandwritingPainter oldDelegate) {
    return true; 
  }
}

/// 手書きキャンバスウィジェット
class HandwritingCanvas extends ConsumerStatefulWidget {
  final String figureId;
  const HandwritingCanvas({super.key, required this.figureId});

  @override
  ConsumerState<HandwritingCanvas> createState() => _HandwritingCanvasState();
}

class _HandwritingCanvasState extends ConsumerState<HandwritingCanvas> {
  Offset? _cursorPosition;
  List<Offset>? _lassoPoints;
  Offset? _dragStart;
  String? _activeHandle; // 'tl', 'tr', 'bl', 'br', 'move'

  @override
  Widget build(BuildContext context) {
    final drawingState = ref.watch(handwritingProvider);
    final strokes = drawingState.figures[widget.figureId] ?? [];
    final selectedIndices = drawingState.selectedIndices[widget.figureId] ?? {};
    final activeTransform = drawingState.activeTransforms[widget.figureId];

    final notifier = ref.read(handwritingProvider.notifier);
    final tool = ref.watch(activeToolProvider);
    final color = ref.watch(activeColorProvider);
    final penWidth = ref.watch(penWidthProvider);
    final eraserWidth = ref.watch(eraserWidthProvider);
    final width = tool == DrawingTool.pen ? penWidth : eraserWidth;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        
        return MouseRegion(
          cursor: _getCursor(tool, selectedIndices, activeTransform, size),
          onHover: (event) {
            if (tool == DrawingTool.eraser) {
              setState(() => _cursorPosition = event.localPosition);
            } else {
              if (_cursorPosition != null) setState(() => _cursorPosition = null);
            }
          },
          onExit: (_) => setState(() => _cursorPosition = null),
          child: GestureDetector(
            onPanStart: (details) {
              setState(() => _cursorPosition = details.localPosition);
              if (tool == DrawingTool.pen) {
                notifier.startStroke(details.localPosition, size, color: color, width: width);
              } else if (tool == DrawingTool.eraser) {
                notifier.eraseAt(details.localPosition, size, widget.figureId, eraserWidth: eraserWidth);
              } else if (tool == DrawingTool.lasso) {
                // Check if clicking on handle or selection
                final handle = _getHandleAt(details.localPosition, selectedIndices, strokes, size);
                if (handle != null) {
                  _activeHandle = handle;
                  _dragStart = details.localPosition;
                } else {
                  _lassoPoints = [details.localPosition];
                  notifier.clearSelection(widget.figureId);
                  setState(() {});
                }
              }
            },
            onPanUpdate: (details) {
              setState(() => _cursorPosition = details.localPosition);
              if (tool == DrawingTool.pen) {
                notifier.updateStroke(details.localPosition, size);
              } else if (tool == DrawingTool.eraser) {
                notifier.eraseAt(details.localPosition, size, widget.figureId, eraserWidth: eraserWidth);
              } else if (tool == DrawingTool.lasso) {
                if (_activeHandle != null) {
                   _updateTransform(details.localPosition, selectedIndices, strokes, size);
                } else if (_lassoPoints != null) {
                  setState(() => _lassoPoints!.add(details.localPosition));
                }
              }
            },
            onPanEnd: (details) {
              setState(() => _cursorPosition = null);
              if (tool == DrawingTool.pen) {
                notifier.endStroke(widget.figureId);
              } else if (tool == DrawingTool.lasso) {
                if (_activeHandle != null) {
                  notifier.commitTransform(widget.figureId);
                  _activeHandle = null;
                  _dragStart = null;
                } else if (_lassoPoints != null) {
                  notifier.selectStrokesInPath(widget.figureId, _lassoPoints!, size);
                  setState(() => _lassoPoints = null);
                }
              }
            },
            child: CustomPaint(
              painter: HandwritingPainter(
                strokes: strokes,
                selectedIndices: selectedIndices,
                activeTransform: activeTransform,
                lassoPoints: _lassoPoints,
                currentStroke: notifier.currentStroke,
                cursorPosition: _cursorPosition,
                cursorRadius: width / 2 * (size.width / HandwritingNotifier.canvasWidth),
                showEraserCursor: tool == DrawingTool.eraser,
              ),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }

  MouseCursor _getCursor(DrawingTool tool, Set<int> selected, Matrix4? transform, Size size) {
     if (tool == DrawingTool.eraser) return SystemMouseCursors.none;
     return MouseCursor.defer;
  }

  String? _getHandleAt(Offset pos, Set<int> selected, List<Stroke> strokes, Size size) {
    if (selected.isEmpty) return null;
    final rect = _getSelectionPixelRect(selected, strokes, size).inflate(4);
    
    // Check handles (TL, TR, BL, BR) with 48x48 hit area
    const hitSize = 48.0;
    if (Rect.fromCenter(center: rect.topLeft, width: hitSize, height: hitSize).contains(pos)) return 'tl';
    if (Rect.fromCenter(center: rect.topRight, width: hitSize, height: hitSize).contains(pos)) return 'tr';
    if (Rect.fromCenter(center: rect.bottomLeft, width: hitSize, height: hitSize).contains(pos)) return 'bl';
    if (Rect.fromCenter(center: rect.bottomRight, width: hitSize, height: hitSize).contains(pos)) return 'br';
    
    if (rect.contains(pos)) return 'move';
    return null;
  }

  Rect _getSelectionPixelRect(Set<int> selected, List<Stroke> strokes, Size size) {
    double minX = double.infinity, minY = double.infinity, maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final index in selected) {
      if (index >= strokes.length) continue;
      final s = strokes[index];
      for (final p in s.points) {
        if (p.dx < minX) minX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy > maxY) maxY = p.dy;
      }
    }
    if (minX == double.infinity) return Rect.zero;
    return Rect.fromLTRB(
      minX / HandwritingNotifier.canvasWidth * size.width,
      minY / HandwritingNotifier.canvasHeight * size.height,
      maxX / HandwritingNotifier.canvasWidth * size.width,
      maxY / HandwritingNotifier.canvasHeight * size.height,
    );
  }

  void _updateTransform(Offset current, Set<int> selected, List<Stroke> strokes, Size size) {
    if (_dragStart == null || _activeHandle == null) return;
    
    final rect = _getSelectionPixelRect(selected, strokes, size);
    if (rect.isEmpty) return;
    
    final notifier = ref.read(handwritingProvider.notifier);
    
    // Normalized units for Matrix
    final normRect = Rect.fromLTRB(
      rect.left / size.width * HandwritingNotifier.canvasWidth,
      rect.top / size.height * HandwritingNotifier.canvasHeight,
      rect.right / size.width * HandwritingNotifier.canvasWidth,
      rect.bottom / size.height * HandwritingNotifier.canvasHeight,
    );

    final dx = (current.dx - _dragStart!.dx) / size.width * HandwritingNotifier.canvasWidth;
    final dy = (current.dy - _dragStart!.dy) / size.height * HandwritingNotifier.canvasHeight;

    if (_activeHandle == 'move') {
      final matrix = Matrix4.identity()..translate(dx, dy);
      notifier.updateActiveTransform(widget.figureId, matrix);
    } else {
      // Scaling
      double sx = 1.0, sy = 1.0;
      Offset pivot = Offset.zero;
      
      switch (_activeHandle) {
        case 'tl':
          pivot = normRect.bottomRight;
          sx = (normRect.width - dx) / normRect.width;
          sy = (normRect.height - dy) / normRect.height;
          break;
        case 'tr':
          pivot = normRect.bottomLeft;
          sx = (normRect.width + dx) / normRect.width;
          sy = (normRect.height - dy) / normRect.height;
          break;
        case 'bl':
          pivot = normRect.topRight;
          sx = (normRect.width - dx) / normRect.width;
          sy = (normRect.height + dy) / normRect.height;
          break;
        case 'br':
          pivot = normRect.topLeft;
          sx = (normRect.width + dx) / normRect.width;
          sy = (normRect.height + dy) / normRect.height;
          break;
      }
      
      // Clamp scale to avoid flipping/zero
      sx = sx.clamp(0.1, 10.0);
      sy = sy.clamp(0.1, 10.0);

      final matrix = Matrix4.identity()
        ..translate(pivot.dx, pivot.dy)
        ..scale(sx, sy)
        ..translate(-pivot.dx, -pivot.dy);
      
      notifier.updateActiveTransform(widget.figureId, matrix);
    }
  }
}
