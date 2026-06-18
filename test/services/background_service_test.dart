import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/background_service.dart';

void main() {
  group('BackgroundServiceManager', () {
    test('sanitizes reconnect payload without retaining SSH secrets', () {
      final sanitized = sanitizeBackgroundReconnectData({
        'sessionId': 'session-1',
        'id': 'connection-1',
        'host': 'example.com',
        'port': 22,
        'username': 'user',
        'password': 'secret-password',
        'privateKey': 'secret-private-key',
        'authMethod': 'both',
        'hostKeyFingerprint': 'MD5:00:01',
      });

      expect(sanitized, isNot(contains('password')));
      expect(sanitized, isNot(contains('privateKey')));
      expect(sanitized['sessionId'], 'session-1');
      expect(sanitized['id'], 'connection-1');
      expect(sanitized['host'], 'example.com');
      expect(sanitized['username'], 'user');
      expect(sanitized['hostKeyFingerprint'], 'MD5:00:01');
    });

    test('tmux unexpected disconnect requires app reconnect', () {
      final decision = decideBackgroundUnexpectedDisconnect(
        launchMode: 'tmux',
        reason: 'stdout closed',
      );

      expect(decision.reconnectInBackground, isFalse);
      expect(decision.requiresAppReconnect, isTrue);
      expect(decision.message, contains('Reconnect from the app'));
    });

    test('plain ssh unexpected disconnect does not background reconnect', () {
      final decision = decideBackgroundUnexpectedDisconnect(
        launchMode: 'ssh',
        reason: 'socket closed',
      );

      expect(decision.reconnectInBackground, isFalse);
      expect(decision.requiresAppReconnect, isFalse);
      expect(decision.message, 'Connection lost: socket closed');
    });
  });
}
