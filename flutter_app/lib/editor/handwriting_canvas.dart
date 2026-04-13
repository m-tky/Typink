import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';

/// 実際に描画を行う Painter
class HandwritingPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? currentStroke;
  final Offset? cursorPosition;
  final double? cursorRadius;
  final bool showEraserCursor;

  HandwritingPainter({
    required this.strokes, 
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
    for (final stroke in strokes) {
      paint.color = stroke.color;
      paint.strokeWidth = stroke.strokeWidth;
      _drawStrokeNormalized(canvas, stroke.points, size, paint);
    }

    // 現在描画中のストロークを描画
    if (currentStroke != null) {
      paint.color = currentStroke!.color;
      paint.strokeWidth = currentStroke!.strokeWidth;
      _drawStrokeNormalized(canvas, currentStroke!.points, size, paint);
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

  @override
  Widget build(BuildContext context) {
    final stateMap = ref.watch(handwritingProvider);
    final strokes = stateMap[widget.figureId] ?? [];
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
          cursor: tool == DrawingTool.eraser ? SystemMouseCursors.none : MouseCursor.defer,
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
              } else {
                notifier.eraseAt(details.localPosition, size, widget.figureId, eraserWidth: eraserWidth);
              }
            },
            onPanUpdate: (details) {
              setState(() => _cursorPosition = details.localPosition);
              if (tool == DrawingTool.pen) {
                notifier.updateStroke(details.localPosition, size);
              } else {
                notifier.eraseAt(details.localPosition, size, widget.figureId, eraserWidth: eraserWidth);
              }
            },
            onPanEnd: (details) {
              setState(() => _cursorPosition = null);
              if (tool == DrawingTool.pen) {
                notifier.endStroke(widget.figureId);
              }
            },
            child: CustomPaint(
              painter: HandwritingPainter(
                strokes: strokes,
                currentStroke: notifier.currentStroke,
                cursorPosition: _cursorPosition,
                cursorRadius: width / 2 * (size.width / HandwritingNotifier.canvasWidth), // Width is in canvas units
                showEraserCursor: tool == DrawingTool.eraser,
              ),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}
