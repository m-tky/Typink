import 'package:flutter/material.dart';
import '../frb_generated.dart/editor.dart';
import 'theme_provider.dart';

mixin EditorThemeMixin {
  TextStyle get editorTextStyle;
  double get editorFontSize;
  double get editorLineHeight;
  SyntaxTheme get activeSyntaxTheme;

  static final Expando<TextSpan> _spanCache = Expando<TextSpan>();

  TextSpan buildTextSpan(RenderLine line) {
    final cached = _spanCache[line];
    if (cached != null) return cached;

    final TextSpan span;
    if (line.spans.isEmpty) {
      span = TextSpan(
        text: line.text,
        style: editorTextStyle.copyWith(fontSize: editorFontSize, height: editorLineHeight),
      );
    } else {
      final children = <InlineSpan>[];
      int lastOffset = 0;
      
      for (final s in line.spans) {
        final start = s.start.toInt().clamp(0, line.text.length);
        final end = s.end.toInt().clamp(0, line.text.length);
        
        if (start > lastOffset) {
          children.add(TextSpan(text: line.text.substring(lastOffset, start)));
        }
        
        if (start < end) {
          final level = s.headingLevel;
          double spanFontSize = editorFontSize;
          if (level != null) {
            if (level == 1) spanFontSize *= 1.5;
            else if (level == 2) spanFontSize *= 1.3;
            else if (level == 3) spanFontSize *= 1.2;
            else spanFontSize *= 1.1;
          }

          children.add(TextSpan(
            text: line.text.substring(start, end),
            style: TextStyle(
              color: getSpanColor(s.label),
              fontSize: spanFontSize,
              fontWeight: (s.bold || level != null) ? FontWeight.bold : FontWeight.normal,
              fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
            ),
          ));
        }
        
        lastOffset = end;
      }
      
      if (lastOffset < line.text.length) {
        children.add(TextSpan(text: line.text.substring(lastOffset)));
      }

      span = TextSpan(
        children: children,
        style: editorTextStyle.copyWith(fontSize: editorFontSize, height: editorLineHeight),
      );
    }

    _spanCache[line] = span;
    return span;
  }

  Color getSpanColor(String label) {
    final theme = activeSyntaxTheme;
    switch (label) {
      case 'heading': return theme.heading;
      case 'math': return theme.math;
      case 'math.operator': return theme.mathOperator;
      case 'math.punctuation': return theme.mathPunctuation;
      case 'math.keyword': return theme.mathKeyword;
      case 'math.function': return theme.mathFunction;
      case 'math.variable': return theme.mathVariable;
      
      case 'delimiter.L1': return theme.delimiterL1;
      case 'delimiter.L2': return theme.delimiterL2;
      case 'delimiter.L3': return theme.delimiterL3;
      case 'delimiter.L4': return theme.delimiterL4;
      case 'delimiter.L5': return theme.delimiterL5;
      
      case 'raw': return theme.raw;
      case 'link': return theme.link;
      case 'label': return theme.label;
      case 'ref': return theme.ref;
      case 'marker': return theme.marker;
      case 'operator': return theme.operator;
      case 'punctuation': return theme.punctuation;
      case 'error': return theme.error;

      case 'function': return theme.function;
      case 'keyword': return theme.keyword;
      case 'string': return theme.string;
      case 'comment': return theme.comment;
      case 'variable': return theme.variable;
      default: return editorTextStyle.color ?? Colors.black;
    }
  }
}
