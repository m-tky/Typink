import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';
import 'color_picker.dart';
import 'package:path/path.dart' as p;

class SettingsPanel extends ConsumerWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionTitle(title: 'Application Theme'),
          DropdownButtonFormField<AppThemeMode>(
            value: settings.theme,
            decoration: const InputDecoration(labelText: 'Theme'),
            items: AppThemeMode.values.map((mode) {
              return DropdownMenuItem(
                value: mode, 
                child: Text(mode.name[0].toUpperCase() + mode.name.substring(1)),
              );
            }).toList(),
            onChanged: (val) {
              if (val != null) notifier.setTheme(val);
            },
          ),
          const Divider(height: 32),
          _SectionTitle(title: 'Preview Options'),
          SwitchListTile(
            title: const Text('Horizontal Page Flipping'),
            subtitle: const Text('Swipe left/right to change pages in preview'),
            value: settings.horizontalPreview,
            onChanged: (value) => notifier.toggleHorizontalPreview(),
          ),
          const Divider(height: 32),
          _SectionTitle(title: 'Editor Environment'),
          SwitchListTile(
            title: const Text('Vim Mode'),
            subtitle: const Text('Enable modal editing (Normal/Insert modes)'),
            value: settings.vimEnabled,
            onChanged: (value) => notifier.toggleVimEnabled(),
          ),
          SwitchListTile(
            title: const Text('Relative Line Numbers'),
            subtitle: const Text('Show line numbers relative to cursor'),
            value: settings.relativeLineNumbers,
            onChanged: (value) => notifier.toggleRelativeLineNumbers(),
          ),
          SwitchListTile(
            title: const Text('Show Whitespace Symbols'),
            subtitle: const Text('Show indicators for newlines and wraps'),
            value: settings.showWhitespace,
            onChanged: (value) => notifier.toggleShowWhitespace(),
          ),
          const Divider(height: 32),
          _SectionTitle(title: 'Toolbar Position'),
          Wrap(
            spacing: 8,
            children: ToolbarPosition.values.map((pos) {
              return ChoiceChip(
                label: Text(pos.name.toUpperCase()),
                selected: settings.toolbarPosition == pos,
                onSelected: (selected) {
                  if (selected) notifier.setToolbarPosition(pos);
                },
              );
            }).toList(),
          ),
          const Divider(height: 32),
          _SectionTitle(title: 'Quick Palette'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ...settings.palette.asMap().entries.map((entry) {
                final index = entry.key;
                final color = entry.value;
                return GestureDetector(
                  onLongPress: () async {
                    final newColor = await showColorWheelPicker(context, color);
                    if (newColor != null) {
                      notifier.replacePaletteColor(index, newColor);
                    }
                  },
                  onDoubleTap: () {
                    final newList = settings.palette.where((c) => c != color).toList();
                    notifier.setPalette(newList);
                  },
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.grey[300]!, width: 2),
                    ),
                  ),
                );
              }),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () async {
                  final color = await showColorWheelPicker(context, Colors.blue);
                  if (color != null) {
                    notifier.setPalette([...settings.palette, color]);
                  }
                },
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Long press: change, Double tap: remove', 
                    style: TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ),
                TextButton(
                  onPressed: () => notifier.resetPalette(),
                  child: const Text('Reset Defaults', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          const Divider(height: 32),
          _SectionTitle(title: 'Fonts'),
          DropdownButtonFormField<String>(
            value: settings.activeFont,
            decoration: const InputDecoration(labelText: 'Preview Font (Typst)'),
            items: [
              'IBM Plex Sans',
              'Moralerspace Argon',
              'Inter',
              settings.activeFont,
              ...settings.customFontPaths.map((path) => p.basenameWithoutExtension(path)),
            ].toSet().map((font) {
              return DropdownMenuItem(value: font, child: Text(font));
            }).toList(),
            onChanged: (val) {
              if (val != null) notifier.setActiveFont(val);
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: settings.editorFont,
            decoration: const InputDecoration(labelText: 'Editor Font'),
            items: [
              'Moralerspace Argon',
              'IBM Plex Mono',
              'Fira Code',
              'JetBrains Mono',
              'Inter',
              settings.editorFont,
              ...settings.customFontPaths.map((path) => p.basenameWithoutExtension(path)),
            ].toSet().map((font) {
              return DropdownMenuItem(value: font, child: Text(font));
            }).toList(),
            onChanged: (val) {
              if (val != null) notifier.setEditorFont(val);
            },
          ),
          const SizedBox(height: 16),
          const Text('Custom Font Paths (Notebook):', style: TextStyle(fontWeight: FontWeight.bold)),
          ...settings.customFontPaths.map((path) => ListTile(
            dense: true,
            title: Text(p.basename(path), style: const TextStyle(fontSize: 12)),
            subtitle: Text(path, style: const TextStyle(fontSize: 10)),
            trailing: IconButton(
              icon: const Icon(Icons.delete, size: 16),
              onPressed: () => notifier.removeFontPath(path),
            ),
          )),
          TextButton.icon(
            onPressed: () => _addFontPath(context, ref, notifier),
            icon: const Icon(Icons.add),
            label: const Text('Add External Font File'),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Center(child: Text('Typink v1.0.0', style: TextStyle(color: Colors.grey[600], fontSize: 12))),
          ),
        ],
      ),
    );
  }

  void _addFontPath(BuildContext context, WidgetRef ref, SettingsNotifier notifier) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Font File'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '/absolute/path/to/font.ttf',
            labelText: 'Absolute Path to .ttf or .otf',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                final relPath = await ref.read(persistenceProvider).copyFontToNotebook(controller.text);
                if (relPath != null) {
                  notifier.addFontPath(relPath);
                }
              }
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Add & Copy'),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.blue)),
    );
  }
}
