import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'workspace_provider.dart';

class WorkspaceSelectorPage extends ConsumerWidget {
  const WorkspaceSelectorPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.book, size: 80, color: Colors.blueAccent),
                const SizedBox(height: 24),
                const Text(
                  'Welcome to Typink',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Select a directory to store your scientific notebooks.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 48),
                ElevatedButton.icon(
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Open Workspace'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  ),
                  onPressed: () async {
                    String? result = await FilePicker.platform.getDirectoryPath();
                    if (result != null) {
                      await ref.read(workspaceManagerProvider).openWorkspace(Directory(result));
                    }
                  },
                ),
                const SizedBox(height: 16),
                const Text('OR', style: TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 16),
                const Text(
                  'Recommendation: Select a directory synced with Syncthing or Dropbox for multi-device support.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
