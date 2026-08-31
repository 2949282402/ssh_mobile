import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/services/connection_target_binding.dart';

void main() {
  test('normalizes empty optional routing and invalid fingerprints safely', () {
    final config = ConnectionConfig(
      id: 'server-1',
      name: 'Server',
      host: '  EXAMPLE.com  ',
      username: 'root',
      hostKeyFingerprint: 'not-a-fingerprint',
      hostKeyAlgorithm: '  SSH-ED25519  ',
      jumpHost: '   ',
      jumpPort: 2222,
      jumpUsername: 'jump',
    );
    final binding = ConnectionTargetBinding.fromConfig(config);

    expect(binding.host, 'example.com');
    expect(binding.hostKeyFingerprint, 'not-a-fingerprint');
    expect(binding.hostKeyAlgorithm, 'ssh-ed25519');
    expect(binding.jumpHost, isNull);
    expect(binding.jumpPort, isNull);
    expect(binding.jumpUsername, isNull);
    expect(binding.matches(config), isTrue);
    expect(binding.matches(null), isFalse);
    expect(binding.matches(config.copyWith(id: 'other')), isFalse);
    expect(binding.config.password, isNull);
    expect(binding.fingerprint, contains('server-1'));
  });

  test(
    'runtime target rejects changed bindings and returns isolated config',
    () {
      final config = ConnectionConfig(
        id: 'server-1',
        name: 'Server',
        host: 'example.com',
        username: 'root',
      );
      final binding = ConnectionTargetBinding.fromConfig(config);
      final target = ConnectionRuntimeTarget(
        binding,
        config,
        'password',
        'private-key',
      );
      final copy = target.config..host = 'mutated.example.com';
      expect(copy.host, 'mutated.example.com');
      expect(target.config.host, 'example.com');
      expect(target.password, 'password');
      expect(target.privateKey, 'private-key');

      expect(
        () => ConnectionRuntimeTarget(
          binding,
          config.copyWith(port: 2200),
          null,
          null,
        ),
        throwsArgumentError,
      );
    },
  );
}
