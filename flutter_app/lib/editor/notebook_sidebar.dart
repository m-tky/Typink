import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'providers.dart';

class NotebookSidebar extends ConsumerStatefulWidget {
  const NotebookSidebar({super.key});

  @override
  ConsumerState<NotebookSidebar> createState() => _NotebookSidebarState();
}

class _NotebookSidebarState extends ConsumerState<NotebookSidebar> {
  List<File> _typFiles = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _refreshFiles();
  }

  Future<void> _refreshFiles() async {
    setState(() => _isLoading = true);
    final dir = ref.read(notebookPathProvider);
    if (dir != null && await dir.exists()) {
      final List<File> files = [];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.typ')) {
          files.add(entity);
        }
      }
      setState(() => _typFiles = files);
    }
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final currentDir = ref.watch(notebookPathProvider);
    final currentNote = ref.watch(documentTitleProvider);

    return Drawer(
      child: Column(
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Typink Notebooks',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text('Root: ${currentDir?.path ?? "Not Set"}',
                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: _refreshFiles,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Refresh'),
                  style: ElevatedButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          ),
          if (_isLoading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_typFiles.isEmpty)
            const Expanded(child: Center(child: Text('No .typ files found')))
          else
            Expanded(
              child: ListView.builder(
                itemCount: _typFiles.length,
                itemBuilder: (context, index) {
                  final file = _typFiles[index];
                  final name = p.basenameWithoutExtension(file.path);
                  final isCurrent = name == currentNote;

                  return ListTile(
                    leading: Icon(Icons.description,
                        color: isCurrent ? Colors.blue : null),
                    title: Text(name,
                        style: TextStyle(
                            fontWeight: isCurrent ? FontWeight.bold : null)),
                    selected: isCurrent,
                    onTap: () {
                      ref.read(persistenceProvider).loadNotebook(
                          currentDir!); // TODO: Support subdirs if needed
                      // Actually just update the content if it's the same dir
                      _openFile(file);
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openFile(File file) async {
    final content = await file.readAsString();
    ref.read(rawContentProvider.notifier).state = content;
    ref.read(debouncedContentProvider.notifier).state = content;
    // Note name is derived from filename in our current noteNameProvider
    // But wait, my noteNameProvider uses p.basename(dir.path).
    // I should probably update it to use the filename.
  }
}
