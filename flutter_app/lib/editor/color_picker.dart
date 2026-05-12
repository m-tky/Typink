import 'dart:math';
import 'package:flutter/material.dart';

class ColorWheelPicker extends StatefulWidget {
  final Color initialColor;
  final ValueChanged<Color> onColorChanged;

  const ColorWheelPicker({
    super.key,
    required this.initialColor,
    required this.onColorChanged,
  });

  @override
  State<ColorWheelPicker> createState() => _ColorWheelPickerState();
}

class _ColorWheelPickerState extends State<ColorWheelPicker> {
  late HSVColor hsvColor;

  @override
  void initState() {
    super.initState();
    hsvColor = HSVColor.fromColor(widget.initialColor);
  }

  void _updateColor(HSVColor newColor) {
    setState(() {
      hsvColor = newColor;
    });
    widget.onColorChanged(newColor.toColor());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: LayoutBuilder(builder: (context, constraints) {
            final size = constraints.maxWidth;
            return Stack(
              alignment: Alignment.center,
              children: [
                // Hue Ring
                GestureDetector(
                  onPanUpdate: (details) =>
                      _handleHuePan(details.localPosition, size),
                  onPanDown: (details) =>
                      _handleHuePan(details.localPosition, size),
                  child: CustomPaint(
                    size: Size(size, size),
                    painter: HueRingPainter(hue: hsvColor.hue),
                  ),
                ),
                // SV Square
                SizedBox(
                  width: size * 0.6,
                  height: size * 0.6,
                  child: GestureDetector(
                    onPanUpdate: (details) =>
                        _handleSVPan(details.localPosition, size * 0.6),
                    onPanDown: (details) =>
                        _handleSVPan(details.localPosition, size * 0.6),
                    child: CustomPaint(
                      painter: SVSquarePainter(
                        hue: hsvColor.hue,
                        saturation: hsvColor.saturation,
                        value: hsvColor.value,
                      ),
                    ),
                  ),
                ),
              ],
            );
          }),
        ),
        const SizedBox(height: 24),
        // Preview and Hex code
        Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: hsvColor.toColor(),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [
                  BoxShadow(color: Colors.black26, blurRadius: 4),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '#${hsvColor.toColor().value.toRadixString(16).padLeft(8, '0').toUpperCase().substring(2)}',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _handleHuePan(Offset localPosition, double size) {
    final center = size / 2;
    final dx = localPosition.dx - center;
    final dy = localPosition.dy - center;
    final angle = atan2(dy, dx) * 180 / pi;
    final hue = (angle + 360) % 360;
    _updateColor(hsvColor.withHue(hue));
  }

  void _handleSVPan(Offset localPosition, double size) {
    final s = (localPosition.dx / size).clamp(0.0, 1.0);
    final v = 1.0 - (localPosition.dy / size).clamp(0.0, 1.0);
    _updateColor(hsvColor.withSaturation(s).withValue(v));
  }
}

class HueRingPainter extends CustomPainter {
  final double hue;
  HueRingPainter({required this.hue});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final thickness = size.width * 0.1;

    // Draw Rainbow Ring
    final rect =
        Rect.fromCircle(center: center, radius: radius - thickness / 2);
    final gradient = SweepGradient(
      colors: List.generate(
          360,
          (index) =>
              HSVColor.fromAHSV(1.0, index.toDouble(), 1.0, 1.0).toColor()),
    );
    final paint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness;

    canvas.drawCircle(center, radius - thickness / 2, paint);

    // Draw Pointer
    final angle = hue * pi / 180;
    final pointerCenter = Offset(
      center.dx + (radius - thickness / 2) * cos(angle),
      center.dy + (radius - thickness / 2) * sin(angle),
    );

    final pointerPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(pointerCenter, thickness / 2 + 2, pointerPaint);

    final innerPointerPaint = Paint()
      ..color = Colors.black.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(pointerCenter, thickness / 2 + 3, innerPointerPaint);
  }

  @override
  bool shouldRepaint(HueRingPainter oldDelegate) => oldDelegate.hue != hue;
}

class SVSquarePainter extends CustomPainter {
  final double hue;
  final double saturation;
  final double value;

  SVSquarePainter({
    required this.hue,
    required this.saturation,
    required this.value,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Horizontal Saturation Gradient
    final gradientS = LinearGradient(
      colors: [Colors.white, HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor()],
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    );
    final paintS = Paint()..shader = gradientS.createShader(rect);
    canvas.drawRect(rect, paintS);

    // Vertical Value Gradient (Linear multiplication)
    final gradientV = LinearGradient(
      colors: [Colors.transparent, Colors.black],
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
    );
    final paintV = Paint()..shader = gradientV.createShader(rect);
    canvas.drawRect(rect, paintV);

    // Draw Selector
    final pointerPos = Offset(
      saturation * size.width,
      (1 - value) * size.height,
    );

    final pointerPaint = Paint()
      ..color = value > 0.5 ? Colors.black : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(pointerPos, 6, pointerPaint);
  }

  @override
  bool shouldRepaint(SVSquarePainter oldDelegate) =>
      oldDelegate.hue != hue ||
      oldDelegate.saturation != saturation ||
      oldDelegate.value != value;
}

Future<Color?> showColorWheelPicker(BuildContext context, Color initialColor) {
  Color selectedColor = initialColor;
  return showDialog<Color>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Pick a Color',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: 300,
          child: ColorWheelPicker(
            initialColor: initialColor,
            onColorChanged: (color) => selectedColor = color,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(selectedColor),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
            child: const Text('Select'),
          ),
        ],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      );
    },
  );
}
