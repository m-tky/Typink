import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'handwriting_canvas.dart';
import 'providers.dart';
import 'color_picker.dart';
import 'settings_panel.dart';

class DrawingPad extends ConsumerStatefulWidget {
  final String figureId;
  const DrawingPad({super.key, required this.figureId});

  @override
  ConsumerState<DrawingPad> createState() => _DrawingPadState();
}

class _DrawingPadState extends ConsumerState<DrawingPad> {
  bool _showGrid = true;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(handwritingProvider.notifier);
    final activeTool = ref.watch(activeToolProvider);
    final activeColor = ref.watch(activeColorProvider);
    final activeWidth = activeTool == DrawingTool.pen
        ? ref.watch(penWidthProvider)
        : ref.watch(eraserWidthProvider);

    final isVertical = settings.toolbarPosition == ToolbarPosition.left ||
        settings.toolbarPosition == ToolbarPosition.right;

    return Scaffold(
      backgroundColor: Colors.black.withOpacity(0.3),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: Text('Editing ${widget.figureId}',
            style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: Icon(_showGrid ? Icons.grid_on : Icons.grid_off),
            tooltip: 'Toggle Grid',
            onPressed: () => setState(() => _showGrid = !_showGrid),
          ),
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Undo',
            onPressed: () => notifier.undo(widget.figureId),
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            tooltip: 'Redo',
            onPressed: () => notifier.redo(widget.figureId),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.save),
            label: const Text('Save & Close'),
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
          ),
          const SizedBox(width: 8),
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Settings',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const SettingsPanel()),
              ),
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: _buildLayout(
          isVertical, settings, activeTool, activeColor, activeWidth, notifier),
    );
  }

  Widget _buildLayout(
      bool isVertical,
      AppSettings settings,
      DrawingTool activeTool,
      Color activeColor,
      double activeWidth,
      HandwritingNotifier notifier) {
    final canvas = Expanded(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: AspectRatio(
            aspectRatio: 1333 / 1000,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.8),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 20,
                      spreadRadius: 5),
                ],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Stack(
                children: [
                  if (_showGrid) const GridBackground(),
                  HandwritingCanvas(figureId: widget.figureId),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final toolbar = _Toolbar(
      settings: settings,
      activeTool: activeTool,
      activeColor: activeColor,
      activeWidth: activeWidth,
      notifier: notifier,
      figureId: widget.figureId,
    );

    if (isVertical) {
      return Row(
        children: settings.toolbarPosition == ToolbarPosition.left
            ? [toolbar, canvas]
            : [canvas, toolbar],
      );
    } else {
      return Column(
        children: settings.toolbarPosition == ToolbarPosition.top
            ? [toolbar, canvas]
            : [canvas, toolbar],
      );
    }
  }
}

class _Toolbar extends ConsumerWidget {
  final AppSettings settings;
  final DrawingTool activeTool;
  final Color activeColor;
  final double activeWidth;
  final HandwritingNotifier notifier;
  final String figureId;

  const _Toolbar({
    required this.settings,
    required this.activeTool,
    required this.activeColor,
    required this.activeWidth,
    required this.notifier,
    required this.figureId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isVertical = settings.toolbarPosition == ToolbarPosition.left ||
        settings.toolbarPosition == ToolbarPosition.right;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: _getBorderRadius(),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10)
        ],
      ),
      child: SafeArea(
        child: isVertical
            ? _buildVertical(context, ref)
            : _buildHorizontal(context, ref),
      ),
    );
  }

  BorderRadius _getBorderRadius() {
    switch (settings.toolbarPosition) {
      case ToolbarPosition.top:
        return const BorderRadius.vertical(bottom: Radius.circular(16));
      case ToolbarPosition.bottom:
        return const BorderRadius.vertical(top: Radius.circular(16));
      case ToolbarPosition.left:
        return const BorderRadius.horizontal(right: Radius.circular(16));
      case ToolbarPosition.right:
        return const BorderRadius.horizontal(left: Radius.circular(16));
    }
  }

  Widget _buildHorizontal(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _buildTools(ref, false),
            const SizedBox(width: 8),
            Container(height: 32, width: 1, color: Colors.white24),
            const SizedBox(width: 8),
            Expanded(child: _buildColors(context, ref, false)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _buildWidthSlider(ref, false)),
            IconButton(
              icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
              onPressed: () => notifier.clear(figureId),
              tooltip: 'Clear Canvas',
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildVertical(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildTools(ref, true),
          const SizedBox(height: 16),
          Container(width: 32, height: 1, color: Colors.white24),
          const SizedBox(height: 16),
          _buildColors(context, ref, true),
          const SizedBox(height: 16),
          _buildWidthSlider(ref, true),
          const SizedBox(height: 8),
          IconButton(
            icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
            onPressed: () => notifier.clear(figureId),
            tooltip: 'Clear Canvas',
          ),
        ],
      ),
    );
  }

  Widget _buildTools(WidgetRef ref, bool vertical) {
    final children = [
      _ToolButton(
        icon: Icons.brush,
        label: 'Pen',
        isSelected: activeTool == DrawingTool.pen,
        onTap: () =>
            ref.read(activeToolProvider.notifier).state = DrawingTool.pen,
      ),
      _ToolButton(
        icon: Icons.cleaning_services,
        label: 'Eraser',
        isSelected: activeTool == DrawingTool.eraser,
        onTap: () =>
            ref.read(activeToolProvider.notifier).state = DrawingTool.eraser,
      ),
      _ToolButton(
        icon: Icons.gesture,
        label: 'Lasso',
        isSelected: activeTool == DrawingTool.lasso,
        onTap: () =>
            ref.read(activeToolProvider.notifier).state = DrawingTool.lasso,
      ),
    ];
    return vertical ? Column(children: children) : Row(children: children);
  }

  Widget _buildColors(BuildContext context, WidgetRef ref, bool vertical) {
    final children = [
      ...settings.palette.asMap().entries.map((entry) {
        final index = entry.key;
        final color = entry.value;
        final isSelected = activeColor == color;
        return GestureDetector(
          onTap: () {
            ref.read(activeColorProvider.notifier).state = color;
            ref.read(activeToolProvider.notifier).state = DrawingTool.pen;
          },
          onLongPress: () async {
            final newColor = await showColorWheelPicker(context, color);
            if (newColor != null) {
              ref
                  .read(settingsProvider.notifier)
                  .replacePaletteColor(index, newColor);
              ref.read(activeColorProvider.notifier).state = newColor;
            }
          },
          child: Container(
            margin: const EdgeInsets.all(4),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? Colors.white : Colors.transparent,
                width: 3,
              ),
              boxShadow: isSelected
                  ? [BoxShadow(color: color.withOpacity(0.5), blurRadius: 8)]
                  : null,
            ),
          ),
        );
      }),
      // Color Wheel Button
      GestureDetector(
        onTap: () async {
          final newColor = await showColorWheelPicker(context, activeColor);
          if (newColor != null) {
            ref.read(activeColorProvider.notifier).state = newColor;
            ref.read(activeToolProvider.notifier).state = DrawingTool.pen;
          }
        },
        child: Container(
          margin: const EdgeInsets.all(4),
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const SweepGradient(
              colors: [
                Colors.red,
                Colors.yellow,
                Colors.green,
                Colors.cyan,
                Colors.blue,
                Colors.purple,
                Colors.red
              ],
            ),
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 4)
            ],
          ),
          child: const Center(
              child: Icon(Icons.colorize, size: 16, color: Colors.white)),
        ),
      ),
    ];

    final isEraser = activeTool == DrawingTool.eraser;
    final paletteWidget = vertical
        ? Column(mainAxisSize: MainAxisSize.min, children: children)
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal, child: Row(children: children));

    return Opacity(
      opacity: isEraser ? 0.3 : 1.0,
      child: AbsorbPointer(
        absorbing: isEraser,
        child: paletteWidget,
      ),
    );
  }

  Widget _buildWidthSlider(WidgetRef ref, bool vertical) {
    final activeWidth = activeTool == DrawingTool.pen
        ? ref.watch(penWidthProvider)
        : ref.watch(eraserWidthProvider);
    final widthNotifier = activeTool == DrawingTool.pen
        ? ref.read(penWidthProvider.notifier)
        : ref.read(eraserWidthProvider.notifier);

    final min = activeTool == DrawingTool.pen ? 1.0 : 5.0;
    final max = activeTool == DrawingTool.pen ? 15.0 : 60.0;
    final divisions = activeTool == DrawingTool.pen ? 14 : 11;

    final slider = SliderTheme(
      data: SliderTheme.of(ref.context).copyWith(
        activeTrackColor: Colors.blue,
        thumbColor: Colors.blue,
        overlayColor: Colors.blue.withAlpha(32),
      ),
      child: vertical
          ? RotatedBox(
              quarterTurns: 3,
              child: Slider(
                value: activeWidth,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: (val) => widthNotifier.state = val,
              ),
            )
          : Slider(
              value: activeWidth,
              min: min,
              max: max,
              divisions: divisions,
              label: activeWidth.round().toString(),
              onChanged: (val) => widthNotifier.state = val,
            ),
    );

    if (vertical) {
      return Column(
        children: [
          const Icon(Icons.line_weight, color: Colors.white70, size: 20),
          const SizedBox(height: 8),
          slider,
          const SizedBox(height: 8),
          Text('${activeWidth.round()}',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      );
    } else {
      return Row(
        children: [
          const Icon(Icons.line_weight, color: Colors.white70, size: 20),
          const SizedBox(width: 12),
          Expanded(child: slider),
          const SizedBox(width: 8),
          Text('${activeWidth.round()}',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      );
    }
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _ToolButton({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white10 : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                color: isSelected ? Colors.blue : Colors.white70, size: 20),
            Text(label,
                style: TextStyle(
                    color: isSelected ? Colors.blue : Colors.white70,
                    fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

class GridBackground extends StatelessWidget {
  const GridBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: GridPainter(),
      size: Size.infinite,
    );
  }
}

class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blue.withOpacity(0.1)
      ..strokeWidth = 1.0;

    final double unitSizeX = size.width / 1333.0;
    final double unitSizeY = size.height / 1000.0;

    for (double i = 0; i <= 1333; i += 100) {
      final x = i * unitSizeX;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double i = 0; i <= 1000; i += 100) {
      final y = i * unitSizeY;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
