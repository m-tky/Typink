import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'frb_generated.dart/frb_generated.dart';
import 'editor/typst_editor.dart';
import 'editor/theme_provider.dart';
import 'editor/workspace_provider.dart';
import 'editor/workspace_selector.dart';
import 'editor/settings_panel.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _initWorkspace();
  }

  Future<void> _initWorkspace() async {
    await ref.read(workspaceManagerProvider).init();
    if (mounted) {
      setState(() {
        _initialized = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.dark,
        home: Scaffold(
          backgroundColor: Color(0xFF1E1E1E),
          body: Center(child: CircularProgressIndicator(color: Colors.blueAccent)),
        ),
      );
    }

    final theme = ref.watch(activeThemeDetailedProvider);
    final workspace = ref.watch(workspacePathProvider);

    return MaterialApp(
      title: 'Typink',
      debugShowCheckedModeBanner: false,
      theme: theme.themeData,
      home: workspace == null 
        ? const WorkspaceSelectorPage() 
        : const TypstEditorPage(),
      routes: {
        '/settings': (context) => const SettingsPanel(),
      },
    );
  }
}
