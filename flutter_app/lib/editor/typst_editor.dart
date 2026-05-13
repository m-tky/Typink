import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../frb_generated.dart/api.dart' as bridge;
import '../frb_generated.dart/vim_engine.dart' as v;
import 'headless_editor.dart';
import 'package:path/path.dart' as p;
import 'drawing_pad.dart';
import 'file_tree.dart';
import 'package:flutter/services.dart';
import 'providers.dart';
import 'theme_provider.dart';
import 'workspace_provider.dart';
import 'vim_provider.dart';
// Ensure pdfx is imported for the preview
import 'package:flutter_svg/flutter_svg.dart';

class TypstEditorPage extends ConsumerStatefulWidget {
  const TypstEditorPage({super.key});

  @override
  ConsumerState<TypstEditorPage> createState() => _TypstEditorPageState();
}

class _TypstEditorPageState extends ConsumerState<TypstEditorPage>
    with WidgetsBindingObserver {
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

    _pageController =
        PageController(initialPage: ref.read(currentPageProvider));
    // Request focus after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });

    // Ensure the persistenceProvider is initialized (autosave is set up in the provider factory)
    ref.read(persistenceProvider);
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
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      ref.read(persistenceProvider).flush();
    }
  }

  Future<void> _addOrEditDrawing([String? existingId]) async {
    final state = ref.read(handwritingProvider);
    final currentFile = ref.read(currentTypFileProvider);
    if (currentFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Please select or create a .typ file first')),
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
        jsonEncode({
          id: (ref.read(handwritingProvider).figures[id] ?? [])
              .map((s) => s.toJson())
              .toList()
        }),
        targetDir: targetDir,
      );

      if (existingId == null) {
        final relWidth = notifier.calculateRelativeWidth(id);
        String widthStr = '100%';
        if (relWidth < 0.3) {
          widthStr = '40%';
        } else if (relWidth < 0.7) {
          widthStr = '70%';
        }

        // 挿入するSnippet
        // insertAfterCurrentLine: true を使うので、Snippet側では余計な先頭改行を控える（1つの改行で十分）
        final snippet =
            '\n#figure(\n  image("$fileNameNoExt/$id.svg", width: $widthStr),\n  caption: [$id],\n)\n';
        debugPrint('Inserting figure snippet after current line: $snippet');

        // エディタの現在の行の直後に挿入
        _editorKey.currentState
            ?.insertText(snippet, insertAfterCurrentLine: true);
      }
    }
  }

  void _deleteActiveFigure(String id) {
    final notifier = ref.read(handwritingProvider.notifier);
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    final nextFigures = Map<String, List<Stroke>>.from(notifier.state.figures);
    nextFigures.remove(id);
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    notifier.state = notifier.state.copyWith(figures: nextFigures);

    // TODO: Bridge delete figure to Rust
    ref.read(activeFigureIdProvider.notifier).state = null;
  }

  @override
  Widget build(BuildContext context) {
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
            onPressed: () =>
                setState(() => _isExplorerVisible = !_isExplorerVisible),
            tooltip: 'Toggle Explorer',
          ),
          title: Text(
            ref.watch(documentTitleProvider),
            style: TextStyle(fontSize: 16, color: theme.editorTextColor),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.add_photo_alternate),
              onPressed: () => _addOrEditDrawing(),
              tooltip: 'Insert Drawing',
            ),
            IconButton(
              icon: const Icon(Icons.picture_as_pdf),
              onPressed: _exportPdf,
              tooltip: 'Export PDF',
            ),
            const VerticalDivider(width: 1, indent: 12, endIndent: 12),
            // Layout mode popup (replaces 3 separate buttons + orientation button)
            PopupMenuButton<String>(
              icon: Icon(_currentLayoutIcon()),
              tooltip: 'View Layout',
              onSelected: (value) {
                if (value == 'editorOnly') {
                  ref.read(layoutModeProvider.notifier).state =
                      LayoutMode.editorOnly;
                } else if (value == 'split') {
                  ref.read(layoutModeProvider.notifier).state =
                      LayoutMode.split;
                } else if (value == 'previewOnly') {
                  ref.read(layoutModeProvider.notifier).state =
                      LayoutMode.previewOnly;
                } else if (value == 'orientation') {
                  final current = ref.read(splitOrientationProvider);
                  ref.read(splitOrientationProvider.notifier).state =
                      current == SplitMode.horizontal
                          ? SplitMode.vertical
                          : SplitMode.horizontal;
                }
              },
              itemBuilder: (context) {
                final currentMode = ref.read(layoutModeProvider);
                final currentOrientation = ref.read(splitOrientationProvider);
                return [
                  CheckedPopupMenuItem(
                    value: 'editorOnly',
                    checked: currentMode == LayoutMode.editorOnly,
                    child: const Text('Editor Only'),
                  ),
                  CheckedPopupMenuItem(
                    value: 'split',
                    checked: currentMode == LayoutMode.split,
                    child: const Text('Split View'),
                  ),
                  CheckedPopupMenuItem(
                    value: 'previewOnly',
                    checked: currentMode == LayoutMode.previewOnly,
                    child: const Text('Preview Only'),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'orientation',
                    child: Text(currentOrientation == SplitMode.horizontal
                        ? 'Switch to Vertical Split'
                        : 'Switch to Horizontal Split'),
                  ),
                ];
              },
            ),
            // Overflow: save, compile, settings
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: 'More',
              onSelected: (value) {
                if (value == 'save') {
                  _editorKey.currentState?.save();
                } else if (value == 'compile') {
                  ref.read(debouncedContentProvider.notifier).state =
                      bridge.getEditorContent();
                } else if (value == 'settings') {
                  Navigator.of(context).pushNamed('/settings');
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'save',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.save),
                    title: Text('Save'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'compile',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.refresh),
                    title: Text('Compile Now'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'settings',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.settings),
                    title: Text('Settings'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
                () => _turnPage(-1),
            const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
                () => _turnPage(1),
          },
          child: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    if (_isExplorerVisible)
                      FileTree(
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

  IconData _currentLayoutIcon() {
    switch (ref.read(layoutModeProvider)) {
      case LayoutMode.editorOnly:
        return Icons.edit_note;
      case LayoutMode.previewOnly:
        return Icons.article_outlined;
      case LayoutMode.split:
        return Icons.view_quilt_outlined;
    }
  }

  Widget _buildStatusBar(AppTheme theme) {
    final settings = ref.watch(settingsProvider);
    final mode = ref.watch(vimModeProvider);
    final modeName = settings.vimEnabled ? mode.name.toUpperCase() : 'EDITOR';
    final modeColor = !settings.vimEnabled
        ? Colors.grey
        : (mode == v.VimMode.insert
            ? Colors.green
            : (mode == v.VimMode.visual ? Colors.orange : Colors.blue));

    final (cursorLine, cursorCol) = ref.watch(cursorPositionProvider);
    final currentPage = ref.watch(currentPageProvider);
    final diagnostics = ref.watch(versionedDiagnosticsProvider);
    final errorCount = diagnostics.items.where((d) => d.severity == 1).length;
    final warnCount = diagnostics.items.where((d) => d.severity == 2).length;

    // Get total pages from compile result (non-blocking)
    final compileAsync = ref.watch(typstCompileResultProvider);
    final totalPages = compileAsync.valueOrNull?.pages.length ?? 0;

    return Container(
      height: 24,
      color: theme.themeData.colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          // Mode badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            color: modeColor,
            child: Text(
              modeName,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 8),
          // Cursor position
          Text(
            '$cursorLine:$cursorCol',
            style: TextStyle(
                color: theme.editorTextColor.withOpacity(0.7), fontSize: 11),
          ),
          if (totalPages > 1) ...[
            const SizedBox(width: 12),
            Text(
              'Page ${currentPage + 1}/$totalPages',
              style: TextStyle(
                  color: theme.editorTextColor.withOpacity(0.7), fontSize: 11),
            ),
          ],
          const Spacer(),
          // Diagnostics summary
          if (errorCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 12, color: Colors.red),
                  const SizedBox(width: 2),
                  Text('$errorCount',
                      style: const TextStyle(color: Colors.red, fontSize: 11)),
                ],
              ),
            ),
          if (warnCount > 0)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning_amber_outlined,
                    size: 12, color: Colors.orange),
                const SizedBox(width: 2),
                Text('$warnCount',
                    style: const TextStyle(color: Colors.orange, fontSize: 11)),
              ],
            ),
          if (errorCount == 0 && warnCount == 0 && totalPages > 0)
            Text(
              '✓',
              style:
                  TextStyle(color: Colors.green.withOpacity(0.8), fontSize: 11),
            ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildPreview(bridge.TypstCompileResult result,
      {required bool isCompiling}) {
    final pages = result.pages;
    final diagnostics = result.diagnostics;
    final activeId = ref.watch(activeFigureIdProvider);

    final settings = ref.watch(settingsProvider);

    final children = <Widget>[];
    if (pages.isNotEmpty) {
      children.add(settings.horizontalPreview
          ? PageView.builder(
              controller: _pageController,
              itemCount: pages.length,
              onPageChanged: (index) =>
                  ref.read(currentPageProvider.notifier).state = index,
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
            ));
    } else if (diagnostics.isEmpty && !isCompiling) {
      children.add(
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.article_outlined,
                  size: 48, color: Colors.grey.withOpacity(0.4)),
              const SizedBox(height: 12),
              Text(
                'No output yet',
                style: TextStyle(
                  color: Colors.grey.withOpacity(0.7),
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Start typing to see the preview',
                style: TextStyle(
                    color: Colors.grey.withOpacity(0.5), fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    children.add(
      Positioned(
        bottom: 16,
        right: 16,
        child: FloatingActionButton(
          mini: true,
          heroTag: 'edit',
          child: const Icon(Icons.edit_note),
          onPressed: () {
            final state = ref.read(handwritingProvider);
            if (state.figures.isEmpty) {
              _addOrEditDrawing();
            } else {
              final svgMap = ref.read(handwritingSvgMapProvider);
              showModalBottomSheet(
                context: context,
                builder: (context) {
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      const ListTile(
                        title: Text(
                          'Select figure to edit',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      ...state.figures.keys.map((id) {
                        final isEditable = ref
                            .read(handwritingProvider.notifier)
                            .isEditable(id);
                        return ListTile(
                          leading: SizedBox(
                            width: 56,
                            height: 42,
                            child: (svgMap[id]?.isNotEmpty == true)
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: SvgPicture.string(
                                      svgMap[id]!,
                                      fit: BoxFit.contain,
                                      colorFilter: (isEditable)
                                          ? null
                                          : const ColorFilter.mode(
                                              Colors.grey,
                                              BlendMode.saturation,
                                            ),
                                    ),
                                  )
                                : Container(
                                    decoration: BoxDecoration(
                                      color: Colors.grey.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Icon(
                                      Icons.image_outlined,
                                      size: 20,
                                      color: Colors.grey,
                                    ),
                                  ),
                          ),
                          title: Text(id + (isEditable ? '' : ' (Read-Only)')),
                          onTap: isEditable
                              ? () {
                                  Navigator.pop(context);
                                  _addOrEditDrawing(id);
                                }
                              : null,
                          trailing: IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () {
                              Navigator.pop(context);
                              _deleteActiveFigure(id);
                            },
                          ),
                        );
                      }),
                      ListTile(
                        leading: const Icon(Icons.add),
                        title: const Text('Add new drawing'),
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
      final isExpanded = ref.watch(isDiagnosticsPanelExpandedProvider);
      final errorCount = diagnostics.where((d) => d.severity == 1).length;
      final warnCount = diagnostics.where((d) => d.severity == 2).length;
      final headerColor =
          (hasErrors ? Colors.red : Colors.orange).withOpacity(0.92);

      children.add(
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Collapsed header (always visible)
              GestureDetector(
                onTap: () => ref
                    .read(isDiagnosticsPanelExpandedProvider.notifier)
                    .state = !isExpanded,
                child: Container(
                  color: headerColor,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        hasErrors
                            ? Icons.error_outline
                            : Icons.warning_amber_outlined,
                        color: Colors.white,
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        [
                          if (errorCount > 0)
                            '$errorCount error${errorCount > 1 ? 's' : ''}',
                          if (warnCount > 0)
                            '$warnCount warning${warnCount > 1 ? 's' : ''}',
                        ].join(', '),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        isExpanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_up,
                        color: Colors.white,
                        size: 16,
                      ),
                    ],
                  ),
                ),
              ),
              // Expanded detail list
              if (isExpanded)
                Container(
                  constraints: const BoxConstraints(maxHeight: 180),
                  color: headerColor.withOpacity(0.95),
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: diagnostics.length,
                    itemBuilder: (context, index) {
                      final diag = diagnostics[index];
                      final isError = diag.severity == 1;
                      return ListTile(
                        dense: true,
                        title: Text(
                          diag.message,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        subtitle: Text(
                          'Line: ${diag.line + 1}, Col: ${diag.column + 1}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                        leading: Icon(
                          isError
                              ? Icons.error_outline
                              : Icons.warning_amber_outlined,
                          color: Colors.white,
                          size: 16,
                        ),
                      );
                    },
                  ),
                ),
            ],
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.blueAccent)),
                SizedBox(width: 8),
                Text('Compiling...',
                    style: TextStyle(
                        color: Colors.blueAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
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
              ref.read(activeFigureIdProvider.notifier).state =
                  state.figures.keys.last;
            } else {
              ref.read(activeFigureIdProvider.notifier).state = 'fig_1';
            }
          }
        },
        child: Container(
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20)
            ],
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
    final result = bridge.handleEditorGetTotalLines();
    if (result == BigInt.zero) return;

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
    final isTypst = selectedFile != null &&
        (p.extension(selectedFile.path).toLowerCase() == '.typ' ||
            p.extension(selectedFile.path).toLowerCase() == '.typst');

    if (layoutMode == LayoutMode.editorOnly) {
      return isTypst
          ? _buildEditor(theme, settings)
          : _buildGenericPreview(theme);
    } else if (layoutMode == LayoutMode.previewOnly) {
      return _buildGenericPreview(theme);
    } else if (layoutMode == LayoutMode.split) {
      return _buildResizableSplit(theme, settings, isTypst);
    }
    return const SizedBox.shrink();
  }

  Widget _buildResizableSplit(
      AppTheme theme, AppSettings settings, bool isTypst) {
    if (!isTypst) return _buildGenericPreview(theme);

    final orientation = ref.watch(splitOrientationProvider);
    final ratio = ref.watch(splitRatioProvider);

    // Watch snippets to ensure they are pre-loaded for auto-expansion
    ref.watch(snippetsProvider);

    return LayoutBuilder(
      key: _mainAreaKey,
      builder: (context, constraints) {
        final renderBox =
            _mainAreaKey.currentContext?.findRenderObject() as RenderBox?;
        final mainAreaOffset =
            renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;

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
                  ref.read(splitRatioProvider.notifier).state =
                      (x / constraints.maxWidth).clamp(0.1, 0.9);
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: Container(
                    width: 8,
                    color: Colors.transparent,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 1,
                            height: 16,
                            color: theme.themeData.dividerColor,
                          ),
                          const SizedBox(height: 2),
                          ...List.generate(
                            3,
                            (_) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Container(
                                width: 4,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: theme.themeData.dividerColor
                                      .withOpacity(0.8),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Container(
                            width: 1,
                            height: 16,
                            color: theme.themeData.dividerColor,
                          ),
                        ],
                      ),
                    ),
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
                  ref.read(splitRatioProvider.notifier).state =
                      (y / constraints.maxHeight).clamp(0.1, 0.9);
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpDown,
                  child: Container(
                    height: 8,
                    color: Colors.transparent,
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            height: 1,
                            width: 16,
                            color: theme.themeData.dividerColor,
                          ),
                          const SizedBox(width: 2),
                          ...List.generate(
                            3,
                            (_) => Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 2),
                              child: Container(
                                width: 4,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: theme.themeData.dividerColor
                                      .withOpacity(0.8),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 2),
                          Container(
                            height: 1,
                            width: 16,
                            color: theme.themeData.dividerColor,
                          ),
                        ],
                      ),
                    ),
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
          fontSize: settings.fontSize,
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
          ref.read(rawContentProvider.notifier).state = content;
          final targetVersion = ref.read(contentVersionProvider);

          _compileDebounceTimer?.cancel();
          _compileDebounceTimer = Timer(const Duration(milliseconds: 500), () {
            if (mounted) {
              // デバウンス発火時に世代を確認。ロード等で世代が進んでいればこの更新は破棄。
              final currentVersion = ref.read(contentVersionProvider);
              if (targetVersion == currentVersion) {
                ref.read(debouncedContentProvider.notifier).state = content;
              } else {
                debugPrint(
                    '[COMPILE] Stale debounce detected. Skipping update.');
              }
            }
          });
        },
      ),
    );
  }

  Widget _buildGenericPreview(AppTheme theme) {
    final selectedFile = ref.watch(selectedFileProvider);
    if (selectedFile == null) {
      return const Center(
          child:
              Text('No file selected', style: TextStyle(color: Colors.grey)));
    }

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
                return Center(
                    child: Text('Invalid JSON: $e',
                        style: const TextStyle(color: Colors.red)));
              }
            }
            return const Center(child: CircularProgressIndicator());
          },
        ),
      );
    } else {
      return Center(
          child: Text(
              'No preview available for ${p.basename(selectedFile.path)}',
              style: const TextStyle(color: Colors.grey)));
    }
  }
}
