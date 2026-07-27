import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/lan_share/services/lan_receiver_coordinator.dart';
import 'package:ssh_mobile/features/settings/viewmodels/settings_viewmodel.dart';
import 'package:ssh_mobile/features/sftp/services/sftp_lan_relay_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_security_service.dart';
import 'package:ssh_mobile/services/relay/relay_client.dart';
import 'package:ssh_mobile/services/relay/relay_transport.dart';

void main() {
  test('relay client and transport APIs construct without network access', () {
    final security = LanSecurityService();
    final client = RelayClient(
      currentDeviceId: 'test-device',
      securityService: security,
    );
    expect(
      RelayTransport(client: client, securityService: security),
      isA<RelayTransport>(),
    );
    expect(LanReceiverCoordinator, isNotNull);
    expect(SftpLanRelayService, isNotNull);
    expect(SettingsViewModel, isNotNull);
  });
}
