import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppThemeMode {
  light,
  dark,
  catppuccin,
}

class AppTheme {
  final ThemeData themeData;
  final Color editorBackground;
  final Color editorTextColor;
  final Color previewBackground;

  AppTheme({
    required this.themeData,
    required this.editorBackground,
    required this.editorTextColor,
    required this.previewBackground,
  });

  static AppTheme get light => AppTheme(
    themeData: ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorSchemeSeed: Colors.blue,
    ),
    editorBackground: Colors.white,
    editorTextColor: Colors.black87,
    previewBackground: const Color(0xFFF0F0F0),
  );

  static AppTheme get dark => AppTheme(
    themeData: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: Colors.blue,
    ),
    editorBackground: const Color(0xFF1E1E1E),
    editorTextColor: const Color(0xFFD4D4D4),
    previewBackground: const Color(0xFF2D2D2D),
  );

  static AppTheme get catppuccin => AppTheme(
    themeData: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF24273A), // Macchiato Base
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF8AADF4), // Blue
        secondary: Color(0xFFF5BDE6), // Pink
        surface: Color(0xFF36394F), // Surface0
        background: Color(0xFF24273A),
      ),
    ),
    editorBackground: const Color(0xFF24273A), // Base
    editorTextColor: const Color(0xFFCAD3F5), // Text
    previewBackground: const Color(0xFF1E2030), // Mantle
  );
}

class ThemeNotifier extends StateNotifier<AppThemeMode> {
  ThemeNotifier() : super(AppThemeMode.dark);

  void setTheme(AppThemeMode mode) => state = mode;
}

final themeProvider = StateNotifierProvider<ThemeNotifier, AppThemeMode>((ref) {
  return ThemeNotifier();
});

final activeThemeDetailedProvider = Provider<AppTheme>((ref) {
  final mode = ref.watch(themeProvider);
  switch (mode) {
    case AppThemeMode.light:
      return AppTheme.light;
    case AppThemeMode.dark:
      return AppTheme.dark;
    case AppThemeMode.catppuccin:
      return AppTheme.catppuccin;
  }
});
