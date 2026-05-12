import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'handwriting_provider.dart';

enum AppThemeMode {
  light,
  dark,
  catppuccin,
  oneDark,
  nightfox,
}

enum ToolbarPosition { top, bottom, left, right }

class AppSettings {
  final ToolbarPosition toolbarPosition;
  final List<Color> palette;
  final List<String> customFontPaths; // Relative paths to notebook dir
  final String activeFont;
  final String editorFont;
  final bool horizontalPreview;
  final bool relativeLineNumbers;
  final bool showWhitespace;
  final bool vimEnabled;
  final double fontSize;
  final AppThemeMode theme;

  const AppSettings({
    this.toolbarPosition = ToolbarPosition.bottom,
    this.palette = defaultPalette,
    this.customFontPaths = const [],
    this.activeFont = 'IBM Plex Sans',
    this.editorFont = 'Moralerspace Argon',
    this.horizontalPreview = false,
    this.relativeLineNumbers = false,
    this.showWhitespace = false,
    this.vimEnabled = true,
    this.fontSize = 14.0,
    this.theme = AppThemeMode.dark,
  });

  Map<String, dynamic> toJson() => {
        'toolbarPosition': toolbarPosition.index,
        'palette': palette.map((c) => c.value).toList(),
        'customFontPaths': customFontPaths,
        'activeFont': activeFont,
        'editorFont': editorFont,
        'horizontalPreview': horizontalPreview,
        'relativeLineNumbers': relativeLineNumbers,
        'showWhitespace': showWhitespace,
        'vimEnabled': vimEnabled,
        'fontSize': fontSize,
        'theme': theme.index,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    String font = json['activeFont'] ?? 'IBM Plex Sans';
    String eFont = json['editorFont'] ?? 'Moralerspace Argon';

    return AppSettings(
      toolbarPosition: ToolbarPosition.values[(json['toolbarPosition'] ?? 1)
          .clamp(0, ToolbarPosition.values.length - 1)],
      palette:
          (json['palette'] as List?)?.map((v) => Color(v as int)).toList() ??
              defaultPalette,
      customFontPaths:
          (json['customFontPaths'] as List?)?.cast<String>() ?? const [],
      activeFont: font,
      editorFont: eFont,
      horizontalPreview: json['horizontalPreview'] ?? false,
      relativeLineNumbers: json['relativeLineNumbers'] ?? false,
      showWhitespace: json['showWhitespace'] ?? false,
      vimEnabled: json['vimEnabled'] ?? true,
      fontSize: (json['fontSize'] ?? 14.0).toDouble(),
      theme: AppThemeMode.values[(json['theme'] ?? AppThemeMode.dark.index)
          .clamp(0, AppThemeMode.values.length - 1)],
    );
  }

  AppSettings copyWith({
    ToolbarPosition? toolbarPosition,
    List<Color>? palette,
    List<String>? customFontPaths,
    String? activeFont,
    String? editorFont,
    bool? horizontalPreview,
    bool? relativeLineNumbers,
    bool? showWhitespace,
    bool? vimEnabled,
    double? fontSize,
    AppThemeMode? theme,
  }) {
    return AppSettings(
      toolbarPosition: toolbarPosition ?? this.toolbarPosition,
      palette: palette ?? this.palette,
      customFontPaths: customFontPaths ?? this.customFontPaths,
      activeFont: activeFont ?? this.activeFont,
      editorFont: editorFont ?? this.editorFont,
      horizontalPreview: horizontalPreview ?? this.horizontalPreview,
      relativeLineNumbers: relativeLineNumbers ?? this.relativeLineNumbers,
      showWhitespace: showWhitespace ?? this.showWhitespace,
      vimEnabled: vimEnabled ?? this.vimEnabled,
      fontSize: fontSize ?? this.fontSize,
      theme: theme ?? this.theme,
    );
  }
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier() : super(const AppSettings());

  void setToolbarPosition(ToolbarPosition pos) =>
      state = state.copyWith(toolbarPosition: pos);

  void setPalette(List<Color> palette) =>
      state = state.copyWith(palette: palette);
  void replacePaletteColor(int index, Color color) {
    final newList = List<Color>.from(state.palette);
    if (index >= 0 && index < newList.length) {
      newList[index] = color;
      state = state.copyWith(palette: newList);
    }
  }

  void resetPalette() => state = state.copyWith(palette: defaultPalette);

  void addFontPath(String relativePath) => state = state.copyWith(
      customFontPaths: {...state.customFontPaths, relativePath}.toList());
  void removeFontPath(String relativePath) => state = state.copyWith(
      customFontPaths:
          state.customFontPaths.where((p) => p != relativePath).toList());
  void setActiveFont(String font) => state = state.copyWith(activeFont: font);
  void setEditorFont(String font) => state = state.copyWith(editorFont: font);
  void toggleHorizontalPreview() =>
      state = state.copyWith(horizontalPreview: !state.horizontalPreview);
  void toggleRelativeLineNumbers() =>
      state = state.copyWith(relativeLineNumbers: !state.relativeLineNumbers);
  void toggleShowWhitespace() =>
      state = state.copyWith(showWhitespace: !state.showWhitespace);
  void toggleVimEnabled() =>
      state = state.copyWith(vimEnabled: !state.vimEnabled);
  void setFontSize(double size) => state = state.copyWith(fontSize: size);
  void setTheme(AppThemeMode theme) => state = state.copyWith(theme: theme);
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>(
    (ref) => SettingsNotifier());

class Snippet {
  final String prefix;
  final String body;
  final String description;

  const Snippet(
      {required this.prefix, required this.body, required this.description});

  factory Snippet.fromJson(String prefix, Map<String, dynamic> json) {
    return Snippet(
      prefix: prefix,
      body: json['body'] as String,
      description: json['description'] as String? ?? '',
    );
  }
}

final snippetsProvider = FutureProvider<List<Snippet>>((ref) async {
  final notebookDir = ref.watch(notebookPathProvider);
  final List<Snippet> allSnippets = [];

  // 1. Load bundled snippets from assets
  try {
    final bundleJson = await rootBundle.loadString('assets/snippets.json');
    final Map<String, dynamic> data = jsonDecode(bundleJson);
    data.forEach((k, v) => allSnippets.add(Snippet.fromJson(k, v)));
  } catch (e) {
    debugPrint('No bundled snippets found: $e');
  }

  // 2. Load user snippets from notebook directory
  if (notebookDir != null) {
    try {
      final userFile = File(p.join(notebookDir.path, 'snippets.json'));
      if (await userFile.exists()) {
        final userJson = await userFile.readAsString();
        final Map<String, dynamic> data = jsonDecode(userJson);
        data.forEach((k, v) => allSnippets.add(Snippet.fromJson(k, v)));
      }
    } catch (e) {
      debugPrint('Error loading user snippets: $e');
    }
  }

  return allSnippets;
});

String buildPreamble(String font) {
  return '''#set page(width: 210mm, height: 297mm, margin: 20mm)
#set text(font: ("$font", "IBM Plex Sans JP"))
''';
}
