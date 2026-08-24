import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:feature_connection/feature_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'loads, verifies and saves a connection through public contracts',
    () async {
      final repository = _FakeConnectionRepository();
      final credentials = _FakeCredentialRepository();
      final runtime = _FakeRuntimePort();
      final verification = _FakeVerificationPort(
        const ConnectionVerificationResult(
          algorithm: 'ssh-ed25519',
          fingerprint: 'MD5:00:01',
          trustedAt: null,
        ),
      );
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: runtime,
        verificationPort: verification,
      );
      addTearDown(viewModel.dispose);

      final config = ConnectionConfig(
        id: 'server-1',
        name: 'Production',
        host: 'prod.example.com',
        username: 'root',
      );
      await viewModel.fetchConnections();
      expect(viewModel.connections, isEmpty);

      final saved = await viewModel.verifyAndSaveConnection(
        config: config,
        isEditing: false,
        rawPassword: 'secret',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => true,
      );

      expect(saved, isTrue);
      expect(verification.calls, 1);
      expect(viewModel.connections.single.hostKeyFingerprint, 'MD5:00:01');
      expect(config.hostKeyFingerprint, 'MD5:00:01');
      expect(credentials.passwords['server-1'], 'secret');
      expect(repository.trustedIds, contains('server-1'));
    },
  );

  test('configuration write failure restores the previous structure', () async {
    final repository = _FakeConnectionRepository();
    final original = _connection('server-1')
      ..name = 'Before'
      ..hostKeyAlgorithm = 'ssh-ed25519'
      ..hostKeyFingerprint = 'MD5:00:00';
    await repository.addConnection(original);
    repository.updateErrorAfterWrite = StateError('database write failed');
    final credentials = _FakeCredentialRepository()
      ..passwords['server-1'] = 'credential-before';
    final viewModel = ConnectionViewModel(
      connectionRepository: repository,
      credentialRepository: credentials,
      hostKeyRepository: repository,
      runtimePort: _FakeRuntimePort(),
      verificationPort: _FakeVerificationPort(
        const ConnectionVerificationResult(
          algorithm: 'ssh-rsa',
          fingerprint: 'MD5:11:11',
        ),
      ),
    );
    addTearDown(viewModel.dispose);
    final edited = _connection('server-1')
      ..name = 'After'
      ..hostKeyAlgorithm = 'ssh-ed25519'
      ..hostKeyFingerprint = 'MD5:00:00';

    await expectLater(
      viewModel.verifyAndSaveConnection(
        config: edited,
        isEditing: true,
        rawPassword: 'credential-after',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => true,
      ),
      throwsStateError,
    );

    expect(repository.getConnection('server-1')?.name, 'Before');
    expect(
      repository.getConnection('server-1')?.hostKeyFingerprint,
      'MD5:00:00',
    );
    expect(credentials.passwords['server-1'], 'credential-before');
    expect(repository.trustCalls, 0);
    expect(credentials.saveCalls, 0);
    expect(edited.hostKeyFingerprint, 'MD5:00:00');
  });

  test('host-key write failure removes a newly added connection', () async {
    final repository = _FakeConnectionRepository()
      ..trustErrorAfterWrite = StateError('host-key write failed');
    final credentials = _FakeCredentialRepository();
    final viewModel = ConnectionViewModel(
      connectionRepository: repository,
      credentialRepository: credentials,
      hostKeyRepository: repository,
      runtimePort: _FakeRuntimePort(),
      verificationPort: _FakeVerificationPort(
        const ConnectionVerificationResult(
          algorithm: 'ssh-ed25519',
          fingerprint: 'MD5:11:11',
        ),
      ),
    );
    addTearDown(viewModel.dispose);
    final config = _connection('server-1');

    await expectLater(
      viewModel.verifyAndSaveConnection(
        config: config,
        isEditing: false,
        rawPassword: 'credential-after',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => true,
      ),
      throwsStateError,
    );

    expect(repository.connections, isEmpty);
    expect(credentials.saveCalls, 0);
    expect(repository.trustCalls, 2);
    expect(config.hostKeyAlgorithm, isNull);
    expect(config.hostKeyFingerprint, isNull);
    expect(config.hostKeyTrustedAt, isNull);
  });

  test(
    'credential write failure restores config host key and credentials',
    () async {
      final repository = _FakeConnectionRepository();
      final original = _connection('server-1')
        ..name = 'Before'
        ..hostKeyAlgorithm = 'ssh-ed25519'
        ..hostKeyFingerprint = 'MD5:00:00';
      await repository.addConnection(original);
      final credentials = _FakeCredentialRepository()
        ..passwords['server-1'] = 'credential-before'
        ..privateKeys['server-1'] = 'private-key-before'
        ..saveErrorAfterWrite = StateError('secure storage write failed');
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: _FakeRuntimePort(),
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(
            algorithm: 'ssh-rsa',
            fingerprint: 'MD5:11:11',
          ),
        ),
      );
      addTearDown(viewModel.dispose);
      final edited = _connection('server-1')
        ..name = 'After'
        ..hostKeyAlgorithm = 'ssh-ed25519'
        ..hostKeyFingerprint = 'MD5:00:00';

      await expectLater(
        viewModel.verifyAndSaveConnection(
          config: edited,
          isEditing: true,
          rawPassword: 'credential-after',
          rawPrivateKey: 'private-key-after',
          confirmDisconnectCallback: (_) async => true,
        ),
        throwsStateError,
      );

      final restored = repository.getConnection('server-1');
      expect(restored?.name, 'Before');
      expect(restored?.hostKeyAlgorithm, 'ssh-ed25519');
      expect(restored?.hostKeyFingerprint, 'MD5:00:00');
      expect(credentials.passwords['server-1'], 'credential-before');
      expect(credentials.privateKeys['server-1'], 'private-key-before');
      expect(credentials.saveCalls, 2);
      expect(repository.trustCalls, 2);
      expect(edited.hostKeyAlgorithm, 'ssh-ed25519');
      expect(edited.hostKeyFingerprint, 'MD5:00:00');
    },
  );

  test(
    'incomplete compensation exposes the original and rollback errors',
    () async {
      final repository = _FakeConnectionRepository();
      final original = _connection('server-1')
        ..hostKeyAlgorithm = 'ssh-ed25519'
        ..hostKeyFingerprint = 'MD5:00:00';
      await repository.addConnection(original);
      final credentials = _FakeCredentialRepository()
        ..passwords['server-1'] = 'credential-before'
        ..failAllSavesAfterWrite = true;
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: _FakeRuntimePort(),
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(
            algorithm: 'ssh-rsa',
            fingerprint: 'MD5:11:11',
          ),
        ),
      );
      addTearDown(viewModel.dispose);

      Object? failure;
      try {
        await viewModel.verifyAndSaveConnection(
          config: _connection('server-1'),
          isEditing: true,
          rawPassword: 'credential-after',
          rawPrivateKey: null,
          confirmDisconnectCallback: (_) async => true,
        );
      } catch (error) {
        failure = error;
      }

      expect(failure, isA<ConnectionSaveRollbackException>());
      final rollbackFailure = failure! as ConnectionSaveRollbackException;
      expect(rollbackFailure.cause, isA<StateError>());
      expect(rollbackFailure.rollbackErrors, hasLength(1));
      expect(rollbackFailure.toString(), contains('rollback failures: 1'));
    },
  );

  test(
    'does not save edited configuration when active-window confirmation is rejected',
    () async {
      final repository = _FakeConnectionRepository();
      final credentials = _FakeCredentialRepository();
      final runtime = _FakeRuntimePort()..activeWindows = 2;
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: runtime,
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(
            algorithm: 'ssh-ed25519',
            fingerprint: 'MD5:11:11',
          ),
        ),
      );
      addTearDown(viewModel.dispose);

      final config = ConnectionConfig(
        id: 'server-1',
        name: 'Production',
        host: 'prod.example.com',
        username: 'root',
      );
      await repository.addConnection(config);
      await viewModel.fetchConnections();

      final saved = await viewModel.verifyAndSaveConnection(
        config: config,
        isEditing: true,
        rawPassword: 'secret',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => false,
      );

      expect(saved, isFalse);
      expect(repository.updateCalls, 0);
      expect(repository.trustCalls, 0);
      expect(config.hostKeyAlgorithm, isNull);
      expect(config.hostKeyFingerprint, isNull);
      expect(runtime.disconnectCalls, 0);
    },
  );

  test('cleans runtime resources and credentials before deleting', () async {
    final repository = _FakeConnectionRepository();
    final credentials = _FakeCredentialRepository()
      ..passwords['server-1'] = 'secret';
    final runtime = _FakeRuntimePort();
    final viewModel = ConnectionViewModel(
      connectionRepository: repository,
      credentialRepository: credentials,
      hostKeyRepository: repository,
      runtimePort: runtime,
      verificationPort: _FakeVerificationPort(
        const ConnectionVerificationResult(),
      ),
    );
    addTearDown(viewModel.dispose);

    await repository.addConnection(
      ConnectionConfig(
        id: 'server-1',
        name: 'Production',
        host: 'prod.example.com',
        username: 'root',
      ),
    );
    await viewModel.fetchConnections();
    await viewModel.deleteConnectionWithCleanup('server-1');

    expect(viewModel.connections, isEmpty);
    expect(runtime.cleanedIds, contains('server-1'));
    expect(credentials.deletedIds, contains('server-1'));
  });

  test(
    'delete waits for an in-flight save mutation before removing data',
    () async {
      final updateReached = Completer<void>();
      final updateGate = Completer<void>();
      final repository = _FakeConnectionRepository()
        ..updateAfterWriteReached = updateReached
        ..updateAfterWriteGate = updateGate;
      await repository.addConnection(_connection('server-1'));
      final credentials = _FakeCredentialRepository()
        ..passwords['server-1'] = 'before';
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: _FakeRuntimePort(),
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(
            algorithm: 'ssh-ed25519',
            fingerprint: 'MD5:11:11',
          ),
        ),
      );
      addTearDown(viewModel.dispose);

      final save = viewModel.verifyAndSaveConnection(
        config: _connection('server-1')..name = 'After',
        isEditing: true,
        rawPassword: 'after',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => true,
      );
      await updateReached.future;

      final delete = viewModel.deleteConnectionWithCleanup('server-1');
      await Future<void>.delayed(Duration.zero);
      expect(repository.deleteCalls, 0);

      updateGate.complete();
      expect(await save, isFalse);
      await delete;

      expect(repository.getConnection('server-1'), isNull);
      expect(credentials.passwords.containsKey('server-1'), isFalse);
      expect(credentials.privateKeys.containsKey('server-1'), isFalse);
    },
  );

  test(
    'single delete finishes credential cleanup after UI generation changes',
    () async {
      final deleteReached = Completer<void>();
      final deleteGate = Completer<void>();
      final repository = _FakeConnectionRepository()
        ..deleteAfterWriteReached = deleteReached
        ..deleteAfterWriteGate = deleteGate;
      await repository.addConnection(_connection('server-1'));
      final credentials = _FakeCredentialRepository()
        ..passwords['server-1'] = 'secret';
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: _FakeRuntimePort(),
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(),
        ),
      );
      addTearDown(viewModel.dispose);

      final delete = viewModel.deleteConnectionWithCleanup('server-1');
      await deleteReached.future;
      await viewModel.fetchConnections();
      deleteGate.complete();
      await delete;

      expect(credentials.deletedIds, contains('server-1'));
      expect(credentials.passwords.containsKey('server-1'), isFalse);
    },
  );

  test(
    'batch delete finishes all credential cleanup after UI generation changes',
    () async {
      final deleteReached = Completer<void>();
      final deleteGate = Completer<void>();
      final repository = _FakeConnectionRepository()
        ..deleteManyAfterWriteReached = deleteReached
        ..deleteManyAfterWriteGate = deleteGate;
      await repository.addConnection(_connection('server-1'));
      await repository.addConnection(_connection('server-2'));
      final credentials = _FakeCredentialRepository()
        ..passwords['server-1'] = 'secret-1'
        ..passwords['server-2'] = 'secret-2';
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: _FakeRuntimePort(),
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(),
        ),
      );
      addTearDown(viewModel.dispose);

      final delete = viewModel.deleteConnectionsWithCleanup(<String>[
        'server-1',
        'server-2',
      ]);
      await deleteReached.future;
      await viewModel.fetchConnections();
      deleteGate.complete();
      await delete;

      expect(
        credentials.deletedIds,
        containsAll(<String>['server-1', 'server-2']),
      );
      expect(credentials.passwords, isEmpty);
    },
  );

  test('does not publish a fetch result after dispose', () async {
    final loadGate = Completer<List<ConnectionConfig>>();
    final repository = _FakeConnectionRepository(
      loadResponses: [loadGate.future],
    );
    final viewModel = ConnectionViewModel(
      connectionRepository: repository,
      credentialRepository: _FakeCredentialRepository(),
      hostKeyRepository: repository,
      runtimePort: _FakeRuntimePort(),
      verificationPort: _FakeVerificationPort(
        const ConnectionVerificationResult(),
      ),
    );
    var notificationCount = 0;
    viewModel.addListener(() => notificationCount++);

    final fetch = viewModel.fetchConnections();
    final notificationsBeforeDispose = notificationCount;
    viewModel.dispose();

    loadGate.complete([_connection('late')]);
    await fetch;

    expect(viewModel.connections, isEmpty);
    expect(notificationCount, notificationsBeforeDispose);
  });

  test('ignores a fetch failure after dispose', () async {
    final loadGate = Completer<List<ConnectionConfig>>();
    final repository = _FakeConnectionRepository(
      loadResponses: [loadGate.future],
    );
    final viewModel = ConnectionViewModel(
      connectionRepository: repository,
      credentialRepository: _FakeCredentialRepository(),
      hostKeyRepository: repository,
      runtimePort: _FakeRuntimePort(),
      verificationPort: _FakeVerificationPort(
        const ConnectionVerificationResult(),
      ),
    );
    var notificationCount = 0;
    viewModel.addListener(() => notificationCount++);

    final fetch = viewModel.fetchConnections();
    final notificationsBeforeDispose = notificationCount;
    viewModel.dispose();

    loadGate.completeError(StateError('late repository failure'));
    await expectLater(fetch, completes);

    expect(viewModel.errorMessage, isNull);
    expect(notificationCount, notificationsBeforeDispose);
  });

  test(
    'keeps the latest fetch result when an older request completes later',
    () async {
      final firstLoad = Completer<List<ConnectionConfig>>();
      final secondLoad = Completer<List<ConnectionConfig>>();
      final repository = _FakeConnectionRepository(
        loadResponses: [firstLoad.future, secondLoad.future],
      );
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: _FakeCredentialRepository(),
        hostKeyRepository: repository,
        runtimePort: _FakeRuntimePort(),
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(),
        ),
      );
      addTearDown(viewModel.dispose);
      var notificationCount = 0;
      viewModel.addListener(() => notificationCount++);

      final firstFetch = viewModel.fetchConnections();
      final secondFetch = viewModel.fetchConnections();

      secondLoad.complete([_connection('latest')]);
      await secondFetch;
      final notificationsAfterLatest = notificationCount;

      firstLoad.complete([_connection('stale')]);
      await firstFetch;

      expect(viewModel.connections.single.id, 'latest');
      expect(notificationCount, notificationsAfterLatest);
      expect(viewModel.errorMessage, isNull);
    },
  );

  test(
    'a concurrent latest operation is not overwritten by an older failure',
    () async {
      final firstLoad = Completer<List<ConnectionConfig>>();
      final repository = _FakeConnectionRepository(
        loadResponses: [
          firstLoad.future,
          Future.value([_connection('latest')]),
        ],
      );
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: _FakeCredentialRepository(),
        hostKeyRepository: repository,
        runtimePort: _FakeRuntimePort(),
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(),
        ),
      );
      addTearDown(viewModel.dispose);

      final firstFetch = viewModel.fetchConnections();
      final secondFetch = viewModel.fetchConnections();
      await secondFetch;

      firstLoad.completeError(StateError('stale failure'));
      await firstFetch;

      expect(viewModel.connections.single.id, 'latest');
      expect(viewModel.errorMessage, isNull);
    },
  );

  test('does not publish verify or save completion after dispose', () async {
    final verificationGate = Completer<ConnectionVerificationResult>();
    final repository = _FakeConnectionRepository();
    final viewModel = ConnectionViewModel(
      connectionRepository: repository,
      credentialRepository: _FakeCredentialRepository(),
      hostKeyRepository: repository,
      runtimePort: _FakeRuntimePort(),
      verificationPort: _FakeVerificationPort(
        const ConnectionVerificationResult(),
        response: verificationGate.future,
      ),
    );
    var notificationCount = 0;
    viewModel.addListener(() => notificationCount++);
    final config = _connection('late-save');

    final save = viewModel.verifyAndSaveConnection(
      config: config,
      isEditing: false,
      rawPassword: 'secret',
      rawPrivateKey: null,
      confirmDisconnectCallback: (_) async => true,
    );
    final notificationsBeforeDispose = notificationCount;
    viewModel.dispose();

    verificationGate.complete(const ConnectionVerificationResult());

    expect(await save, isFalse);
    expect(repository.connections, isEmpty);
    expect(notificationCount, notificationsBeforeDispose);
  });

  test(
    'all public async commands reject without side effects after dispose',
    () async {
      final repository = _FakeConnectionRepository();
      final credentials = _FakeCredentialRepository();
      final runtime = _FakeRuntimePort();
      final verification = _FakeVerificationPort(
        const ConnectionVerificationResult(),
      );
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: runtime,
        verificationPort: verification,
      );
      var notificationCount = 0;
      viewModel.addListener(() => notificationCount++);

      viewModel.dispose();

      await expectLater(viewModel.fetchConnections(), completes);
      await expectLater(
        viewModel.deleteConnectionWithCleanup('server-1'),
        completes,
      );
      await expectLater(
        viewModel.deleteConnectionsWithCleanup(['server-1']),
        completes,
      );
      await expectLater(viewModel.reorderConnections(0, 1), completes);
      final saved = await viewModel.verifyAndSaveConnection(
        config: _connection('server-1'),
        isEditing: false,
        rawPassword: 'secret',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => true,
      );
      expect(saved, isFalse);
      final sessionId = await viewModel.openTerminalSession(
        'server-1',
        'window',
      );
      expect(sessionId, isNull);

      expect(notificationCount, 0);
      expect(repository.loadCalls, 0);
      expect(repository.addCalls, 0);
      expect(repository.updateCalls, 0);
      expect(repository.deleteCalls, 0);
      expect(repository.deleteManyCalls, 0);
      expect(repository.reorderCalls, 0);
      expect(repository.trustCalls, 0);
      expect(credentials.saveCalls, 0);
      expect(credentials.deleteCalls, 0);
      expect(runtime.cleanupCalls, 0);
      expect(runtime.activeWindowCalls, 0);
      expect(runtime.disconnectCalls, 0);
      expect(runtime.openCalls, 0);
      expect(verification.calls, 0);
      expect(viewModel.errorMessage, isNull);
      expect(viewModel.isLoading, isFalse);
      expect(viewModel.isSaving, isFalse);
      expect(viewModel.isVerifying, isFalse);
      expect(viewModel.connections, isEmpty);
    },
  );

  test(
    'stale single delete does not publish after a newer operation',
    () async {
      final repository = _FakeConnectionRepository();
      await repository.addConnection(_connection('stale'));
      await repository.addConnection(_connection('latest'));
      final credentials = _FakeCredentialRepository();
      final runtime = _FakeRuntimePort();
      final cleanupGate = Completer<void>();
      runtime.cleanupGate = cleanupGate;
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: runtime,
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(),
        ),
      );
      addTearDown(viewModel.dispose);
      var notificationCount = 0;
      viewModel.addListener(() => notificationCount++);

      final delete = viewModel.deleteConnectionWithCleanup('stale');
      final fetch = viewModel.fetchConnections();
      await fetch;
      final notificationsAfterLatest = notificationCount;

      cleanupGate.complete();
      await delete;

      expect(repository.deleteCalls, 0);
      expect(credentials.deleteCalls, 0);
      expect(viewModel.connections.map((item) => item.id), ['stale', 'latest']);
      expect(notificationCount, notificationsAfterLatest);
    },
  );

  test('stale batch delete does not publish after a newer operation', () async {
    final repository = _FakeConnectionRepository();
    await repository.addConnection(_connection('stale'));
    await repository.addConnection(_connection('latest'));
    final credentials = _FakeCredentialRepository();
    final runtime = _FakeRuntimePort();
    final cleanupGate = Completer<void>();
    runtime.cleanupGate = cleanupGate;
    final viewModel = ConnectionViewModel(
      connectionRepository: repository,
      credentialRepository: credentials,
      hostKeyRepository: repository,
      runtimePort: runtime,
      verificationPort: _FakeVerificationPort(
        const ConnectionVerificationResult(),
      ),
    );
    addTearDown(viewModel.dispose);
    var notificationCount = 0;
    viewModel.addListener(() => notificationCount++);

    final delete = viewModel.deleteConnectionsWithCleanup(['stale']);
    final fetch = viewModel.fetchConnections();
    await fetch;
    final notificationsAfterLatest = notificationCount;

    cleanupGate.complete();
    await delete;

    expect(repository.deleteManyCalls, 0);
    expect(credentials.deleteCalls, 0);
    expect(viewModel.connections.map((item) => item.id), ['stale', 'latest']);
    expect(notificationCount, notificationsAfterLatest);
  });

  test('stale reorder does not publish after a newer operation', () async {
    final repository = _FakeConnectionRepository();
    await repository.addConnection(_connection('a'));
    await repository.addConnection(_connection('b'));
    final reorderGate = Completer<void>();
    repository.reorderGate = reorderGate;
    final viewModel = ConnectionViewModel(
      connectionRepository: repository,
      credentialRepository: _FakeCredentialRepository(),
      hostKeyRepository: repository,
      runtimePort: _FakeRuntimePort(),
      verificationPort: _FakeVerificationPort(
        const ConnectionVerificationResult(),
      ),
    );
    addTearDown(viewModel.dispose);
    var notificationCount = 0;
    viewModel.addListener(() => notificationCount++);

    final reorder = viewModel.reorderConnections(0, 1);
    final fetch = viewModel.fetchConnections();
    await fetch;
    final notificationsAfterLatest = notificationCount;

    reorderGate.complete();
    await reorder;

    expect(viewModel.connections.map((item) => item.id), ['a', 'b']);
    expect(notificationCount, notificationsAfterLatest);
  });

  test(
    'stale terminal opening does not publish after a newer operation',
    () async {
      final repository = _FakeConnectionRepository();
      final runtime = _FakeRuntimePort();
      final terminalGate = Completer<String?>();
      runtime.terminalGate = terminalGate;
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: _FakeCredentialRepository(),
        hostKeyRepository: repository,
        runtimePort: runtime,
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(),
        ),
      );
      addTearDown(viewModel.dispose);
      var notificationCount = 0;
      viewModel.addListener(() => notificationCount++);

      final terminal = viewModel.openTerminalSession('stale', 'window');
      final fetch = viewModel.fetchConnections();
      await fetch;
      final notificationsAfterLatest = notificationCount;

      terminalGate.complete('session-1');
      expect(await terminal, isNull);
      expect(viewModel.errorMessage, isNull);
      expect(notificationCount, notificationsAfterLatest);
    },
  );

  test(
    'stale save at host-key trust does not publish after a newer operation',
    () async {
      final repository = _FakeConnectionRepository();
      final credentials = _FakeCredentialRepository();
      final runtime = _FakeRuntimePort();
      final verification = _FakeVerificationPort(
        const ConnectionVerificationResult(
          algorithm: 'ssh-ed25519',
          fingerprint: 'MD5:00:01',
        ),
      );
      final trustGate = Completer<void>();
      repository.trustGate = trustGate;
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: runtime,
        verificationPort: verification,
      );
      addTearDown(viewModel.dispose);
      var notificationCount = 0;
      viewModel.addListener(() => notificationCount++);

      final save = viewModel.verifyAndSaveConnection(
        config: _connection('stale'),
        isEditing: false,
        rawPassword: 'secret',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => true,
      );
      final fetch = viewModel.fetchConnections();
      await fetch;
      final notificationsAfterLatest = notificationCount;

      trustGate.complete();
      expect(await save, isFalse);
      expect(viewModel.connections, isEmpty);
      expect(notificationCount, notificationsAfterLatest);
      expect(viewModel.isSaving, isFalse);
      expect(viewModel.isVerifying, isFalse);
    },
  );

  test(
    'stale save at active-window confirmation does not publish after a newer operation',
    () async {
      final repository = _FakeConnectionRepository();
      await repository.addConnection(_connection('stale'));
      final credentials = _FakeCredentialRepository();
      final runtime = _FakeRuntimePort()..activeWindows = 2;
      final confirmGate = Completer<bool>();
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: runtime,
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(),
        ),
      );
      addTearDown(viewModel.dispose);
      var notificationCount = 0;
      viewModel.addListener(() => notificationCount++);

      final save = viewModel.verifyAndSaveConnection(
        config: _connection('stale'),
        isEditing: true,
        rawPassword: 'secret',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) => confirmGate.future,
      );
      final fetch = viewModel.fetchConnections();
      await fetch;
      final notificationsAfterLatest = notificationCount;

      confirmGate.complete(true);
      expect(await save, isFalse);
      expect(repository.updateCalls, 0);
      expect(runtime.disconnectCalls, 0);
      expect(notificationCount, notificationsAfterLatest);
      expect(viewModel.isSaving, isFalse);
      expect(viewModel.isVerifying, isFalse);
    },
  );

  test(
    'stale save at update boundary does not publish after a newer operation',
    () async {
      final repository = _FakeConnectionRepository();
      await repository.addConnection(_connection('stale'));
      final updateGate = Completer<void>();
      repository.updateGate = updateGate;
      final credentials = _FakeCredentialRepository();
      final runtime = _FakeRuntimePort();
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: runtime,
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(),
        ),
      );
      addTearDown(viewModel.dispose);
      var notificationCount = 0;
      viewModel.addListener(() => notificationCount++);

      final save = viewModel.verifyAndSaveConnection(
        config: _connection('stale'),
        isEditing: true,
        rawPassword: 'secret',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => true,
      );
      final fetch = viewModel.fetchConnections();
      await fetch;
      final notificationsAfterLatest = notificationCount;

      updateGate.complete();
      expect(await save, isFalse);
      expect(credentials.saveCalls, 0);
      expect(runtime.disconnectCalls, 0);
      expect(notificationCount, notificationsAfterLatest);
      expect(viewModel.isSaving, isFalse);
      expect(viewModel.isVerifying, isFalse);
    },
  );

  test(
    'stale save at add boundary does not publish after a newer operation',
    () async {
      final repository = _FakeConnectionRepository();
      final addGate = Completer<void>();
      repository.addGate = addGate;
      final credentials = _FakeCredentialRepository();
      final runtime = _FakeRuntimePort();
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: runtime,
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(),
        ),
      );
      addTearDown(viewModel.dispose);
      var notificationCount = 0;
      viewModel.addListener(() => notificationCount++);

      final save = viewModel.verifyAndSaveConnection(
        config: _connection('stale'),
        isEditing: false,
        rawPassword: 'secret',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => true,
      );
      final fetch = viewModel.fetchConnections();
      await fetch;
      final notificationsAfterLatest = notificationCount;

      addGate.complete();
      expect(await save, isFalse);
      expect(credentials.saveCalls, 0);
      expect(notificationCount, notificationsAfterLatest);
      expect(viewModel.isSaving, isFalse);
      expect(viewModel.isVerifying, isFalse);
    },
  );

  test(
    'stale save at disconnect boundary does not publish after a newer operation',
    () async {
      final repository = _FakeConnectionRepository();
      await repository.addConnection(_connection('stale'));
      final credentials = _FakeCredentialRepository();
      final runtime = _FakeRuntimePort()..activeWindows = 2;
      final disconnectGate = Completer<void>();
      runtime.disconnectGate = disconnectGate;
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: runtime,
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(),
        ),
      );
      addTearDown(viewModel.dispose);
      var notificationCount = 0;
      viewModel.addListener(() => notificationCount++);

      final save = viewModel.verifyAndSaveConnection(
        config: _connection('stale'),
        isEditing: true,
        rawPassword: 'secret',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => true,
      );
      final fetch = viewModel.fetchConnections();
      await fetch;
      final notificationsAfterLatest = notificationCount;

      disconnectGate.complete();
      expect(await save, isFalse);
      expect(credentials.saveCalls, 0);
      expect(notificationCount, notificationsAfterLatest);
      expect(viewModel.isSaving, isFalse);
      expect(viewModel.isVerifying, isFalse);
    },
  );

  test(
    'stale save at credential-save boundary does not publish after a newer operation',
    () async {
      final repository = _FakeConnectionRepository();
      await repository.addConnection(_connection('stale'));
      final credentials = _FakeCredentialRepository();
      final saveGate = Completer<void>();
      credentials.saveGate = saveGate;
      final runtime = _FakeRuntimePort();
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: runtime,
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(),
        ),
      );
      addTearDown(viewModel.dispose);
      var notificationCount = 0;
      viewModel.addListener(() => notificationCount++);

      final save = viewModel.verifyAndSaveConnection(
        config: _connection('stale'),
        isEditing: true,
        rawPassword: 'secret',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => true,
      );
      final fetch = viewModel.fetchConnections();
      await fetch;
      final notificationsAfterLatest = notificationCount;

      saveGate.complete();
      expect(await save, isFalse);
      expect(viewModel.connections.single.id, 'stale');
      expect(notificationCount, notificationsAfterLatest);
      expect(viewModel.isSaving, isFalse);
      expect(viewModel.isVerifying, isFalse);
    },
  );

  test(
    'a stale save finally preserves the newer save flags and does not notify',
    () async {
      final verificationGate1 = Completer<ConnectionVerificationResult>();
      final verificationGate2 = Completer<ConnectionVerificationResult>();
      final repository = _FakeConnectionRepository();
      final credentials = _FakeCredentialRepository();
      final runtime = _FakeRuntimePort();
      final verification = _FakeVerificationPort(
        const ConnectionVerificationResult(),
        responses: [verificationGate1.future, verificationGate2.future],
      );
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: runtime,
        verificationPort: verification,
      );
      addTearDown(viewModel.dispose);
      var notificationCount = 0;
      viewModel.addListener(() => notificationCount++);

      final firstSave = viewModel.verifyAndSaveConnection(
        config: _connection('first'),
        isEditing: false,
        rawPassword: 'secret',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => true,
      );
      final secondSave = viewModel.verifyAndSaveConnection(
        config: _connection('second'),
        isEditing: false,
        rawPassword: 'secret',
        rawPrivateKey: null,
        confirmDisconnectCallback: (_) async => true,
      );
      expect(viewModel.isSaving, isTrue);
      expect(viewModel.isVerifying, isTrue);
      final notificationsWhilePending = notificationCount;

      verificationGate1.complete(const ConnectionVerificationResult());
      expect(await firstSave, isFalse);
      expect(viewModel.isSaving, isTrue);
      expect(viewModel.isVerifying, isTrue);
      expect(notificationCount, notificationsWhilePending);

      verificationGate2.complete(const ConnectionVerificationResult());
      expect(await secondSave, isTrue);
      expect(viewModel.isSaving, isFalse);
      expect(viewModel.isVerifying, isFalse);
      expect(viewModel.connections.single.id, 'second');
    },
  );

  test(
    'a reentrant listener that starts a new fetch does not drive external work in the stale operation',
    () async {
      final firstLoad = Completer<List<ConnectionConfig>>();
      final secondLoad = Completer<List<ConnectionConfig>>();
      final repository = _FakeConnectionRepository(
        loadResponses: [firstLoad.future, secondLoad.future],
      );
      final viewModel = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: _FakeCredentialRepository(),
        hostKeyRepository: repository,
        runtimePort: _FakeRuntimePort(),
        verificationPort: _FakeVerificationPort(
          const ConnectionVerificationResult(),
        ),
      );
      addTearDown(viewModel.dispose);
      var reentered = false;
      Future<void>? reentrantFetch;
      viewModel.addListener(() {
        if (!reentered) {
          reentered = true;
          reentrantFetch = viewModel.fetchConnections();
        }
      });

      final firstFetch = viewModel.fetchConnections();
      await firstFetch;

      // The stale (first) operation returned before touching the repository;
      // only the reentrant fetch reached loadConnections.
      expect(repository.loadCalls, 1);

      firstLoad.complete([_connection('reentrant')]);
      await reentrantFetch!;
      expect(viewModel.connections.single.id, 'reentrant');
    },
  );
}

ConnectionConfig _connection(String id) => ConnectionConfig(
  id: id,
  name: id,
  host: '$id.example.com',
  username: 'root',
);

final class _FakeConnectionRepository
    implements ConnectionRepository, HostKeyRepository {
  _FakeConnectionRepository({
    Iterable<Future<List<ConnectionConfig>>>? loadResponses,
  }) : _loadResponses = List<Future<List<ConnectionConfig>>>.from(
         loadResponses ?? const [],
       );

  final List<ConnectionConfig> _items = [];
  final List<String> trustedIds = [];
  final List<Future<List<ConnectionConfig>>> _loadResponses;
  int loadCalls = 0;
  int addCalls = 0;
  int updateCalls = 0;
  int deleteCalls = 0;
  int deleteManyCalls = 0;
  int reorderCalls = 0;
  int trustCalls = 0;
  Completer<void>? addGate;
  Completer<void>? updateGate;
  Completer<void>? updateAfterWriteReached;
  Completer<void>? updateAfterWriteGate;
  Completer<void>? deleteAfterWriteReached;
  Completer<void>? deleteAfterWriteGate;
  Completer<void>? deleteManyAfterWriteReached;
  Completer<void>? deleteManyAfterWriteGate;
  Completer<void>? reorderGate;
  Completer<void>? trustGate;
  Object? updateErrorAfterWrite;
  Object? trustErrorAfterWrite;

  @override
  List<ConnectionConfig> get connections => List.unmodifiable(_items);

  @override
  Future<void> initialize() async {}

  @override
  Future<List<ConnectionConfig>> loadConnections() {
    loadCalls++;
    if (_loadResponses.isEmpty) return Future.value(connections);
    return _loadResponses.removeAt(0);
  }

  @override
  Future<void> addConnection(ConnectionConfig config) async {
    addCalls++;
    final gate = addGate;
    addGate = null;
    if (gate != null) {
      await gate.future;
    }
    _items.add(ConnectionConfig.fromJson(config.toJson()));
  }

  @override
  Future<void> updateConnection(ConnectionConfig config) async {
    updateCalls++;
    final gate = updateGate;
    updateGate = null;
    if (gate != null) {
      await gate.future;
    }
    final index = _items.indexWhere((item) => item.id == config.id);
    _items[index] = ConnectionConfig.fromJson(config.toJson());
    updateAfterWriteReached?.complete();
    updateAfterWriteReached = null;
    final afterWriteGate = updateAfterWriteGate;
    updateAfterWriteGate = null;
    if (afterWriteGate != null) await afterWriteGate.future;
    final error = updateErrorAfterWrite;
    updateErrorAfterWrite = null;
    if (error != null) throw error;
  }

  @override
  Future<void> deleteConnection(String id) async {
    deleteCalls++;
    _items.removeWhere((item) => item.id == id);
    deleteAfterWriteReached?.complete();
    deleteAfterWriteReached = null;
    final gate = deleteAfterWriteGate;
    deleteAfterWriteGate = null;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> deleteConnections(List<String> ids) async {
    deleteManyCalls++;
    _items.removeWhere((item) => ids.contains(item.id));
    deleteManyAfterWriteReached?.complete();
    deleteManyAfterWriteReached = null;
    final gate = deleteManyAfterWriteGate;
    deleteManyAfterWriteGate = null;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    reorderCalls++;
    final gate = reorderGate;
    reorderGate = null;
    if (gate != null) {
      await gate.future;
    }
    final item = _items.removeAt(oldIndex);
    _items.insert(newIndex, item);
  }

  @override
  ConnectionConfig? getConnection(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) async {
    trustCalls++;
    final gate = trustGate;
    trustGate = null;
    if (gate != null) {
      await gate.future;
    }
    trustedIds.add(connectionId);
    final config = getConnection(connectionId);
    if (config == null) return;
    config.hostKeyAlgorithm = algorithm;
    config.hostKeyFingerprint = fingerprint;
    config.hostKeyTrustedAt = trustedAt;
    final error = trustErrorAfterWrite;
    trustErrorAfterWrite = null;
    if (error != null) throw error;
  }
}

final class _FakeCredentialRepository implements CredentialRepository {
  final Map<String, String?> passwords = {};
  final Map<String, String?> privateKeys = {};
  final List<String> deletedIds = [];
  int saveCalls = 0;
  int deleteCalls = 0;
  Completer<void>? saveGate;
  Object? saveErrorAfterWrite;
  bool failAllSavesAfterWrite = false;

  @override
  Future<String?> getPassword(String connectionId) async =>
      passwords[connectionId];

  @override
  Future<String?> getPrivateKey(String connectionId) async =>
      privateKeys[connectionId];

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) async {
    saveCalls++;
    final gate = saveGate;
    saveGate = null;
    if (gate != null) {
      await gate.future;
    }
    passwords[connectionId] = password;
    privateKeys[connectionId] = privateKey;
    final error = saveErrorAfterWrite;
    saveErrorAfterWrite = null;
    if (error != null) throw error;
    if (failAllSavesAfterWrite) {
      throw StateError('secure storage remains unavailable');
    }
  }

  @override
  Future<void> deleteCredentials(String connectionId) async {
    deleteCalls++;
    deletedIds.add(connectionId);
    passwords.remove(connectionId);
    privateKeys.remove(connectionId);
  }
}

final class _FakeRuntimePort implements ConnectionRuntimePort {
  int activeWindows = 0;
  int disconnectCalls = 0;
  int cleanupCalls = 0;
  int activeWindowCalls = 0;
  int openCalls = 0;
  final List<String> cleanedIds = [];
  Completer<void>? cleanupGate;
  Completer<void>? disconnectGate;
  Completer<String?>? terminalGate;

  @override
  String? get errorMessage => 'fake runtime error';

  @override
  Future<int> activeWindowCount(String connectionId) async {
    activeWindowCalls++;
    return activeWindows;
  }

  @override
  Future<void> disconnectSessionsForConnection(String connectionId) async {
    disconnectCalls++;
    final gate = disconnectGate;
    disconnectGate = null;
    if (gate != null) {
      await gate.future;
    }
  }

  @override
  Future<void> cleanupConnectionResources(String connectionId) async {
    cleanupCalls++;
    final gate = cleanupGate;
    cleanupGate = null;
    if (gate != null) {
      await gate.future;
    }
    cleanedIds.add(connectionId);
  }

  @override
  Future<String?> openTerminalSession(
    String connectionId,
    String windowName, {
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) async {
    openCalls++;
    final gate = terminalGate;
    terminalGate = null;
    if (gate != null) {
      return gate.future;
    }
    return null;
  }
}

final class _FakeVerificationPort implements ConnectionVerificationPort {
  _FakeVerificationPort(
    this.result, {
    this.response,
    Iterable<Future<ConnectionVerificationResult>>? responses,
  }) : _responses = responses == null
           ? null
           : List<Future<ConnectionVerificationResult>>.from(responses);

  final ConnectionVerificationResult result;
  final Future<ConnectionVerificationResult>? response;
  final List<Future<ConnectionVerificationResult>>? _responses;
  int calls = 0;

  @override
  Future<ConnectionVerificationResult> verify(
    ConnectionConfig config, {
    required String? password,
    required String? privateKey,
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) async {
    calls++;
    if (_responses != null && _responses.isNotEmpty) {
      return _responses.removeAt(0);
    }
    return response ?? result;
  }
}
