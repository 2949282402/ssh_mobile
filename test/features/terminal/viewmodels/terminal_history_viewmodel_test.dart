import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/terminal/viewmodels/terminal_history_viewmodel.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;
  late SshService sshService;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = StorageService();
    await storageService.init();

    sshService = SshService(storageService);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    storageService.dispose();
  });

  group('TerminalHistoryViewModel Tests', () {
    test('Initialization queries historical records', () {
      final viewModel = TerminalHistoryViewModel(sshService: sshService);
      addTearDown(viewModel.dispose);

      expect(viewModel.recordsFuture, isNotNull);
    });

    test('serializes deletes and exposes queued records as busy', () async {
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final started = <String>[];
      var loadCalls = 0;
      final viewModel = TerminalHistoryViewModel.forTesting(
        loadRecords: () async {
          loadCalls += 1;
          return const [];
        },
        removeRecord: (sessionId) async {
          started.add(sessionId);
          if (sessionId == 'first') {
            firstStarted.complete();
            await firstGate.future;
          } else {
            secondStarted.complete();
            await secondGate.future;
          }
        },
      );
      addTearDown(viewModel.dispose);

      final firstDelete = viewModel.deleteRecord('first');
      final secondDelete = viewModel.deleteRecord('second');
      await firstStarted.future;

      expect(started, ['first']);
      expect(viewModel.isDeleting('first'), isTrue);
      expect(viewModel.isDeleting('second'), isTrue);

      firstGate.complete();
      await secondStarted.future;
      expect(started, ['first', 'second']);

      secondGate.complete();
      await Future.wait([firstDelete, secondDelete]);
      expect(loadCalls, 3);
      expect(viewModel.isDeleting('first'), isFalse);
      expect(viewModel.isDeleting('second'), isFalse);
    });

    test(
      'pending delete can finish after disposal without notifying',
      () async {
        final removeStarted = Completer<void>();
        final removeGate = Completer<void>();
        final viewModel = TerminalHistoryViewModel.forTesting(
          loadRecords: () async => const [],
          removeRecord: (_) async {
            removeStarted.complete();
            await removeGate.future;
          },
        );

        final deletion = viewModel.deleteRecord('pending');
        await removeStarted.future;
        viewModel.dispose();
        removeGate.complete();

        await expectLater(deletion, completes);
      },
    );
  });
}
