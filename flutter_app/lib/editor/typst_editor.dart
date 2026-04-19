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
import 'package:flutter_svg/flutter_svg.dart';

class TypstEditorPage extends ConsumerStatefulWidget {
  const TypstEditorPage({super.key});

  @override
  ConsumerState<TypstEditorPage> createState() => _TypstEditorPageState();
}

class _TypstEditorPageState extends ConsumerState<TypstEditorPage> with WidgetsBindingObserver {
  late final FocusNode _focusNode;
  final GlobalKey<HeadlessEditorViewState> _editorKey = GlobalKey();
  Timer? _compileDebounceTimer;
  bool _isExplorerVisible = true;
  late final PageController _pageController;
  final GlobalKey _mainAreaKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (mounted) setState(() {});
    });
    
    _pageController = PageController(initialPage: ref.read(currentPageProvider));
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
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      ref.read(persistenceProvider).flush();
    }
  }

  Future<void> _addOrEditDrawing([String? existingId]) async {
    final state = ref.read(handwritingProvider);
    final currentFile = ref.read(currentTypFileProvider);
    if (currentFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select or create a .typ file first')),
      );
      return;
    }
    
    final fileNameNoExt = p.basenameWithoutExtension(currentFile.path);
    final targetDir = p.join(currentFile.parent.path, fileNameNoExt);

    String id;
    if (existingId != null) {
      id = existingId;
    } else {
      int nextIndex = 1;
      while (state.figures.containsKey('fig_$nextIndex')) {
        nextIndex++;
      }
      id = 'fig_$nextIndex';
    }

    debugPrint('Opening DrawingPad for figure ID: $id at $targetDir');

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
        jsonEncode({id: (ref.read(handwritingProvider).figures[id] ?? []).map((s) => s.toJson()).toList()}),
        targetDir: targetDir,
      );

      if (existingId == null) {
        final relWidth = notifier.calculateRelativeWidth(id);
        String widthStr = '100%';
        if (relWidth < 0.3) widthStr = '40%';
        else if (relWidth < 0.7) widthStr = '70%';

        // 挿入するSnippet
        // insertAfterCurrentLine: true を使うので、Snippet側では余計な先頭改行を控える（1つの改行で十分）
        final snippet = '\n#figure(\n  image("$fileNameNoExt/$id.svg", width: $widthStr),\n  caption: [$id],\n)\n';
        debugPrint('Inserting figure snippet after current line: $snippet');
        
        // エディタの現在の行の直後に挿入
        _editorKey.currentState?.insertText(snippet, insertAfterCurrentLine: true);
      }
    }
  }

  void _cleanGhostFigures(String text) {
    final regExp = RegExp(r'figures/(fig_\d+)\.svg');
    final matches = regExp.allMatches(text);
    final referencedIds = matches.map((m) => m.group(1)).toSet();

    final currentMap = ref.read(handwritingProvider);
    final existingIds = currentMap.figures.keys.toSet();
    final deadIds = existingIds.difference(referencedIds);
    if (deadIds.isNotEmpty) {
      final newState = Map<String, List<Stroke>>.from(currentMap.figures);
      for (final id in deadIds) {
        newState.remove(id);
      }
      Future.microtask(() {
        final notifier = ref.read(handwritingProvider.notifier);
        notifier.state = notifier.state.copyWith(figures: newState);
      });
    }
  }

  void _deleteActiveFigure(String id) {
    final notifier = ref.read(handwritingProvider.notifier);
    final nextFigures = Map<String, List<Stroke>>.from(notifier.state.figures);
    nextFigures.remove(id);
    notifier.state = notifier.state.copyWith(figures: nextFigures);
    
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        
        final vimMode = ref.read(vimModeProvider);
        if (vimMode != v.VimMode.normal) {
          // Send Escape to the editor to return to normal mode
          _editorKey.currentState?.sendEsc();
        } else {
          // If already in normal mode, maybe we want to allow pop, 
          // but typically on Android we might want to confirm or just ignore.
          // For now, let's just ignore to prevent accidental exit.
          debugPrint('Pop requested in Normal mode, ignored.');
        }
      },
      child: Scaffold(
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
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.read(debouncedContentProvider.notifier).state = bridge.getEditorContent();
            },
            tooltip: 'Compile Now',
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: () => _editorKey.currentState?.save(),
            tooltip: 'Save',
          ),
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: _exportPdf,
            tooltip: 'Export PDF',
          ),
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
          const VerticalDivider(width: 1, indent: 12, endIndent: 12),
          _LayoutActionButton(
            icon: Icons.edit_note,
            mode: LayoutMode.editorOnly,
            tooltip: 'Editor Only',
          ),
          _LayoutActionButton(
            icon: Icons.article_outlined,
            mode: LayoutMode.previewOnly,
            tooltip: 'Preview Only',
          ),
          _LayoutActionButton(
            icon: Icons.view_quilt_outlined,
            mode: LayoutMode.split,
            tooltip: 'Split View',
          ),
          if (ref.watch(layoutModeProvider) == LayoutMode.split)
            _OrientationActionButton(),
          const SizedBox(width: 8),
        ],
      ),
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () => _turnPage(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () => _turnPage(1),
        },
        child: Column(
          children: [
          Expanded(
            child: Row(
              children: [
                if (_isExplorerVisible) FileTree(
                  onFileSelected: (path) {
                    ref.read(currentPageProvider.notifier).state = 0;
                    if (_pageController.hasClients) {
                      _pageController.jumpToPage(0);
                    }
                    _editorKey.currentState?.load(path);
                  },
                  onSvgSelected: (id) => _addOrEditDrawing(id),
                ),
                Expanded(
                  child: _buildMainArea(theme, settings),
                ),
              ],
            ),
          ),
          _buildStatusBar(theme),
        ],
        ),
      ),
    ),
  );
}

  void _turnPage(int delta) {
    if (!_pageController.hasClients) return;
    final compileResult = ref.read(typstCompileResultProvider);
    compileResult.whenData((result) {
      final totalPages = result.pages.length;
      if (totalPages <= 1) return;
      
      final currentPage = ref.read(currentPageProvider);
      final targetPage = (currentPage + delta).clamp(0, totalPages - 1);
      
      if (targetPage != currentPage) {
        _pageController.animateToPage(
          targetPage,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
        // Page view onPageChanged will update the provider
      }
    });
  }

  Widget _buildStatusBar(AppTheme theme) {
    final settings = ref.watch(settingsProvider);
    final mode = ref.watch(vimModeProvider);
    final modeName = settings.vimEnabled ? mode.name.toUpperCase() : 'EDITOR';
    final modeColor = !settings.vimEnabled ? Colors.grey : (mode == v.VimMode.insert ? Colors.green : (mode == v.VimMode.visual ? Colors.orange : Colors.blue));

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

  Widget _buildPreview(bridge.TypstCompileResult result, {required bool isCompiling}) {
    final pages = result.pages;
    final diagnostics = result.diagnostics;
    final activeId = ref.watch(activeFigureIdProvider);

    final settings = ref.watch(settingsProvider);

    final children = <Widget>[];
    if (pages.isNotEmpty) {
      children.add(
        settings.horizontalPreview 
        ? PageView.builder(
            controller: _pageController,
            itemCount: pages.length,
            onPageChanged: (index) => ref.read(currentPageProvider.notifier).state = index,
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
    } else if (diagnostics.isEmpty && !isCompiling) {
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
            final state = ref.read(handwritingProvider);
            if (state.figures.isEmpty) {
              _addOrEditDrawing();
            } else {
              showModalBottomSheet(
                context: context,
                builder: (context) {
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(title: Text('Select figure to edit', style: TextStyle(fontWeight: FontWeight.bold))),
                      ...state.figures.keys.map((id) {
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

    if (diagnostics.isNotEmpty) {
      final hasErrors = diagnostics.any((d) => d.severity == 1);
      children.add(
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            constraints: BoxConstraints(maxHeight: 200),
            color: (hasErrors ? Colors.red : Colors.orange).withOpacity(0.9),
            padding: EdgeInsets.all(8),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: diagnostics.length,
              itemBuilder: (context, index) {
                final diag = diagnostics[index];
                final isError = diag.severity == 1;
                return ListTile(
                  dense: true,
                  title: Text(diag.message, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: Text('Line: ${diag.line + 1}, Column: ${diag.column + 1}', style: TextStyle(color: Colors.white70)),
                  leading: Icon(isError ? Icons.error_outline : Icons.warning_amber_outlined, color: Colors.white),
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
            final state = ref.read(handwritingProvider);
            if (state.figures.isNotEmpty) {
              ref.read(activeFigureIdProvider.notifier).state = state.figures.keys.last;
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

  Future<void> _exportPdf() async {
    final result = await bridge.handleEditorGetTotalLines();
    if (result == 0) return;

    // Use file picker to select destination
    // For now, on Linux, we might just use a standard path or ask.
    // file_picker 8.0 support getSavePath
    // ...
    // To simplify for this demo, I'll use a fixed name or prompt.
    // But since file_picker is present, let's use it.
    
    // final path = await FilePicker.platform.saveFile(...)
    // However, on some Linux setups, saveFile might not be fully supported.
    // Let's just use a default path in the workspace for now to ensure it works.
    
    final workspace = ref.read(workspacePathProvider);
    if (workspace == null) return;
    
    final pdfPath = p.join(workspace.path, 'output.pdf');
    await _editorKey.currentState?.exportPdf(pdfPath);
  }

  Widget _buildMainArea(AppTheme theme, AppSettings settings) {
    final layoutMode = ref.watch(layoutModeProvider);
    final selectedFile = ref.watch(selectedFileProvider);
    final isTypst = selectedFile != null && (p.extension(selectedFile.path).toLowerCase() == '.typ' || p.extension(selectedFile.path).toLowerCase() == '.typst');

    if (layoutMode == LayoutMode.editorOnly) {
      return isTypst ? _buildEditor(theme, settings) : _buildGenericPreview(theme);
    } else if (layoutMode == LayoutMode.previewOnly) {
      return _buildGenericPreview(theme);
    } else if (layoutMode == LayoutMode.split) {
      return _buildResizableSplit(theme, settings, isTypst);
    }
    return const SizedBox.shrink();
  }

  Widget _buildResizableSplit(AppTheme theme, AppSettings settings, bool isTypst) {
    if (!isTypst) return _buildGenericPreview(theme);

    final orientation = ref.watch(splitOrientationProvider);
    final ratio = ref.watch(splitRatioProvider);
    
    // Watch snippets to ensure they are pre-loaded for auto-expansion
    ref.watch(snippetsProvider);

    return LayoutBuilder(
      key: _mainAreaKey,
      builder: (context, constraints) {
        final renderBox = _mainAreaKey.currentContext?.findRenderObject() as RenderBox?;
        final mainAreaOffset = renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;

        if (orientation == SplitMode.horizontal) {
          return Row(
            children: [
              SizedBox(
                width: constraints.maxWidth * ratio,
                child: _buildEditor(theme, settings),
              ),
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanUpdate: (details) {
                  final x = details.globalPosition.dx - mainAreaOffset.dx;
                  ref.read(splitRatioProvider.notifier).state = (x / constraints.maxWidth).clamp(0.1, 0.9);
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: Container(
                    width: 8,
                    color: Colors.transparent,
                    child: Center(child: Container(width: 1, color: theme.themeData.dividerColor)),
                  ),
                ),
              ),
              Expanded(
                child: _buildGenericPreview(theme),
              ),
            ],
          );
        } else {
          return Column(
            children: [
              SizedBox(
                height: constraints.maxHeight * ratio,
                child: _buildEditor(theme, settings),
              ),
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanUpdate: (details) {
                  final y = details.globalPosition.dy - mainAreaOffset.dy;
                  ref.read(splitRatioProvider.notifier).state = (y / constraints.maxHeight).clamp(0.1, 0.9);
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpDown,
                  child: Container(
                    height: 8,
                    color: Colors.transparent,
                    child: Center(child: Container(height: 1, color: theme.themeData.dividerColor)),
                  ),
                ),
              ),
              Expanded(
                child: _buildGenericPreview(theme),
              ),
            ],
          );
        }
      },
    );
  }

  Widget _buildEditor(AppTheme theme, AppSettings settings) {
    return Container(
      color: theme.editorBackground,
      padding: const EdgeInsets.all(16),
      child: HeadlessEditorView(
        key: _editorKey,
        focusNode: _focusNode,
        initialContent: ref.read(rawContentProvider),
        currentPath: ref.watch(currentTypFileProvider)?.path,
        textStyle: TextStyle(
          fontSize: 14.0,
          fontFamily: settings.editorFont,
          color: theme.editorTextColor,
          height: 1.4,
        ),
        cursorColor: theme.themeData.colorScheme.primary,
        onChanged: (content) {
          ref.read(lastInputTimeProvider.notifier).state = DateTime.now();
          ref.read(docVersionProvider.notifier).update((v) => v + 1);

          // 状態の世代（Version）をインクリメント
          ref.read(contentVersionProvider.notifier).update((v) => v + 1);
          final targetVersion = ref.read(contentVersionProvider);

          ref.read(rawContentProvider.notifier).state = content;

          _compileDebounceTimer?.cancel();
          _compileDebounceTimer = Timer(const Duration(milliseconds: 500), () {
            if (mounted) {
              // デバウンス発火時に世代を確認。ロード等で世代が進んでいればこの更新は破棄。
              final currentVersion = ref.read(contentVersionProvider);
              if (targetVersion == currentVersion) {
                ref.read(debouncedContentProvider.notifier).state = content;
              } else {
                debugPrint('[COMPILE] Stale debounce detected. Skipping update.');
              }
            }
          });
        },
      ),
    );
  }

  Widget _buildGenericPreview(AppTheme theme) {
    final selectedFile = ref.watch(selectedFileProvider);
    if (selectedFile == null) return const Center(child: Text('No file selected', style: TextStyle(color: Colors.grey)));

    final extension = p.extension(selectedFile.path).toLowerCase();
    if (extension == '.typ' || extension == '.typst') {
      final compileResultAsync = ref.watch(typstCompileResultProvider);
      return Container(
        color: theme.previewBackground,
        child: compileResultAsync.maybeWhen(
          data: (result) => _buildPreview(result, isCompiling: false),
          loading: () {
            if (compileResultAsync.hasValue) {
              final prev = compileResultAsync.value!;
              if (prev.diagnostics.isEmpty && prev.pages.isNotEmpty) {
                return _buildPreview(prev, isCompiling: true);
              }
            }
            return const Center(child: CircularProgressIndicator());
          },
          orElse: () => const Center(child: CircularProgressIndicator()),
        ),
      );
    } else if (extension == '.svg') {
      return Container(
        color: Colors.white10,
        padding: const EdgeInsets.all(32),
        child: Center(
          child: SvgPicture.file(
            selectedFile,
            placeholderBuilder: (context) => const CircularProgressIndicator(),
          ),
        ),
      );
    } else if (extension == '.json') {
      return Container(
        color: theme.previewBackground,
        child: FutureBuilder<String>(
          future: selectedFile.readAsString(),
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              try {
                final json = jsonDecode(snapshot.data!);
                const encoder = JsonEncoder.withIndent('  ');
                final prettyJson = encoder.convert(json);
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    prettyJson,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: theme.editorTextColor,
                      fontSize: 13,
                    ),
                  ),
                );
              } catch (e) {
                return Center(child: Text('Invalid JSON: $e', style: const TextStyle(color: Colors.red)));
              }
            }
            return const Center(child: CircularProgressIndicator());
          },
        ),
      );
    } else {
      return Center(child: Text('No preview available for ${p.basename(selectedFile.path)}', style: const TextStyle(color: Colors.grey)));
    }
  }
}

class _LayoutActionButton extends ConsumerWidget {
  final IconData icon;
  final LayoutMode mode;
  final String tooltip;

  const _LayoutActionButton({
    required this.icon,
    required this.mode,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentMode = ref.watch(layoutModeProvider);
    final isActive = currentMode == mode;

    return IconButton(
      icon: Icon(icon),
      onPressed: () => ref.read(layoutModeProvider.notifier).state = mode,
      tooltip: tooltip,
      color: isActive ? Theme.of(context).colorScheme.primary : Colors.grey,
    );
  }
}

class _OrientationActionButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orientation = ref.watch(splitOrientationProvider);
    final isHorizontal = orientation == SplitMode.horizontal;

    return IconButton(
      icon: Icon(isHorizontal ? Icons.view_agenda_outlined : Icons.view_sidebar_outlined),
      onPressed: () {
        ref.read(splitOrientationProvider.notifier).state = isHorizontal ? SplitMode.vertical : SplitMode.horizontal;
      },
      tooltip: isHorizontal ? 'Switch to Vertical Split' : 'Switch to Horizontal Split',
      color: Colors.grey,
    );
  }
}
