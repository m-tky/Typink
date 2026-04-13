import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../frb_generated.dart/api.dart' as bridge;
import '../frb_generated.dart/frb_generated.dart';
import '../frb_generated.dart/editor.dart';
import '../frb_generated.dart/vim_engine.dart' as v;
import 'headless_editor.dart';
import 'dart:typed_data';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'drawing_pad.dart';
import 'handwriting_canvas.dart';
import 'file_tree.dart';
import 'package:flutter/services.dart';
import 'providers.dart';
import 'theme_provider.dart';
import 'workspace_provider.dart';
import 'vim_provider.dart';
import 'package:pdfx/pdfx.dart'; // Ensure pdfx is imported for the preview

class TypstEditorPage extends ConsumerStatefulWidget {
  const TypstEditorPage({super.key});

  @override
  ConsumerState<TypstEditorPage> createState() => _TypstEditorPageState();
}

class _TypstEditorPageState extends ConsumerState<TypstEditorPage> with WidgetsBindingObserver {
  late final FocusNode _focusNode;
  Timer? _compileDebounceTimer;
  bool _isExplorerVisible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (mounted) setState(() {});
    });
    
    // Request focus after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });

    // 自動保存の再設定
    Future.microtask(() => ref.read(persistenceProvider).setupAutoSave());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _compileDebounceTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      ref.read(persistenceProvider).flush();
    }
  }

  Future<void> _addOrEditDrawing([String? existingId]) async {
    final stateMap = ref.read(handwritingProvider);
    String id;
    if (existingId != null) {
      id = existingId;
    } else {
      int nextIndex = 1;
      while (stateMap.containsKey('fig_$nextIndex')) {
        nextIndex++;
      }
      id = 'fig_$nextIndex';
    }

    final result = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      pageBuilder: (context, anim1, anim2) {
        return DrawingPad(figureId: id);
      },
    );

    if (result == true) {
      final notifier = ref.read(handwritingProvider.notifier);
      final persistence = ref.read(persistenceProvider);

      await persistence.saveFigure(
        id, 
        notifier.toSvg(id),
        jsonEncode({id: (ref.read(handwritingProvider)[id] ?? []).map((s) => s.toJson()).toList()}),
      );

      if (existingId == null) {
        final relWidth = notifier.calculateRelativeWidth(id);
        String widthStr = '100%';
        if (relWidth < 0.3) widthStr = '40%';
        else if (relWidth < 0.7) widthStr = '70%';

        final snippet = '\n#figure(\n  image("figures/$id.svg", width: $widthStr),\n  caption: [$id],\n)\n';
        // TODO: Bridge this to Rust headless editor in a future step
        debugPrint('Added figure snippet: $snippet');
      }
      // Trigger compilation/persistence via provider update if necessary
    }
  }

  void _cleanGhostFigures(String text) {
    final regExp = RegExp(r'figures/(fig_\d+)\.svg');
    final matches = regExp.allMatches(text);
    final referencedIds = matches.map((m) => m.group(1)).toSet();

    final currentMap = ref.read(handwritingProvider);
    final existingIds = currentMap.keys.toSet();
    final deadIds = existingIds.difference(referencedIds);
    if (deadIds.isNotEmpty) {
      final newState = Map<String, List<Stroke>>.from(currentMap);
      for (final id in deadIds) {
        newState.remove(id);
      }
      Future.microtask(() {
        ref.read(handwritingProvider.notifier).state = newState;
      });
    }
  }

  void _deleteActiveFigure(String id) {
    final newState = Map<String, List<Stroke>>.from(ref.read(handwritingProvider));
    newState.remove(id);
    ref.read(handwritingProvider.notifier).state = newState;
    
    // TODO: Bridge delete figure to Rust
    ref.read(activeFigureIdProvider.notifier).state = null;
  }

  @override
  Widget build(BuildContext context) {
    final vimMode = ref.watch(vimModeProvider);
    final compileResultAsync = ref.watch(typstCompileResultProvider);
    final theme = ref.watch(activeThemeDetailedProvider);
    final settings = ref.watch(settingsProvider);
    
    // Breaking the circular loop: The controller listener already handles updates.
    // We only need to sync FROM the provider when the document changes (dealt with in file tree).

    return Scaffold(
      backgroundColor: theme.editorBackground,
      appBar: AppBar(
        backgroundColor: theme.themeData.colorScheme.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(_isExplorerVisible ? Icons.menu_open : Icons.menu),
          onPressed: () => setState(() => _isExplorerVisible = !_isExplorerVisible),
          tooltip: 'Toggle Explorer',
        ),
        title: Text(
          ref.watch(documentTitleProvider),
          style: TextStyle(fontSize: 16, color: theme.editorTextColor),
        ),
        actions: [
          _buildThemeSelector(),
          IconButton(
            icon: const Icon(Icons.add_photo_alternate),
            onPressed: () => _addOrEditDrawing(),
            tooltip: 'Add Handwriting',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                if (_isExplorerVisible) const FileTree(),
                Expanded(
                  flex: 1,
                  child: Container(
                    color: theme.editorBackground,
                    padding: const EdgeInsets.all(16),
                    child: HeadlessEditorView(
                      focusNode: _focusNode,
                      initialContent: ref.read(rawContentProvider),
                      textStyle: TextStyle(
                        fontSize: 14.0,
                        fontFamily: settings.activeFont,
                        color: theme.editorTextColor,
                      ),
                      cursorColor: theme.themeData.colorScheme.primary,
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  flex: 1,
                  child: Container(
                    color: theme.previewBackground,
                    child: compileResultAsync.maybeWhen(
                      data: (result) => _buildPreview(result, isCompiling: false),
                      loading: () {
                        if (compileResultAsync.hasValue) {
                          final prev = compileResultAsync.value!;
                          if (prev.errors.isEmpty && prev.pages.isNotEmpty) {
                            return _buildPreview(prev, isCompiling: true);
                          }
                        }
                        return Center(child: CircularProgressIndicator());
                      },
                      orElse: () => Center(child: CircularProgressIndicator()),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _buildStatusBar(theme),
        ],
      ),
    );
  }

  Widget _buildStatusBar(AppTheme theme) {
    final mode = ref.read(vimModeProvider);
    final modeName = mode.name.toUpperCase();
    final modeColor = mode == v.VimMode.insert ? Colors.green : (mode == v.VimMode.visual ? Colors.orange : Colors.blue);

    return Container(
      height: 24,
      color: theme.themeData.colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            color: modeColor,
            child: Text(
              modeName,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Typink Pro - Headless Core Active',
            style: TextStyle(color: theme.editorTextColor.withOpacity(0.5), fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildThemeSelector() {
    return PopupMenuButton<AppThemeMode>(
      icon: const Icon(Icons.palette),
      onSelected: (mode) => ref.read(themeProvider.notifier).setTheme(mode),
      itemBuilder: (context) => [
        const PopupMenuItem(value: AppThemeMode.light, child: Text('Light')),
        const PopupMenuItem(value: AppThemeMode.dark, child: Text('Dark')),
        const PopupMenuItem(value: AppThemeMode.catppuccin, child: Text('Catppuccin')),
      ],
    );
  }


  Widget _buildPreview(bridge.TypstCompileResult result, {required bool isCompiling}) {
    final pages = result.pages;
    final errors = result.errors;
    final activeId = ref.watch(activeFigureIdProvider);

    final settings = ref.watch(settingsProvider);

    final children = <Widget>[];
    if (pages.isNotEmpty) {
      children.add(
        settings.horizontalPreview 
        ? PageView.builder(
            itemCount: pages.length,
            itemBuilder: (context, index) {
              final image = pages[index].image;
              return Padding(
                padding: const EdgeInsets.all(24),
                child: _buildPageItem(image, activeId),
              );
            },
          )
        : ListView.separated(
            padding: const EdgeInsets.all(24),
            itemCount: pages.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final image = pages[index].image;
              return _buildPageItem(image, activeId);
            },
          )
      );
    } else if (errors.isEmpty && !isCompiling) {
      children.add(Center(child: Text('No Output', style: TextStyle(color: Colors.grey))));
    }

    children.add(
      Positioned(
        bottom: 16,
        right: 16,
        child: FloatingActionButton(
          mini: true,
          heroTag: 'edit',
          child: Icon(Icons.edit_note),
          onPressed: () {
            final stateMap = ref.read(handwritingProvider);
            if (stateMap.isEmpty) {
              _addOrEditDrawing();
            } else {
              showModalBottomSheet(
                context: context,
                builder: (context) {
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(title: Text('Select figure to edit', style: TextStyle(fontWeight: FontWeight.bold))),
                      ...stateMap.keys.map((id) {
                        final isEditable = ref.read(handwritingProvider.notifier).isEditable(id);
                        return ListTile(
                          leading: Icon(isEditable ? Icons.brush : Icons.visibility, color: isEditable ? null : Colors.grey),
                          title: Text(id + (isEditable ? '' : ' (Ready-Only)')),
                          onTap: isEditable ? () {
                            Navigator.pop(context);
                            _addOrEditDrawing(id);
                          } : null,
                          trailing: IconButton(
                            icon: Icon(Icons.delete, color: Colors.red),
                            onPressed: () {
                              Navigator.pop(context);
                              _deleteActiveFigure(id);
                            },
                          ),
                        );
                      }),
                      ListTile(
                        leading: Icon(Icons.add),
                        title: Text('Add new drawing'),
                        onTap: () {
                          Navigator.pop(context);
                          _addOrEditDrawing();
                        },
                      ),
                    ],
                  );
                },
              );
            }
          },
        ),
      ),
    );

    if (errors.isNotEmpty) {
      children.add(
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            constraints: BoxConstraints(maxHeight: 200),
            color: Colors.red.withOpacity(0.9),
            padding: EdgeInsets.all(8),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: errors.length,
              itemBuilder: (context, index) {
                final err = errors[index];
                return ListTile(
                  dense: true,
                  title: Text(err.message, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: Text('Line: ${err.line + 1}, Column: ${err.column + 1}', style: TextStyle(color: Colors.white70)),
                  leading: Icon(Icons.error_outline, color: Colors.white),
                );
              },
            ),
          ),
        ),
      );
    }

    if (isCompiling) {
      children.add(
        Positioned(
          top: 16,
          right: 16,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent)),
                SizedBox(width: 8),
                Text('Compiling...', style: TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      );
    }

    return Stack(children: children);
  }

  Widget _buildPageItem(Uint8List image, String? activeId) {
    return Center(
      child: GestureDetector(
        onTap: () {
          if (activeId == null) {
            final stateMap = ref.read(handwritingProvider);
            if (stateMap.isNotEmpty) {
              ref.read(activeFigureIdProvider.notifier).state = stateMap.keys.last;
            } else {
              ref.read(activeFigureIdProvider.notifier).state = 'fig_1';
            }
          }
        },
        child: Container(
          decoration: BoxDecoration(
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20)],
          ),
          child: AspectRatio(
            aspectRatio: 210 / 297,
            child: Image.memory(
              image, 
              gaplessPlayback: true,
              fit: BoxFit.fill,
            ),
          ),
        ),
      ),
    );
  }
}
