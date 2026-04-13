class TypinkDocument {
  final String path;
  final String content;
  final List<String> figurePaths;

  TypinkDocument({
    required this.path,
    required this.content,
    required this.figurePaths,
  });

  TypinkDocument copyWith({
    String? path,
    String? content,
    List<String>? figurePaths,
  }) {
    return TypinkDocument(
      path: path ?? this.path,
      content: content ?? this.content,
      figurePaths: figurePaths ?? this.figurePaths,
    );
  }
}
