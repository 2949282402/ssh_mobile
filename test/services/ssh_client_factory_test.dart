import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/core/services/ssh_client_factory.dart';

void main() {
  group('SshClientFactory', () {
    test(
        'answers a single hidden keyboard-interactive prompt with the password',
        () {
      final responses =
          SshClientFactory.keyboardInteractiveResponsesForPassword(
        const _FakeKeyboardInteractiveRequest(
          'password',
          [_FakeKeyboardInteractivePrompt('Password: ', false)],
        ),
        'secret',
      );
      expect(responses, ['secret']);
    });

    test(
        'skips multi-factor keyboard-interactive prompts it cannot answer safely',
        () {
      final responses =
          SshClientFactory.keyboardInteractiveResponsesForPassword(
        const _FakeKeyboardInteractiveRequest(
          'mfa',
          [
            _FakeKeyboardInteractivePrompt('Password: ', false),
            _FakeKeyboardInteractivePrompt('Verification code: ', false),
          ],
        ),
        'secret',
      );
      expect(responses, isNull);
    });

    test('rejects password auth when the password is missing', () {
      expect(
        () => SshClientFactory.validateAuthSecrets(
          config: ConnectionConfig(
            id: 'id',
            name: 'server',
            host: 'example.com',
            username: 'user',
            authMethod: AuthMethod.password,
          ),
          password: null,
          privateKey: null,
        ),
        throwsStateError,
      );
    });

    test('does not expose password callbacks for private-key-only auth', () {
      final options = SshClientFactory.buildAuthOptions(
        config: ConnectionConfig(
          id: 'id',
          name: 'server',
          host: 'example.com',
          username: 'user',
          authMethod: AuthMethod.privateKey,
        ),
        credentials: const SshCredentials(
          password: null,
          privateKey: null,
        ),
        identities: null,
      );

      expect(options.onPasswordRequest, isNull);
      expect(options.onUserInfoRequest, isNull);
    });
  });
}

class _FakeKeyboardInteractiveRequest {
  final String name;
  final List<_FakeKeyboardInteractivePrompt> prompts;

  const _FakeKeyboardInteractiveRequest(this.name, this.prompts);
}

class _FakeKeyboardInteractivePrompt {
  final String promptText;
  final bool echo;

  const _FakeKeyboardInteractivePrompt(this.promptText, this.echo);
}
