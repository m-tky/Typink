import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:typink/editor/providers.dart';
import 'package:path/path.dart' as p;

void main() {
  // Mock necessary for File operations in tests
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PersistenceManager Tests', () {
    late ProviderContainer container;
    late PersistenceManager manager;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('typink_test_');
      container = ProviderContainer();
      manager = container.read(persistenceProvider);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      container.dispose();
    });

    test('Monotonic versioning prevents stale overrides', () async {
      final file = File(p.join(tempDir.path, 'test.typ'));
      await file.writeAsString('v0');

      container.read(currentTypFileProvider.notifier).state = file;
      manager.updateLastSavedContent('v0', path: file.path);

      // Save version 2 (newer)
      await manager.saveTypst('v2', version: 2, targetPath: file.path);
      expect(await file.readAsString(), 'v2');

      // Attempt to save version 1 (older than current committed v2) - should be ignored
      await manager.saveTypst('v1', version: 1, targetPath: file.path);
      expect(await file.readAsString(), 'v2');
    });

    test('File mismatch prevention during switch', () async {
      final fileA = File(p.join(tempDir.path, 'a.typ'));
      final fileB = File(p.join(tempDir.path, 'b.typ'));
      await fileA.writeAsString('contentA');
      await fileB.writeAsString('contentB');

      // Set active file to A
      container.read(currentTypFileProvider.notifier).state = fileA;
      manager.updateLastSavedContent('contentA', path: fileA.path);

      // Start a save intended for A, but switch to B before it executes in the queue
      final saveA =
          manager.saveTypst('newA', version: 1, targetPath: fileA.path);

      // Synchronously switch active file to B
      container.read(currentTypFileProvider.notifier).state = fileB;

      await saveA;

      // A should NOT have been updated because of the currentTypFileProvider path check
      expect(await fileA.readAsString(), 'contentA');
      expect(await fileB.readAsString(), 'contentB');
    });

    test('Atomic write safeguard (Temp -> Rename)', () async {
      final file = File(p.join(tempDir.path, 'atomic.typ'));
      await file.writeAsString('original');

      container.read(currentTypFileProvider.notifier).state = file;
      manager.updateLastSavedContent('original', path: file.path);

      await manager.saveTypst('updated', version: 1, targetPath: file.path);

      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), 'updated');
      // Verify temp file is cleaned up
      expect(await File('${file.path}.tmp').exists(), isFalse);
    });

    test('Empty overwrite safeguard', () async {
      final file = File(p.join(tempDir.path, 'non_empty.typ'));
      await file.writeAsString('important content');

      container.read(currentTypFileProvider.notifier).state = file;
      manager.updateLastSavedContent('important content', path: file.path);

      // Attempt to save empty content when last saved was non-empty
      await manager.saveTypst('', version: 1, targetPath: file.path);

      // Should NOT overwrite with empty string
      expect(await file.readAsString(), 'important content');
    });
  });
}
