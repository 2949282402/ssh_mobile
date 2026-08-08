import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_ai/ai_skills.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/services/connection_target_binding.dart';
import 'package:ssh_mobile/services/remote_target_scope.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ConnectionTargetBinding', () {
    test('is non-secret, deeply copied, and ignores display-only edits', () {
      final source = _connection(
        id: 'server-a',
        name: 'Primary',
        host: 'EXAMPLE.com',
        password: 'password-value',
        privateKey: 'private-key-value',
        hostKeyFingerprint:
            'MD5:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff',
        hostKeyAlgorithm: 'SSH-ED25519',
      );
      final binding = ConnectionTargetBinding.fromConfig(source);
      final fingerprint = binding.fingerprint;

      source
        ..name = 'Mutated source'
        ..host = 'other.example.com'
        ..updatedAt = DateTime.utc(2030);
      final exposedCopy = binding.config
        ..host = 'third.example.com'
        ..password = 'should-not-stick';

      expect(binding.name, 'Primary');
      expect(binding.host, 'example.com');
      expect(binding.config.host, 'EXAMPLE.com');
      expect(binding.config.password, isNull);
      expect(binding.config.privateKey, isNull);
      expect(exposedCopy.host, 'third.example.com');
      expect(binding.fingerprint, fingerprint);

      final displayOnlyEdit = _connection(
        id: 'server-a',
        name: 'Renamed',
        host: 'example.COM',
        password: 'rotated-password',
        privateKey: 'rotated-key',
        hostKeyFingerprint: 'md5:00112233445566778899AABBCCDDEEFF',
        hostKeyAlgorithm: 'ssh-ed25519',
        updatedAt: DateTime.utc(2040),
        hostKeyTrustedAt: DateTime.utc(2040),
      );
      expect(binding.matches(displayOnlyEdit), isTrue);
      expect(
        ConnectionTargetBinding.fromConfig(displayOnlyEdit).fingerprint,
        fingerprint,
      );
    });

    test('detects routing, authentication, platform, and host-key edits', () {
      final source = _connection(
        id: 'server-a',
        host: 'example.com',
        jumpHost: 'jump.example.com',
        jumpPort: 2222,
        jumpUsername: 'jump-user',
        hostKeyFingerprint:
            'MD5:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff',
        hostKeyAlgorithm: 'ssh-ed25519',
      );
      final binding = ConnectionTargetBinding.fromConfig(source);

      expect(
        binding.matches(source.copyWith(host: 'other.example.com')),
        isFalse,
      );
      expect(binding.matches(source.copyWith(port: 2200)), isFalse);
      expect(binding.matches(source.copyWith(username: 'other-user')), isFalse);
      expect(
        binding.matches(source.copyWith(username: '${source.username} ')),
        isFalse,
      );
      expect(
        binding.matches(source.copyWith(authMethod: AuthMethod.privateKey)),
        isFalse,
      );
      expect(
        binding.matches(
          source.copyWith(serverPlatform: ServerPlatform.windows),
        ),
        isFalse,
      );
      expect(
        binding.matches(source.copyWith(launchMode: TerminalLaunchMode.tmux)),
        isFalse,
      );
      expect(
        binding.matches(source.copyWith(tmuxAutoDeleteSeconds: 30)),
        isFalse,
      );
      expect(binding.matches(source.copyWith(jumpPort: 2201)), isFalse);
      expect(
        binding.matches(
          _connection(
            id: source.id,
            host: source.host,
            jumpHost: source.jumpHost,
            jumpPort: source.jumpPort,
            jumpUsername: source.jumpUsername,
            hostKeyFingerprint:
                'MD5:ff:ee:dd:cc:bb:aa:99:88:77:66:55:44:33:22:11:00',
            hostKeyAlgorithm: source.hostKeyAlgorithm,
          ),
        ),
        isFalse,
      );
    });
  });

  group('StorageService remote target boundary', () {
    late StorageService storage;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      storage = StorageService();
      await storage.init();
    });

    tearDown(() async {
      await storage.shutdown();
      storage.dispose();
    });

    test(
      'atomically resolves a deep config copy with secure credentials',
      () async {
        final config = _connection(
          id: 'server-a',
          host: 'one.example.com',
          password: 'password-a',
          privateKey: 'key-a',
        );
        await storage.addConnection(config);
        final binding = storage.captureConnectionTargetBindings([
          'server-a',
        ])['server-a']!;

        final target = await storage.resolveConnectionTarget(binding);

        expect(target, isNotNull);
        expect(target!.password, 'password-a');
        expect(target.privateKey, 'key-a');
        expect(target.config.host, 'one.example.com');
        final mutableCopy = target.config..host = 'mutated.example.com';
        expect(mutableCopy.host, 'mutated.example.com');
        expect(target.config.host, 'one.example.com');

        await storage.updateConnection(
          config.copyWith(
            name: 'Renamed',
            password: 'password-b',
            privateKey: 'key-b',
          ),
        );
        final afterDisplayEdit = await storage.resolveConnectionTarget(binding);
        expect(afterDisplayEdit, isNotNull);
        expect(afterDisplayEdit!.password, 'password-b');
        expect(afterDisplayEdit.privateKey, 'key-b');

        await storage.updateConnection(
          config.copyWith(host: 'two.example.com'),
        );
        expect(await storage.resolveConnectionTarget(binding), isNull);
      },
    );

    test('connection compare-and-swap APIs reject stale targets', () async {
      final original = _connection(id: 'server-a', host: 'one.example.com');
      await storage.addConnection(original);
      final stale = storage.captureConnectionTargetBindings([
        'server-a',
      ])['server-a']!;
      await storage.updateConnection(
        original.copyWith(host: 'two.example.com'),
      );

      expect(
        await storage.updateConnectionIfMatches(
          stale,
          original.copyWith(name: 'Should not apply'),
        ),
        isFalse,
      );
      expect(await storage.deleteConnectionIfMatches(stale), isFalse);
      expect(storage.getConnection('server-a')!.host, 'two.example.com');

      final current = storage.captureConnectionTargetBindings([
        'server-a',
      ])['server-a']!;
      expect(
        await storage.updateConnectionIfMatches(
          current,
          storage.getConnection('server-a')!.copyWith(name: 'CAS rename'),
        ),
        isTrue,
      );
      expect(storage.getConnection('server-a')!.name, 'CAS rename');
      expect(await storage.deleteConnectionIfMatches(current), isTrue);
      expect(storage.getConnection('server-a'), isNull);
    });

    test(
      'full connection snapshot CAS preserves credentials and user edits',
      () async {
        final original = _connection(
          id: 'server-a',
          host: 'one.example.com',
          password: 'password-a',
          privateKey: 'key-a',
        );
        await storage.addConnection(original);
        final expected = ConnectionConfig.fromJson(
          storage.getConnection('server-a')!.toJson(),
        );

        expect(
          await storage.updateConnectionFromSnapshotIfUnchanged(
            expected: expected,
            next: expected.copyWith(name: 'Approved rename'),
          ),
          isTrue,
        );
        expect(await storage.getPassword('server-a'), 'password-a');
        expect(await storage.getPrivateKey('server-a'), 'key-a');

        final staleExpected = ConnectionConfig.fromJson(
          storage.getConnection('server-a')!.toJson(),
        );
        await storage.updateConnection(
          storage.getConnection('server-a')!.copyWith(group: 'User edit'),
        );
        expect(
          await storage.updateConnectionFromSnapshotIfUnchanged(
            expected: staleExpected,
            next: staleExpected.copyWith(name: 'Must not overwrite'),
          ),
          isFalse,
        );
        expect(storage.getConnection('server-a')!.group, 'User edit');
        expect(storage.getConnection('server-a')!.name, 'Approved rename');
      },
    );

    test(
      'scope rejects unbound and changed targets before remote I/O',
      () async {
        final first = _connection(id: 'server-a', host: 'one.example.com');
        final second = _connection(id: 'server-b', host: 'two.example.com');
        await storage.addConnection(first);
        await storage.addConnection(second);
        final bindings = storage.captureConnectionTargetBindings(['server-a']);

        await RemoteTargetScope.run(bindings, () async {
          expect(
            (await RemoteTargetScope.resolveIfBound(
              storage,
              'server-a',
            )).config.host,
            'one.example.com',
          );
          await expectLater(
            RemoteTargetScope.resolveIfBound(storage, 'server-b'),
            throwsA(
              isA<RemoteTargetScopeException>().having(
                (error) => error.code,
                'code',
                'connection_not_bound',
              ),
            ),
          );
        });

        await storage.updateConnection(
          first.copyWith(host: 'changed.example.com'),
        );
        await RemoteTargetScope.run(bindings, () async {
          await expectLater(
            RemoteTargetScope.resolveIfBound(storage, 'server-a'),
            throwsA(
              isA<RemoteTargetScopeException>().having(
                (error) => error.code,
                'code',
                'approval_target_changed',
              ),
            ),
          );
        });
      },
    );

    test(
      'SSH and detached SFTP stop stale scoped targets before sockets',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        final ssh = SshService(storage);
        final sftp = SftpService(storage);
        try {
          final original = _connection(id: 'server-a', host: 'one.example.com');
          await storage.addConnection(original);
          final bindings = storage.captureConnectionTargetBindings([
            'server-a',
          ]);
          await storage.updateConnection(
            original.copyWith(host: 'changed.example.com'),
          );

          await RemoteTargetScope.run(bindings, () async {
            await expectLater(
              ssh.runOneShotCommand(
                connectionId: 'server-a',
                command: 'whoami',
              ),
              throwsA(isA<RemoteTargetScopeException>()),
            );
            await expectLater(
              sftp.listDirectoryForConnection('server-a', '/'),
              throwsA(isA<RemoteTargetScopeException>()),
            );
          });
        } finally {
          sftp.dispose();
          ssh.dispose();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });

  group('AI skill compare-and-swap storage', () {
    late StorageService storage;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      storage = StorageService();
      await storage.init();
    });

    tearDown(() async {
      await storage.shutdown();
      storage.dispose();
    });

    test('saves only when the complete expected record is unchanged', () async {
      final createdAt = DateTime.utc(2026, 1, 1);
      final expected = AiSkillRecord(
        id: 'skill-a',
        name: 'Skill A',
        description: 'Original',
        content: 'original content',
        createdAt: createdAt,
        updatedAt: createdAt,
      );
      await storage.saveAiSkill(expected);
      final next = expected.copyWith(
        content: 'approved content',
        updatedAt: createdAt.add(const Duration(seconds: 1)),
      );

      expect(await storage.saveAiSkillIfUnchanged(expected, next), isTrue);
      expect((await storage.loadAiSkills()).single.content, 'approved content');

      final staleNext = next.copyWith(
        content: 'must not overwrite',
        updatedAt: createdAt.add(const Duration(seconds: 2)),
      );
      expect(
        await storage.saveAiSkillIfUnchanged(expected, staleNext),
        isFalse,
      );
      expect((await storage.loadAiSkills()).single.content, 'approved content');
    });
  });

  group('Playbook action compare-and-swap storage', () {
    late StorageService storage;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      storage = StorageService();
      await storage.init();
    });

    tearDown(() async {
      await storage.shutdown();
      storage.dispose();
    });

    test(
      'ignores execution state but rejects approved command edits',
      () async {
        final createdAt = DateTime.utc(2026, 1, 1);
        final original = Playbook(
          id: 'playbook-a',
          name: 'Deploy',
          description: 'Safe deploy',
          steps: [
            PlaybookStep(
              id: 'step-a',
              name: 'Check',
              command: 'whoami',
              description: 'Check user',
              expectedOutcomeRegex: 'root',
            ),
          ],
          createdAt: createdAt,
          updatedAt: createdAt,
        );
        await storage.savePlaybook(original);
        final fingerprint = _playbookActionFingerprint(original);
        final executionState = original.copyWith(
          steps: [
            original.steps.single.copyWith(
              status: StepStatus.success,
              stdout: 'root',
              exitCode: 0,
            ),
          ],
          updatedAt: createdAt.add(const Duration(seconds: 1)),
          lastConnectionId: 'server-a',
        );

        expect(
          await storage.savePlaybookIfActionUnchanged(
            playbookId: original.id,
            expectedActionFingerprint: fingerprint,
            playbook: executionState,
          ),
          isTrue,
        );

        final edited = executionState.copyWith(
          steps: [executionState.steps.single.copyWith(command: 'id')],
          updatedAt: createdAt.add(const Duration(seconds: 2)),
        );
        await storage.savePlaybook(edited);
        expect(
          await storage.savePlaybookIfActionUnchanged(
            playbookId: original.id,
            expectedActionFingerprint: fingerprint,
            playbook: executionState.copyWith(
              updatedAt: createdAt.add(const Duration(seconds: 3)),
            ),
          ),
          isFalse,
        );
        expect(
          (await storage.loadPlaybooks()).single.steps.single.command,
          'id',
        );
      },
    );
  });
}

ConnectionConfig _connection({
  required String id,
  String name = 'Server',
  String host = 'example.com',
  int port = 22,
  String username = 'root',
  String? password,
  String? privateKey,
  AuthMethod authMethod = AuthMethod.both,
  ServerPlatform serverPlatform = ServerPlatform.linux,
  String? hostKeyFingerprint,
  String? hostKeyAlgorithm,
  DateTime? hostKeyTrustedAt,
  String? jumpHost,
  int? jumpPort,
  String? jumpUsername,
  DateTime? updatedAt,
}) {
  return ConnectionConfig(
    id: id,
    name: name,
    host: host,
    port: port,
    username: username,
    password: password,
    privateKey: privateKey,
    authMethod: authMethod,
    serverPlatform: serverPlatform,
    hostKeyFingerprint: hostKeyFingerprint,
    hostKeyAlgorithm: hostKeyAlgorithm,
    hostKeyTrustedAt: hostKeyTrustedAt,
    jumpHost: jumpHost,
    jumpPort: jumpPort,
    jumpUsername: jumpUsername,
    updatedAt: updatedAt,
  );
}

String _playbookActionFingerprint(Playbook playbook) {
  return jsonEncode({
    'id': playbook.id,
    'name': playbook.name,
    'description': playbook.description,
    'steps': playbook.steps
        .map(
          (step) => {
            'id': step.id,
            'name': step.name,
            'command': step.command,
            'description': step.description,
            'expectedOutcomeRegex': step.expectedOutcomeRegex,
          },
        )
        .toList(growable: false),
  });
}
