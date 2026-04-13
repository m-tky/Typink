import 'package:flutter/material.dart';

class Stroke {
  final String id;
  final List<Offset> points;
  final Color color;
  final double strokeWidth;

  Stroke({
    required this.id,
    required this.points,
    this.color = Colors.black,
    this.strokeWidth = 3.0,
  });

  // SVGのpath要素に変換するための文字列を生成
  String toSvgPathData() {
    if (points.isEmpty) return '';
    final buffer = StringBuffer();
    buffer.write('M ${points[0].dx},${points[0].dy}');
    for (var i = 1; i < points.length; i++) {
      buffer.write(' L ${points[i].dx},${points[i].dy}');
    }
    return buffer.toString();
  }

  Stroke copyWith({
    String? id,
    List<Offset>? points,
    Color? color,
    double? strokeWidth,
  }) {
    return Stroke(
      id: id ?? this.id,
      points: points ?? this.points,
      color: color ?? this.color,
      strokeWidth: strokeWidth ?? this.strokeWidth,
    );
  }
}
