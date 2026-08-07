import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'ConnectionConfig JSON and copyWith keep credentials out of structure',
    () {
      final source = ConnectionConfig(
        id: 'server-1',
        name: 'Production',
        host: 'example.com',
        username: 'gary',
        password: 'not-for-json',
        privateKey: 'not-for-json-either',
        hostKeyFingerprint: 'SHA256:fingerprint',
      );

      final json = source.toJson();
      expect(json, isNot(contains('password')));
      expect(json, isNot(contains('privateKey')));

      final restored = ConnectionConfig.fromJson(json);
      expect(restored.password, isNull);
      expect(restored.privateKey, isNull);
      expect(restored.hostKeyFingerprint, source.hostKeyFingerprint);

      final moved = source.copyWith(host: 'other.example.com');
      expect(moved.hostKeyFingerprint, isNull);
      expect(moved.password, source.password);
      expect(moved.privateKey, source.privateKey);
    },
  );

  test('Windows profile cannot retain tmux launch mode', () {
    final profile = ConnectionProfile(
      id: 'server-2',
      name: 'Windows',
      host: 'win.example.com',
      username: 'administrator',
      serverPlatform: ServerPlatform.windows,
      launchMode: TerminalLaunchMode.tmux,
    );

    expect(profile.launchMode, TerminalLaunchMode.tmux);
    final restored = ConnectionProfile.fromJson(profile.toJson());
    expect(restored.launchMode, TerminalLaunchMode.ssh);
  });
}
