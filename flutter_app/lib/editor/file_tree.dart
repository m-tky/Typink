import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'workspace_provider.dart';
import 'providers.dart';

class FileTree extends ConsumerWidget {
  const FileTree({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspaceDir = ref.watch(workspacePathProvider);
    if (workspaceDir == null) return const SizedBox.shrink();

    return Container(
      width: 250,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'EXPLORER',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 16),
                  onPressed: () => ref.refresh(workspacePathProvider),
                  tooltip: 'Refresh',
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              children: [
                _buildSectionTitle('Documents'),
                ..._buildFileList(workspaceDir, ref, context, isTyp: true),
                const SizedBox(height: 16),
                _buildSectionTitle('Figures'),
                ..._buildFileList(workspaceDir, ref, context, isTyp: false),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.grey),
      ),
    );
  }

  List<Widget> _buildFileList(Directory workspace, WidgetRef ref, BuildContext context, {required bool isTyp}) {
    final activeFile = ref.watch(currentTypFileProvider);
    
    // Simple list for now. Typst files in root, SVGs in /figures.
    if (isTyp) {
      final List<File> files = workspace.listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.typ'))
          .toList();
      
      return files.map((file) {
        final isActive = activeFile?.path == file.path;
        return ListTile(
          dense: true,
          leading: Icon(Icons.description, size: 16, color: isActive ? Colors.blue : null),
          title: Text(p.basename(file.path)),
          selected: isActive,
          onTap: () async {
             // Load the file content into the editor buffer
             final content = await file.readAsString();
             ref.read(currentTypFileProvider.notifier).state = file;
             ref.read(rawContentProvider.notifier).state = content;
             // TypstEditorPage should have a way to update its controller.
          },
        );
      }).toList();
    } else {
      final figuresDir = Directory(p.join(workspace.path, 'figures'));
      if (!figuresDir.existsSync()) return [];
      
      final List<File> files = figuresDir.listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.svg'))
          .toList();
      
      return files.map((file) {
        return ListTile(
          dense: true,
          leading: const Icon(Icons.image, size: 16),
          title: Text(p.basename(file.path)),
          onTap: () {
            // Future: Show SVG preview or copy reference
          },
        );
      }).toList();
    }
  }
}
