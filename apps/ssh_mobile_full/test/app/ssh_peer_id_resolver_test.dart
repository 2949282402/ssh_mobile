// SSH/SFTP native peer 解析器单元测试：验证 ConnectionConfig → peer_id 映射，
// 以及 SshService 的 native ReliableStream 传输接线（resolver 非空）。

import 'dart:async';
import 'dart:typed_data';

import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile/app/ssh_native_stream_adapters.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/terminal_session_metadata_store.dart';

void main() {
  group('resolveSshNativePeerId', () {
    ConnectionConfig config({String host = '192.168.1.5', int port = 22}) {
      return ConnectionConfig(
        id: 'conn-1',
        name: 'server',
        host: host,
        port: port,
        username: 'root',
      );
    }

    test('returns peer_id when host:port is enrolled', () {
      final peerId = resolveSshNativePeerId(
        config(),
        enrolledPeerEndpoints: const {'192.168.1.5:22': 'device-a'},
      );
      expect(peerId, 'device-a');
    });

    test('matches by bare host when the host:port key is absent', () {
      final peerId = resolveSshNativePeerId(
        config(),
        enrolledPeerEndpoints: const {'192.168.1.5': 'device-a'},
      );
      expect(peerId, 'device-a');
    });

    test('host:port match wins over bare host', () {
      final peerId = resolveSshNativePeerId(
        config(),
        enrolledPeerEndpoints: const {
          '192.168.1.5:22': 'device-a',
          '192.168.1.5': 'device-any',
        },
      );
      expect(peerId, 'device-a');
    });

    test('returns null for an unresolvable config (raw-TCP fallback)', () {
      final peerId = resolveSshNativePeerId(
        config(host: '10.0.0.9'),
        enrolledPeerEndpoints: const {'192.168.1.5:22': 'device-a'},
      );
      expect(peerId, isNull);
    });

    test('returns null when no peers are enrolled', () {
      final peerId = resolveSshNativePeerId(
        config(),
        enrolledPeerEndpoints: const <String, String>{},
      );
      expect(peerId, isNull);
    });
  });

  group('SshService native transport wiring', () {
    test('canUseNativeTransport requires both connector and resolver', () {
      final connector = AppSshNativeStreamConnector(
        gatewayProvider: () async => _FakeGateway(),
      );
      final service = SshService(
        connectionRepository: _EmptyConnectionRepository(),
        credentialRepository: _EmptyCredentialRepository(),
        hostKeyRepository: _EmptyHostKeyRepository(),
        terminalMetadataStore: TerminalSessionMetadataStore(),
        nativeStreamConnector: connector,
        peerIdResolver: (_) => 'device-a',
      );
      expect(service.canUseNativeTransport, isTrue);

      final withoutResolver = SshService(
        connectionRepository: _EmptyConnectionRepository(),
        credentialRepository: _EmptyCredentialRepository(),
        hostKeyRepository: _EmptyHostKeyRepository(),
        terminalMetadataStore: TerminalSessionMetadataStore(),
        nativeStreamConnector: connector,
      );
      expect(withoutResolver.canUseNativeTransport, isFalse);
    });
  });
}

/// 只提交命令、不产生任何事件的假 gateway。
final class _FakeGateway implements NetworkCommandGateway {
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get events => _events.stream;

  @override
  TransportOperationStatus sendCommand(Uint8List command) {
    return TransportOperationStatus.success;
  }
}

final class _EmptyConnectionRepository implements ConnectionRepository {
  @override
  List<ConnectionConfig> get connections => const <ConnectionConfig>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<List<ConnectionConfig>> loadConnections() async =>
      const <ConnectionConfig>[];

  @override
  Future<void> addConnection(ConnectionConfig config) async {}

  @override
  Future<void> updateConnection(ConnectionConfig config) async {}

  @override
  Future<void> deleteConnection(String id) async {}

  @override
  Future<void> deleteConnections(List<String> ids) async {}

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {}

  @override
  ConnectionConfig? getConnection(String id) => null;
}

final class _EmptyCredentialRepository implements CredentialRepository {
  @override
  Future<String?> getPassword(String connectionId) async => null;

  @override
  Future<String?> getPrivateKey(String connectionId) async => null;

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) async {}

  @override
  Future<void> deleteCredentials(String connectionId) async {}
}

final class _EmptyHostKeyRepository implements HostKeyRepository {
  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) async {}
}
