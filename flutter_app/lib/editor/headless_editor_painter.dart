import 'package:flutter/material.dart';
import '../frb_generated.dart/editor.dart';
import '../frb_generated.dart/vim_engine.dart';
import 'providers.dart';

class HeadlessEditorPainter extends CustomPainter {
  final EditorView view;
  final double fontSize;
  final double lineHeight;
  final TextStyle textStyle;
  final Color cursorColor;
  final AppSettings settings;

  HeadlessEditorPainter({
    required this.view,
    this.fontSize = 14.0,
    this.lineHeight = 1.4,
    required this.textStyle,
    required this.cursorColor,
    required this.settings,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    final lineNumPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
    );

    double currentY = 0;
    const double leftMargin = 40.0;
    const double rightPadding = 8.0;

    for (int i = 0; i < view.lines.length; i++) {
      final line = view.lines[i];
      
      // Calculate line number string
      String lineNumStr = '${i + 1}';
      if (settings.relativeLineNumbers) {
        final rel = (i - view.cursorLine.toInt()).abs();
        if (rel == 0) {
          lineNumStr = '${i + 1}'; // Current line usually shows absolute number in Neovim
        } else {
          lineNumStr = '$rel';
        }
      }

      // Draw line number
      lineNumPainter.text = TextSpan(
        text: lineNumStr,
        style: textStyle.copyWith(
          fontSize: fontSize * 0.85, 
          color: i == view.cursorLine.toInt() 
            ? cursorColor.withOpacity(0.8) 
            : textStyle.color?.withOpacity(0.4) ?? Colors.grey
        ),
      );
      lineNumPainter.layout();
      lineNumPainter.paint(canvas, Offset(leftMargin - 8 - lineNumPainter.width, currentY + (fontSize * lineHeight - fontSize * 0.85) / 2));

      textPainter.text = _buildTextSpan(line);
      
      textPainter.layout(maxWidth: size.width - leftMargin - rightPadding);
      textPainter.paint(canvas, Offset(leftMargin, currentY));

      // Draw Whitespace indicators (Listchars)
      if (settings.showWhitespace) {
        final symbolPainter = TextPainter(
          textDirection: TextDirection.ltr,
        );
        
        final metrics = textPainter.computeLineMetrics();
        for (int m = 0; m < metrics.length; m++) {
          final isLast = m == metrics.length - 1;
          symbolPainter.text = TextSpan(
            text: isLast ? '↵' : '↳',
            style: textStyle.copyWith(fontSize: fontSize * 0.7, color: Colors.grey.withOpacity(0.3)),
          );
          symbolPainter.layout();
          
          final metric = metrics[m];
          // Position at the end of the visual line
          symbolPainter.paint(canvas, Offset(leftMargin + metric.width, currentY + metric.baseline - fontSize * 0.7));
        }
      }

      // Draw cursor if this is the cursor line
      if (i == view.cursorLine.toInt()) {
        _drawCursor(canvas, textPainter, currentY, leftMargin);
      }

      currentY += textPainter.height;
    }
  }

  void _drawCursor(Canvas canvas, TextPainter textPainter, double currentY, double leftMargin) {
    final charIdx = view.cursorColumnU16.toInt();
    final textLength = textPainter.text?.toPlainText().length ?? 0;
    
    // Get the horizontal/vertical offset for the cursor based on UTF-16 index
    // TextPosition(offset: charIdx) correctly handles wrapped lines in TextPainter
    final offset = textPainter.getOffsetForCaret(
      TextPosition(offset: charIdx.clamp(0, textLength)),
      Rect.fromLTWH(0, 0, 1, fontSize * lineHeight),
    );

    final paint = Paint()..color = cursorColor;
    final cursorY = currentY + offset.dy;
    final cursorHeight = fontSize * lineHeight;
    
    if (view.mode == VimMode.insert) {
      canvas.drawRect(
        Rect.fromLTWH(leftMargin + offset.dx, cursorY, 2, cursorHeight),
        paint,
      );
    } else {
      double charWidth = fontSize * 0.6;
      if (charIdx < textLength) {
        final nextOffset = textPainter.getOffsetForCaret(
          TextPosition(offset: charIdx + 1),
          Rect.fromLTWH(0, 0, 1, cursorHeight),
        );
        // If the next character is on a different visual line, use default width
        if (nextOffset.dy == offset.dy) {
          charWidth = (nextOffset.dx - offset.dx).abs().clamp(fontSize * 0.2, fontSize * 1.5);
        }
      }

      final p = Paint()
        ..color = cursorColor.withOpacity(0.8)
        ..style = PaintingStyle.fill;
      canvas.drawRect(
        Rect.fromLTWH(leftMargin + offset.dx, cursorY, charWidth, cursorHeight),
        p,
      );
    }
  }

  int? getGlobalOffsetForPosition(Offset position, Size size) {
    double currentY = 0;
    const double leftMargin = 40.0;
    const double rightPadding = 8.0;

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    for (int i = 0; i < view.lines.length; i++) {
      final line = view.lines[i];
      textPainter.text = TextSpan(
        text: line.text,
        style: textStyle.copyWith(fontSize: fontSize, height: lineHeight),
      );
      textPainter.layout(maxWidth: size.width - leftMargin - rightPadding);

      final double lineHeightPixels = textPainter.height;

      if (position.dy >= currentY && position.dy < currentY + lineHeightPixels ||
         (i == view.lines.length - 1 && position.dy >= currentY)) {
        
        final localOffset = Offset(position.dx - leftMargin, position.dy - currentY);
        final textPosition = textPainter.getPositionForOffset(localOffset);
        
        return line.startU16.toInt() + textPosition.offset;
      }

      currentY += lineHeightPixels;
    }

    return null;
  }

  TextSpan _buildTextSpan(RenderLine line) {
    if (line.spans.isEmpty) {
      return TextSpan(
        text: line.text,
        style: textStyle.copyWith(fontSize: fontSize, height: lineHeight),
      );
    }

    final children = <InlineSpan>[];
    int lastOffset = 0;
    
    for (final span in line.spans) {
      final start = span.start.toInt().clamp(0, line.text.length);
      final end = span.end.toInt().clamp(0, line.text.length);
      
      if (start > lastOffset) {
        children.add(TextSpan(text: line.text.substring(lastOffset, start)));
      }
      
      if (start < end) {
        children.add(TextSpan(
          text: line.text.substring(start, end),
          style: TextStyle(color: _getSpanColor(span.label)),
        ));
      }
      
      lastOffset = end;
    }
    
    if (lastOffset < line.text.length) {
      children.add(TextSpan(text: line.text.substring(lastOffset)));
    }

    return TextSpan(
      children: children,
      style: textStyle.copyWith(fontSize: fontSize, height: lineHeight),
    );
  }

  Color _getSpanColor(String label) {
    // Elegant, curated palette for scientific notebook
    switch (label) {
      case 'heading': return const Color(0xFFE45649); // Warm Red
      case 'math': return const Color(0xFF4078F2);    // Bright Blue
      case 'function': return const Color(0xFF0184BC); // Cyan/Deep Blue
      case 'keyword': return const Color(0xFFA626A4); // Purple
      case 'string': return const Color(0xFF50A14F);  // Green
      case 'comment': return const Color(0xFFA0A1A7); // Grey
      case 'variable': return const Color(0xFF986801); // Ochre
      default: return textStyle.color ?? Colors.black;
    }
  }

  @override
  bool shouldRepaint(covariant HeadlessEditorPainter oldDelegate) {
    return oldDelegate.view != view ||
           oldDelegate.fontSize != fontSize ||
           oldDelegate.lineHeight != lineHeight ||
           oldDelegate.textStyle != textStyle ||
           oldDelegate.cursorColor != cursorColor ||
           oldDelegate.settings != settings;
  }
}
