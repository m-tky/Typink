import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';

class SyntaxTheme {
  final Color heading;
  final Color math;
  final Color mathOperator;
  final Color mathPunctuation;
  final Color mathKeyword;
  final Color mathFunction;
  final Color mathVariable;
  final Color delimiterL1;
  final Color delimiterL2;
  final Color delimiterL3;
  final Color delimiterL4;
  final Color delimiterL5;
  final Color raw;
  final Color link;
  final Color label;
  final Color ref;
  final Color marker;
  final Color operator;
  final Color punctuation;
  final Color error;
  final Color function;
  final Color keyword;
  final Color string;
  final Color comment;
  final Color variable;

  SyntaxTheme({
    required this.heading,
    required this.math,
    required this.mathOperator,
    required this.mathPunctuation,
    required this.mathKeyword,
    required this.mathFunction,
    required this.mathVariable,
    required this.delimiterL1,
    required this.delimiterL2,
    required this.delimiterL3,
    required this.delimiterL4,
    required this.delimiterL5,
    required this.raw,
    required this.link,
    required this.label,
    required this.ref,
    required this.marker,
    required this.operator,
    required this.punctuation,
    required this.error,
    required this.function,
    required this.keyword,
    required this.string,
    required this.comment,
    required this.variable,
  });

  factory SyntaxTheme.light() => SyntaxTheme(
    heading: const Color(0xFFE45649),
    math: const Color(0xFF4078F2),
    mathOperator: const Color(0xFF008080),
    mathPunctuation: const Color(0xFF707070),
    mathKeyword: const Color(0xFFA626A4),
    mathFunction: const Color(0xFF0184BC),
    mathVariable: const Color(0xFF986801),
    delimiterL1: const Color(0xFFFFCC00),
    delimiterL2: const Color(0xFFDA70D6),
    delimiterL3: const Color(0xFF1E90FF),
    delimiterL4: const Color(0xFFFF7F50),
    delimiterL5: const Color(0xFF32CD32),
    raw: const Color(0xFFD19A66),
    link: const Color(0xFF61AFEF),
    label: const Color(0xFF56B6C2),
    ref: const Color(0xFF56B6C2),
    marker: const Color(0xFFE06C75),
    operator: const Color(0xFF56B6C2),
    punctuation: const Color(0xFFABB2BF),
    error: const Color(0xFFFF0000),
    function: const Color(0xFF0184BC),
    keyword: const Color(0xFFA626A4),
    string: const Color(0xFF50A14F),
    comment: const Color(0xFFA0A1A7),
    variable: const Color(0xFF986801),
  );

  factory SyntaxTheme.dark() => SyntaxTheme.light().copyWith(
    punctuation: const Color(0xFF808080),
    comment: const Color(0xFF606060),
    variable: const Color(0xFFD19A66),
  );

  factory SyntaxTheme.catppuccinMacchiato() => SyntaxTheme(
    heading: const Color(0xFFED8796), // Red
    math: const Color(0xFF8AADF4),    // Blue
    mathOperator: const Color(0xFF8BD5CA), // Teal
    mathPunctuation: const Color(0xFF939AB7), // Overlay2
    mathKeyword: const Color(0xFFC6A0F6), // Mauve
    mathFunction: const Color(0xFF8AADF4), // Blue
    mathVariable: const Color(0xFFF5A97F), // Peach
    delimiterL1: const Color(0xFFEED49F), // Yellow
    delimiterL2: const Color(0xFFC6A0F6), // Mauve
    delimiterL3: const Color(0xFF8AADF4), // Blue
    delimiterL4: const Color(0xFFF5A97F), // Peach
    delimiterL5: const Color(0xFFA6DA95), // Green
    raw: const Color(0xFFF5A97F), // Peach
    link: const Color(0xFF91D7E3), // Sky
    label: const Color(0xFF8BD5CA), // Teal
    ref: const Color(0xFF8BD5CA), // Teal
    marker: const Color(0xFFEE99A0), // Maroon
    operator: const Color(0xFF8BD5CA), // Teal
    punctuation: const Color(0xFF939AB7), // Overlay2
    error: const Color(0xFFED8796), // Red
    function: const Color(0xFF8AADF4), // Blue
    keyword: const Color(0xFFC6A0F6), // Mauve
    string: const Color(0xFFA6DA95), // Green
    comment: const Color(0xFF6E738D), // Overlay0
    variable: const Color(0xFFF5A97F), // Peach
  );

  factory SyntaxTheme.oneDark() => SyntaxTheme(
    heading: const Color(0xFFE06C75), // Red
    math: const Color(0xFF61AFEF),    // Blue
    mathOperator: const Color(0xFF56B6C2), // Cyan
    mathPunctuation: const Color(0xFFABB2BF), // Light Grey
    mathKeyword: const Color(0xFFC678DD), // Purple
    mathFunction: const Color(0xFF61AFEF), // Blue
    mathVariable: const Color(0xFFD19A66), // Dark Yellow
    delimiterL1: const Color(0xFFE5C07B), // Yellow
    delimiterL2: const Color(0xFFC678DD), // Purple
    delimiterL3: const Color(0xFF61AFEF), // Blue
    delimiterL4: const Color(0xFFD19A66), // Dark Yellow
    delimiterL5: const Color(0xFF98C379), // Green
    raw: const Color(0xFFD19A66), // Dark Yellow
    link: const Color(0xFF61AFEF), // Blue
    label: const Color(0xFF56B6C2), // Cyan
    ref: const Color(0xFF56B6C2), // Cyan
    marker: const Color(0xFFE06C75), // Red
    operator: const Color(0xFF56B6C2), // Cyan
    punctuation: const Color(0xFFABB2BF), // Light Grey
    error: const Color(0xFFBE5046), // Dark Red
    function: const Color(0xFF61AFEF), // Blue
    keyword: const Color(0xFFC678DD), // Purple
    string: const Color(0xFF98C379), // Green
    comment: const Color(0xFF5C6370), // Grey
    variable: const Color(0xFFE06C75), // Red
  );

  factory SyntaxTheme.nightfox() => SyntaxTheme(
    heading: const Color(0xFF719CD6),    // Blue bright
    math: const Color(0xFF719CD6),       // Blue base
    mathOperator: const Color(0xFFAEAFB0), // FG2
    mathPunctuation: const Color(0xFFAEAFB0),
    mathKeyword: const Color(0xFF9D79D6), // Magenta base
    mathFunction: const Color(0xFF719CD6),
    mathVariable: const Color(0xFFDFDFE0), // White base
    delimiterL1: const Color(0xFFDBC074), // Yellow base
    delimiterL2: const Color(0xFF9D79D6), // Magenta base
    delimiterL3: const Color(0xFF719CD6), // Blue base
    delimiterL4: const Color(0xFFF4A261), // Orange base
    delimiterL5: const Color(0xFF81B29A), // Green base
    raw: const Color(0xFFF4A261),         // Orange base
    link: const Color(0xFF63CDCF),        // Cyan base
    label: const Color(0xFF63CDCF),
    ref: const Color(0xFF63CDCF),
    marker: const Color(0xFFC94F6D),      // Red base
    operator: const Color(0xFFAEAFB0),   // FG2
    punctuation: const Color(0xFFAEAFB0),
    error: const Color(0xFFC94F6D),
    function: const Color(0xFF719CD6),
    keyword: const Color(0xFF9D79D6),
    string: const Color(0xFF81B29A),
    comment: const Color(0xFF738091),
    variable: const Color(0xFFDFDFE0),
  );

  SyntaxTheme copyWith({
    Color? heading,
    Color? math,
    Color? mathOperator,
    Color? mathPunctuation,
    Color? mathKeyword,
    Color? mathFunction,
    Color? mathVariable,
    Color? delimiterL1,
    Color? delimiterL2,
    Color? delimiterL3,
    Color? delimiterL4,
    Color? delimiterL5,
    Color? raw,
    Color? link,
    Color? label,
    Color? ref,
    Color? marker,
    Color? operator,
    Color? punctuation,
    Color? error,
    Color? function,
    Color? keyword,
    Color? string,
    Color? comment,
    Color? variable,
  }) {
    return SyntaxTheme(
      heading: heading ?? this.heading,
      math: math ?? this.math,
      mathOperator: mathOperator ?? this.mathOperator,
      mathPunctuation: mathPunctuation ?? this.mathPunctuation,
      mathKeyword: mathKeyword ?? this.mathKeyword,
      mathFunction: mathFunction ?? this.mathFunction,
      mathVariable: mathVariable ?? this.mathVariable,
      delimiterL1: delimiterL1 ?? this.delimiterL1,
      delimiterL2: delimiterL2 ?? this.delimiterL2,
      delimiterL3: delimiterL3 ?? this.delimiterL3,
      delimiterL4: delimiterL4 ?? this.delimiterL4,
      delimiterL5: delimiterL5 ?? this.delimiterL5,
      raw: raw ?? this.raw,
      link: link ?? this.link,
      label: label ?? this.label,
      ref: ref ?? this.ref,
      marker: marker ?? this.marker,
      operator: operator ?? this.operator,
      punctuation: punctuation ?? this.punctuation,
      error: error ?? this.error,
      function: function ?? this.function,
      keyword: keyword ?? this.keyword,
      string: string ?? this.string,
      comment: comment ?? this.comment,
      variable: variable ?? this.variable,
    );
  }
}

class AppTheme {
  final ThemeData themeData;
  final Color editorBackground;
  final Color editorTextColor;
  final Color previewBackground;
  final SyntaxTheme syntaxTheme;

  AppTheme({
    required this.themeData,
    required this.editorBackground,
    required this.editorTextColor,
    required this.previewBackground,
    required this.syntaxTheme,
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
    syntaxTheme: SyntaxTheme.light(),
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
    syntaxTheme: SyntaxTheme.dark(),
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
    syntaxTheme: SyntaxTheme.catppuccinMacchiato(),
  );

  static AppTheme get oneDark => AppTheme(
    themeData: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF282C34),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF61AFEF),
        secondary: Color(0xFFC678DD),
        surface: Color(0xFF21252B),
        background: Color(0xFF282C34),
      ),
    ),
    editorBackground: const Color(0xFF282C34),
    editorTextColor: const Color(0xFFABB2BF),
    previewBackground: const Color(0xFF21252B),
    syntaxTheme: SyntaxTheme.oneDark(),
  );

  static AppTheme get nightfox => AppTheme(
    themeData: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF131A24), // BG0
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF719CD6), // Blue base
        secondary: Color(0xFF9D79D6), // Magenta base
        surface: Color(0xFF192330), // BG1
        background: Color(0xFF131A24),
      ),
    ),
    editorBackground: const Color(0xFF192330), // BG1
    editorTextColor: const Color(0xFFCDCECF), // FG1
    previewBackground: const Color(0xFF131A24), // BG0
    syntaxTheme: SyntaxTheme.nightfox(),
  );
}

final themeProvider = Provider<AppThemeMode>((ref) {
  return ref.watch(settingsProvider.select((s) => s.theme));
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
    case AppThemeMode.oneDark:
      return AppTheme.oneDark;
    case AppThemeMode.nightfox:
      return AppTheme.nightfox;
  }
});
