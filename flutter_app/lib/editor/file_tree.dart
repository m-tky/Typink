import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'workspace_provider.dart';
import 'providers.dart';

class FileTree extends ConsumerStatefulWidget {
  final void Function(String path)? onFileSelected;
  final void Function(String id)? onSvgSelected;
  const FileTree({super.key, this.onFileSelected, this.onSvgSelected});

  @override
  ConsumerState<FileTree> createState() => _FileTreeState();
}

class _FileTreeState extends ConsumerState<FileTree> {
  final Set<String> _expandedDirs = {};

  @override
  Widget build(BuildContext context) {
    final workspaceDir = ref.watch(workspacePathProvider);
    if (workspaceDir == null) return const SizedBox.shrink();

    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
            right:
                BorderSide(color: Theme.of(context).dividerColor, width: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context, workspaceDir.path),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: _buildTree(workspaceDir, 0),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, String rootPath) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'EXPLORER',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
          Row(
            children: [
              _HeaderAction(
                icon: Icons.note_add_outlined,
                tooltip: 'New File',
                onPressed: () => _createNewFile(rootPath),
              ),
              _HeaderAction(
                icon: Icons.create_new_folder_outlined,
                tooltip: 'New Folder',
                onPressed: () => _createNewFolder(rootPath),
              ),
              _HeaderAction(
                icon: Icons.refresh,
                tooltip: 'Refresh',
                onPressed: () => ref.refresh(workspacePathProvider),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _createNewFile(String parentPath) async {
    final name = await _showRenameDialog(context,
        title: 'New File', initialValue: 'untitled.typ');
    if (name != null && name.isNotEmpty) {
      await ref
          .read(workspaceManagerProvider)
          .createFile(name, parentPath: parentPath);
    }
  }

  void _createNewFolder(String parentPath) async {
    final name = await _showRenameDialog(context,
        title: 'New Folder', initialValue: 'new_folder');
    if (name != null && name.isNotEmpty) {
      await ref
          .read(workspaceManagerProvider)
          .createFolder(name, parentPath: parentPath);
    }
  }

  void _moveEntity(FileSystemEntity entity) async {
    final workspaceDir = ref.read(workspacePathProvider);
    if (workspaceDir == null) return;

    final List<Directory> allDirs = _getAllDirectories(workspaceDir);

    final targetParent = await showDialog<Directory>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move to...'),
        content: SizedBox(
          width: 300,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: allDirs.length,
            itemBuilder: (context, index) {
              final dir = allDirs[index];
              final relPath = p.relative(dir.path, from: workspaceDir.path);
              return ListTile(
                leading: const Icon(Icons.folder_outlined, size: 18),
                title: Text(relPath == '.' ? '/' : relPath,
                    style: const TextStyle(fontSize: 13)),
                onTap: () => Navigator.pop(context, dir),
              );
            },
          ),
        ),
      ),
    );

    if (targetParent != null) {
      await ref
          .read(workspaceManagerProvider)
          .moveEntity(entity, targetParent.path);
    }
  }

  List<Directory> _getAllDirectories(Directory root) {
    final List<Directory> dirs = [root];
    try {
      final List<FileSystemEntity> entities = root.listSync(recursive: true);
      dirs.addAll(entities
          .whereType<Directory>()
          .where((d) => !p.basename(d.path).startsWith('.')));
    } catch (_) {}
    return dirs;
  }

  List<Widget> _buildTree(Directory dir, int level) {
    final List<Widget> widgets = [];
    final List<FileSystemEntity> entities = dir.listSync()
      ..sort((a, b) {
        if (a is Directory && b is! Directory) return -1;
        if (a is! Directory && b is Directory) return 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });

    for (final entity in entities) {
      final isDir = entity is Directory;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;

      widgets.add(
        FileTreeItem(
          entity: entity,
          level: level,
          isExpanded: _expandedDirs.contains(entity.path),
          onTap: () {
            if (isDir) {
              setState(() {
                if (_expandedDirs.contains(entity.path)) {
                  _expandedDirs.remove(entity.path);
                } else {
                  _expandedDirs.add(entity.path);
                }
              });
            } else {
              final file = entity as File;
              final extension = p.extension(file.path).toLowerCase();

              // Always update selectedFileProvider for any file
              ref.read(selectedFileProvider.notifier).state = file;

              if (extension == '.typ' || extension == '.typst') {
                ref.read(currentTypFileProvider.notifier).state = file;
                ref.read(workspaceManagerProvider).saveLastFile(file.path);
                widget.onFileSelected?.call(file.path);
              } else if (extension == '.svg') {
                // If it's an SVG, we just select it.
                // The main page will decide whether to show a viewer or a drawing pad.
                // For now, let's keep the existing drawing pad behavior if it's already used that way,
                // but we also allow viewing it in the preview area.
              } else if (extension == '.json') {
                // Similarly for JSON
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(
                          'Unsupported file type: ${p.basename(file.path)}')),
                );
              }
            }
          },
          onRename: (newName) async {
            await ref
                .read(workspaceManagerProvider)
                .renameEntity(entity, newName);
          },
          onDelete: () async {
            final confirm = await _showConfirmDelete(context, name);
            if (confirm == true) {
              await ref.read(workspaceManagerProvider).deleteEntity(entity);
            }
          },
          onMove: () => _moveEntity(entity),
          onCreateFile: isDir ? () => _createNewFile(entity.path) : null,
          onCreateFolder: isDir ? () => _createNewFolder(entity.path) : null,
        ),
      );

      if (isDir && _expandedDirs.contains(entity.path)) {
        widgets.addAll(_buildTree(entity as Directory, level + 1));
      }
    }
    return widgets;
  }

  Future<bool?> _showConfirmDelete(BuildContext context, String name) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete'),
        content: Text('Are you sure you want to delete $name?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class FileTreeItem extends ConsumerStatefulWidget {
  final FileSystemEntity entity;
  final int level;
  final bool isExpanded;
  final VoidCallback onTap;
  final Function(String) onRename;
  final VoidCallback onDelete;
  final VoidCallback onMove;
  final VoidCallback? onCreateFile;
  final VoidCallback? onCreateFolder;

  const FileTreeItem({
    super.key,
    required this.entity,
    required this.level,
    required this.isExpanded,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    required this.onMove,
    this.onCreateFile,
    this.onCreateFolder,
  });

  @override
  ConsumerState<FileTreeItem> createState() => _FileTreeItemState();
}

class _FileTreeItemState extends ConsumerState<FileTreeItem> {
  bool _isHovered = false;
  bool _isEditing = false;
  late TextEditingController _renameController;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _renameController = TextEditingController(
        text: p.basenameWithoutExtension(widget.entity.path));
  }

  @override
  void dispose() {
    _renameController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startEditing() {
    setState(() {
      _isEditing = true;
      _renameController.text = p.basenameWithoutExtension(widget.entity.path);
    });
    _focusNode.requestFocus();
  }

  void _submitRename() {
    if (_isEditing) {
      final newName = _renameController.text.trim();
      if (newName.isNotEmpty &&
          newName != p.basenameWithoutExtension(widget.entity.path)) {
        widget.onRename(newName);
      }
      setState(() => _isEditing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDir = widget.entity is Directory;
    final name = p.basename(widget.entity.path);
    final extension = isDir ? '' : p.extension(widget.entity.path);
    final isActive =
        !isDir && ref.watch(selectedFileProvider)?.path == widget.entity.path;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onSecondaryTapDown: (details) =>
            _showContextMenu(context, details.globalPosition),
        child: InkWell(
          onTap: _isEditing ? null : widget.onTap,
          child: Container(
            height: 28,
            padding:
                EdgeInsets.only(left: 12.0 + (widget.level * 12.0), right: 8),
            color: isActive
                ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
                : (_isHovered
                    ? Theme.of(context).hoverColor
                    : Colors.transparent),
            child: Row(
              children: [
                _buildLeadingIcon(
                    isDir, widget.isExpanded, extension, isActive),
                const SizedBox(width: 6),
                Expanded(
                  child: _isEditing
                      ? TextField(
                          controller: _renameController,
                          focusNode: _focusNode,
                          autofocus: true,
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(vertical: 4),
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _submitRename(),
                          onTapOutside: (_) => _submitRename(),
                        )
                      : Text(
                          name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                isActive ? FontWeight.w600 : FontWeight.normal,
                            color: isActive
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withOpacity(0.8),
                          ),
                        ),
                ),
                if (_isHovered && !_isEditing)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isDir && widget.onCreateFile != null)
                        _ActionIcon(
                            icon: Icons.note_add_outlined,
                            onPressed: widget.onCreateFile!),
                      if (isDir && widget.onCreateFolder != null)
                        _ActionIcon(
                            icon: Icons.create_new_folder_outlined,
                            onPressed: widget.onCreateFolder!),
                      _ActionIcon(
                          icon: Icons.drive_file_move_outlined,
                          onPressed: widget.onMove),
                      _ActionIcon(
                          icon: Icons.delete_outline,
                          onPressed: widget.onDelete),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLeadingIcon(
      bool isDir, bool isExpanded, String extension, bool isActive) {
    if (isDir) {
      return Icon(
        isExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
        size: 18,
        color: Colors.grey,
      );
    }
    IconData iconData = Icons.insert_drive_file_outlined;
    Color iconColor = Colors.grey;
    if (extension == '.typ' || extension == '.typst') {
      iconData = Icons.description;
      iconColor = isActive ? Colors.blue : Colors.blue.withOpacity(0.7);
    } else if (extension == '.svg') {
      iconData = Icons.image_outlined;
      iconColor = Colors.orange.withOpacity(0.7);
    } else if (extension == '.json') {
      iconData = Icons.settings_ethernet;
      iconColor = Colors.green.withOpacity(0.7);
    }
    return Icon(iconData, size: 16, color: iconColor);
  }

  void _showContextMenu(BuildContext context, Offset position) {
    final List<PopupMenuEntry> items = [];

    if (widget.onCreateFile != null) {
      items.add(
        PopupMenuItem(
          child: const Row(children: [
            Icon(Icons.note_add, size: 18),
            SizedBox(width: 8),
            Text('New File')
          ]),
          onTap: () => Future.microtask(widget.onCreateFile!),
        ),
      );
      items.add(
        PopupMenuItem(
          child: const Row(children: [
            Icon(Icons.create_new_folder, size: 18),
            SizedBox(width: 8),
            Text('New Folder')
          ]),
          onTap: () => Future.microtask(widget.onCreateFolder!),
        ),
      );
      items.add(const PopupMenuDivider());
    }

    items.addAll([
      PopupMenuItem(
        child: const Row(children: [
          Icon(Icons.edit, size: 18),
          SizedBox(width: 8),
          Text('Rename')
        ]),
        onTap: () => Future.microtask(_startEditing),
      ),
      PopupMenuItem(
        child: const Row(children: [
          Icon(Icons.drive_file_move, size: 18),
          SizedBox(width: 8),
          Text('Move to...')
        ]),
        onTap: () => Future.microtask(widget.onMove),
      ),
      PopupMenuItem(
        child: const Row(children: [
          Icon(Icons.delete, size: 18, color: Colors.red),
          SizedBox(width: 8),
          Text('Delete', style: TextStyle(color: Colors.red))
        ]),
        onTap: () => Future.microtask(widget.onDelete),
      ),
    ]);

    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx, position.dy),
      items: items,
    );
  }
}

class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  const _HeaderAction(
      {required this.icon, required this.tooltip, required this.onPressed});
  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      onPressed: onPressed,
      tooltip: tooltip,
      splashRadius: 14,
    );
  }
}

class _ActionIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  const _ActionIcon({required this.icon, required this.onPressed});
  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 14),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      onPressed: onPressed,
      splashRadius: 11,
      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
    );
  }
}

Future<String?> _showRenameDialog(BuildContext context,
    {required String title, required String initialValue}) async {
  final controller = TextEditingController(text: initialValue);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(isDense: true),
        onSubmitted: (val) => Navigator.pop(context, val),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('OK')),
      ],
    ),
  );
}
