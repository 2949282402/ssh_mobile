import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/lan_share/utils/lan_text_action_helper.dart';

void main() {
  group('LanTextActionHelper Test', () {
    test('Parse standard SSH command string', () {
      final info = LanTextActionHelper.parseSshString('ssh root@192.168.1.100');
      expect(info, isNotNull);
      expect(info!.user, equals('root'));
      expect(info.host, equals('192.168.1.100'));
      expect(info.port, equals(22));
    });

    test('Parse SSH command string with port -p', () {
      final info = LanTextActionHelper.parseSshString(
        'ssh -p 2222 admin@myserver.com',
      );
      expect(info, isNotNull);
      expect(info!.user, equals('admin'));
      expect(info.host, equals('myserver.com'));
      expect(info.port, equals(2222));
    });

    test('Parse simple user@host', () {
      final info = LanTextActionHelper.parseSshString('deploy@10.0.0.1');
      expect(info, isNotNull);
      expect(info!.user, equals('deploy'));
      expect(info.host, equals('10.0.0.1'));
      expect(info.port, equals(22));
    });

    test('Parse URL and IP', () {
      expect(
        LanTextActionHelper.parseUrl('Check out https://github.com/flutter'),
        equals('https://github.com/flutter'),
      );
      expect(
        LanTextActionHelper.parseIp('Server IP is 192.168.1.5'),
        equals('192.168.1.5'),
      );
    });
  });
}
