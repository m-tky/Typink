import 'package:flutter/material.dart';
import '../frb_generated.dart/editor.dart';
import '../frb_generated.dart/vim_engine.dart';
import '../frb_generated.dart/api.dart' as bridge;
import 'providers.dart';
import 'editor_theme_mixin.dart';
import 'theme_provider.dart';

class HeadlessEditorPainter extends CustomPainter with EditorThemeMixin {
  final EditorView view;
  final double fontSize;
  final double lineHeight;
  final TextStyle textStyle;
  final Color cursorColor;
  final AppSettings settings;
  final double verticalOffset;
  final int baseLineIndex;
  final VersionedDiagnostics diagnostics;
  final int currentVersion;
  final DateTime lastInputTime;
  final bool isComposing;
  final AppTheme activeTheme;

  @override
  TextStyle get editorTextStyle => textStyle;
  @override
  double get editorFontSize => fontSize;
  @override
  double get editorLineHeight => lineHeight;
  
  HeadlessEditorPainter({
    required this.view,
    this.fontSize = 14.0,
    this.lineHeight = 1.4,
    required this.textStyle,
    required this.cursorColor,
    required this.settings,
    this.verticalOffset = 0.0,
    this.baseLineIndex = 0,
    required this.diagnostics,
    required this.currentVersion,
    required this.lastInputTime,
    required this.isComposing,
    required this.activeTheme,
  });

  @override
  SyntaxTheme get activeSyntaxTheme => activeTheme.syntaxTheme;

  @override
  void paint(Canvas canvas, Size size) {
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    final lineNumPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
    );

    double currentY = verticalOffset;
    const double leftMargin = 40.0;
    const double rightPadding = 8.0;

    for (int i = 0; i < view.lines.length; i++) {
      final line = view.lines[i];
      
      // Calculate line number string
      final absoluteLineIdx = baseLineIndex + i;
      String lineNumStr = '${absoluteLineIdx + 1}';
      if (settings.relativeLineNumbers) {
        final rel = (absoluteLineIdx - view.cursorLine.toInt()).abs();
        if (rel == 0) {
          lineNumStr = '${absoluteLineIdx + 1}'; 
        } else {
          lineNumStr = '$rel';
        }
      }

      // Draw line number
      lineNumPainter.text = TextSpan(
        text: lineNumStr,
        style: textStyle.copyWith(
          fontSize: fontSize * 0.85, 
          color: absoluteLineIdx == view.cursorLine.toInt() 
            ? cursorColor.withOpacity(0.8) 
            : textStyle.color?.withOpacity(0.4) ?? Colors.grey
        ),
      );
      lineNumPainter.layout();
      lineNumPainter.paint(canvas, Offset(leftMargin - 8 - lineNumPainter.width, currentY + (fontSize * lineHeight - fontSize * 0.85) / 2));

      textPainter.text = buildTextSpan(line);
      
      const double arrowWidth = 16.0;
      textPainter.layout(maxWidth: size.width - leftMargin - rightPadding - arrowWidth);

      double yOffset = 0;
      final metrics = textPainter.computeLineMetrics();
      
      if (metrics.isEmpty && absoluteLineIdx == view.cursorLine.toInt()) {
        // Special case: empty cursor line
        _drawCursor(canvas, textPainter, currentY, leftMargin);
        
        if (settings.showWhitespace) {
          final symbolPainter = TextPainter(textDirection: TextDirection.ltr);
          symbolPainter.text = TextSpan(
            text: '↵',
            style: textStyle.copyWith(
              fontSize: fontSize * 0.9,
              color: cursorColor.withOpacity(0.5),
              fontWeight: FontWeight.bold,
            ),
          );
          symbolPainter.layout();
          symbolPainter.paint(canvas, Offset(leftMargin, currentY + (textPainter.height - symbolPainter.height) / 2));
        }
      }

      for (int m = 0; m < metrics.length; m++) {
        final metric = metrics[m];
        final bool isLastSegment = (m == metrics.length - 1);
        final double lineTop = currentY + yOffset;
        final double xOffset = (m == 0) ? leftMargin : leftMargin + arrowWidth;

        canvas.save();
        // Clip to this physical line segment
        canvas.clipRect(Rect.fromLTWH(0, lineTop, size.width, metric.height));
        
        // 1. Draw Selection (using translated context)
        if ((view.mode == VimMode.visual || view.mode == VimMode.visualLine) && view.selectionStartLine != null) {
          _drawSelection(canvas, textPainter, currentY, xOffset, i, size.width);
        }

        // 2. Draw Highlights
        if (view.searchQuery != null && view.searchQuery!.isNotEmpty) {
          _drawSearchHighlights(canvas, textPainter, currentY, xOffset, view.searchQuery!);
        }

        // 3. Draw Text
        textPainter.paint(canvas, Offset(xOffset, currentY));

        // 4. Draw Diagnostics
        _drawDiagnostics(canvas, textPainter, currentY, xOffset, absoluteLineIdx, size);

        // 5. Draw Cursor
        if (absoluteLineIdx == view.cursorLine.toInt()) {
          _drawCursor(canvas, textPainter, currentY, xOffset);
        }

        canvas.restore();

        // 6. Draw Indicators (Inline)
        if (settings.showWhitespace) {
          final symbolPainter = TextPainter(textDirection: TextDirection.ltr);
          final style = textStyle.copyWith(
            fontSize: fontSize * 0.9,
            color: cursorColor.withOpacity(0.5),
            fontWeight: FontWeight.bold,
          );

          if (isLastSegment) {
            symbolPainter.text = TextSpan(text: '↵', style: style);
            symbolPainter.layout();
            symbolPainter.paint(canvas, Offset(xOffset + metric.width, lineTop + (metric.height - symbolPainter.height) / 2));
          }

          if (m > 0) {
            symbolPainter.text = TextSpan(text: '↪', style: style);
            symbolPainter.layout();
            // Positioned at the leftmost part of the text indent
            symbolPainter.paint(canvas, Offset(leftMargin, lineTop + (metric.height - symbolPainter.height) / 2));
          }
        }
        
        yOffset += metric.height;
      }

      currentY += textPainter.height;
    }
  }

  void _drawSelection(Canvas canvas, TextPainter textPainter, double currentY, double leftMargin, int lineIdx, double canvasWidth) {
    if (view.selectionStartLine == null || view.selectionStartColumnU16 == null) return;
    
    final startLine = view.selectionStartLine!.toInt();
    final startCol = view.selectionStartColumnU16!.toInt();
    final cursorLine = view.cursorLine.toInt();
    final cursorCol = view.cursorColumnU16.toInt();

    final minLine = startLine < cursorLine ? startLine : cursorLine;
    final maxLine = startLine < cursorLine ? cursorLine : startLine;

    if (lineIdx < minLine || lineIdx > maxLine) return;

    final isVisualLine = view.mode == VimMode.visualLine;
    int selStart;
    int selEnd;
    final textLen = textPainter.text?.toPlainText().length ?? 0;

    if (isVisualLine) {
      selStart = 0;
      selEnd = textLen;
    } else {
      if (startLine == cursorLine) {
        selStart = startCol < cursorCol ? startCol : cursorCol;
        selEnd = startCol < cursorCol ? cursorCol : startCol;
      } else if (lineIdx == minLine) {
        selStart = (startLine == minLine) ? startCol : cursorCol;
        selEnd = textLen;
      } else if (lineIdx == maxLine) {
        selStart = 0;
        selEnd = (cursorLine == maxLine) ? cursorCol : startCol;
      } else {
        selStart = 0;
        selEnd = textLen;
      }
    }

    // In Vim visual mode, the character under the cursor IS included in the selection.
    final selection = TextSelection(
      baseOffset: selStart.clamp(0, textLen),
      extentOffset: (selEnd + 1).clamp(0, textLen),
    );

    final boxes = textPainter.getBoxesForSelection(selection);
    // Use a more prominent opacity for Neovim-like feel (0.4 vs 0.25)
    final paint = Paint()..color = cursorColor.withOpacity(0.4);
    
    for (final box in boxes) {
      double startX = leftMargin + box.left;
      double width = box.right - box.left;
      
      // For visual line mode, if it's the end of text or empty line,
      // we might want to extend the highlight to represent the newline or full line.
      if (isVisualLine && (selEnd == textLen || textLen == 0)) {
        // Extend highlight to at least a bit further to show the "line" selection
        width = (canvasWidth - startX).clamp(width, canvasWidth - startX);
      }

      canvas.drawRect(
        Rect.fromLTWH(
          startX,
          currentY + box.top,
          width,
          box.bottom - box.top,
        ),
        paint,
      );
    }

    // Handle empty lines in visual line mode
    if (isVisualLine && textLen == 0) {
      canvas.drawRect(
        Rect.fromLTWH(
          leftMargin,
          currentY,
          canvasWidth - leftMargin,
          fontSize * lineHeight,
        ),
        paint,
      );
    }
  }

  void _drawSearchHighlights(Canvas canvas, TextPainter textPainter, double currentY, double leftMargin, String query) {
    if (query.isEmpty) return;
    final text = textPainter.text?.toPlainText() ?? '';
    final matches = <RegExpMatch>[];
    try {
      // Recursive/Looping regex to find all matches
      final regex = RegExp(RegExp.escape(query), caseSensitive: false);
      matches.addAll(regex.allMatches(text));
    } catch (_) {}

    final paint = Paint()..color = Colors.orangeAccent.withOpacity(0.4);
    for (final match in matches) {
      final selection = TextSelection(
        baseOffset: match.start,
        extentOffset: match.end,
      );
      final boxes = textPainter.getBoxesForSelection(selection);
      for (final box in boxes) {
        canvas.drawRect(
          Rect.fromLTWH(
            leftMargin + box.left,
            currentY + box.top,
            box.right - box.left,
            box.bottom - box.top,
          ),
          paint,
        );
      }
    }
  }

  void _drawCursor(Canvas canvas, TextPainter textPainter, double currentY, double leftMargin) {
    final charIdx = view.cursorColumnU16.toInt();
    final textLength = textPainter.text?.toPlainText().length ?? 0;
    
    double cursorX = 0;
    double cursorY = 0;
    double cursorHeight = fontSize * lineHeight;
    double charWidth = fontSize * 0.6;

    // Use character box metrics for the most accurate positioning and sizing.
    // This ensures headings and other styled text have correctly aligned cursors.
    final bool isAtLineEnd = charIdx >= textLength;
    final int lookupIdx = isAtLineEnd ? (textLength - 1).clamp(0, textLength) : charIdx;

    if (textLength > 0) {
      final boxes = textPainter.getBoxesForSelection(
        TextSelection(baseOffset: lookupIdx, extentOffset: (lookupIdx + 1).clamp(0, textLength)),
      );

      if (boxes.isNotEmpty) {
        final box = boxes.first;
        cursorX = isAtLineEnd ? box.right : box.left;
        cursorY = box.top;
        cursorHeight = box.bottom - box.top; 
        charWidth = box.right - box.left;
      } else {
        // Fallback to getOffsetForCaret if boxes are empty
        final offset = textPainter.getOffsetForCaret(
          TextPosition(offset: charIdx.clamp(0, textLength)),
          Rect.fromLTWH(0, 0, 1, fontSize * lineHeight),
        );
        cursorX = offset.dx;
        cursorY = offset.dy;
      }
    } else {
      // Completely empty line: use metrics to find the default height
      final metrics = textPainter.computeLineMetrics();
      if (metrics.isNotEmpty) {
        cursorHeight = metrics.first.height;
      }
    }

    final finalCursorY = currentY + cursorY;
    final paint = Paint()..color = cursorColor;

    if (view.mode == VimMode.insert) {
      // Bar cursor in insert mode
      canvas.drawRect(
        Rect.fromLTWH(leftMargin + cursorX, finalCursorY, 2, cursorHeight),
        paint,
      );
    } else {
      // Block cursor in normal/visual mode
      charWidth = charWidth.clamp(fontSize * 0.2, fontSize * 1.5);
      
      final p = Paint()
        ..color = cursorColor.withOpacity(0.8)
        ..style = PaintingStyle.fill;
        
      canvas.drawRect(
        Rect.fromLTWH(leftMargin + cursorX, finalCursorY, charWidth, cursorHeight),
        p,
      );
    }
  }

  void _drawDiagnostics(Canvas canvas, TextPainter textPainter, double currentY, double leftMargin, int lineIdx, Size size) {
    if (diagnostics.items.isEmpty) return;

    final bool isFresh = diagnostics.version == currentVersion;
    final bool isTyping = DateTime.now().difference(lastInputTime).inMilliseconds < 300;
    final bool isStale = diagnostics.version == currentVersion - 1;
    final bool showFaded = isStale && (isTyping || isComposing);

    if (!isFresh && !showFaded) return;

    final double opacity = isFresh ? 1.0 : 0.4;
    final text = textPainter.text?.toPlainText() ?? '';
    final textLen = text.length;

    // Filter diagnostics for this line
    final lineDiags = diagnostics.items.where((d) => d.line.toInt() == lineIdx).toList();
    if (lineDiags.isEmpty) return;

    // 1. Draw Gutter Signs
    _drawGutterSign(canvas, currentY, lineDiags.first, opacity);

    // 2. Draw Underlines
    for (final diag in lineDiags) {
      final int startCol = diag.column.toInt();
      final int endCol = (startCol + 1).clamp(0, textLen);
      
      final selection = TextSelection(
        baseOffset: startCol.clamp(0, textLen),
        extentOffset: endCol.clamp(0, textLen),
      );
      
      final boxes = textPainter.getBoxesForSelection(selection);
      final Color color = diag.severity == 1 ? Colors.red : Colors.orange;
      final paint = Paint()
        ..color = color.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;

      for (final box in boxes) {
        final double y = currentY + box.bottom;
        canvas.drawLine(Offset(leftMargin + box.left, y), Offset(leftMargin + box.right, y), paint);
      }
    }

    // 3. Draw Virtual Text (LSP message at line end)
    final firstDiag = lineDiags.first;
    _drawVirtualText(canvas, textPainter, currentY, leftMargin, firstDiag, opacity, size);
  }

  void _drawGutterSign(Canvas canvas, double currentY, bridge.TypstDiagnostic diag, double opacity) {
    final Color color = diag.severity == 1 ? Colors.red : Colors.orange;
    final double dotSize = 4.0;
    final double centerX = 12.0; // In the left margin (10-20 range)
    final double centerY = currentY + (lineHeight * fontSize * 0.5);

    final paint = Paint()
      ..color = color.withOpacity(opacity)
      ..style = PaintingStyle.fill;
    
    canvas.drawCircle(Offset(centerX, centerY), dotSize / 2, paint);
  }

  void _drawVirtualText(Canvas canvas, TextPainter mainTextPainter, double currentY, double leftMargin, bridge.TypstDiagnostic diag, double opacity, Size size) {
    final Color color = diag.severity == 1 ? Colors.red.withOpacity(0.7) : Colors.orange.withOpacity(0.7);
    
    final vtPainter = TextPainter(
      text: TextSpan(
        text: "  // ${diag.message}",
        style: textStyle.copyWith(
          color: color.withOpacity(opacity * 0.8),
          fontSize: fontSize * 0.9,
          fontStyle: FontStyle.italic,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '...',
    );

    // Calculate available width at the end of the line
    final double textWidth = mainTextPainter.width;
    final double availableWidth = (size.width - leftMargin - textWidth - 20).clamp(0.0, size.width * 0.4);
    
    if (availableWidth < 50) return; // Too narrow to show anything useful

    vtPainter.layout(maxWidth: availableWidth);
    vtPainter.paint(canvas, Offset(leftMargin + textWidth, currentY));
  }

  @override
  bool shouldRepaint(covariant HeadlessEditorPainter oldDelegate) {
    return oldDelegate.view != view ||
           oldDelegate.fontSize != fontSize ||
           oldDelegate.lineHeight != lineHeight ||
           oldDelegate.textStyle != textStyle ||
           oldDelegate.cursorColor != cursorColor ||
           oldDelegate.settings != settings ||
           oldDelegate.diagnostics != diagnostics ||
           oldDelegate.currentVersion != currentVersion ||
           oldDelegate.lastInputTime != lastInputTime ||
           oldDelegate.isComposing != isComposing ||
           oldDelegate.activeTheme != activeTheme;
  }
}
