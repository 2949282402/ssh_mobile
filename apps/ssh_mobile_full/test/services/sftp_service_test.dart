import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/app/sftp_backend_adapters.dart';
import '../test_utils/test_storage_adapter.dart';

void main() {
  late TestStorageAdapter storage;
  late SftpService sftp;

  setUp(() {
    storage = TestStorageAdapter();
    sftp = createTestSftpService(storage);
  });

  tearDown(() {
    sftp.dispose();
    storage.dispose();
  });

  test('starts disconnected with safe empty defaults', () {
    expect(sftp.connectionId, isNull);
    expect(sftp.currentPath, '.');
    expect(sftp.entries, isEmpty);
    expect(sftp.isConnected, isFalse);
    expect(sftp.isBusy, isFalse);
    expect(sftp.activeTransfer, isNull);
    expect(sftp.hasActiveTransfer, isFalse);
  });

  test('cancelActiveTransfer returns normally when no active transfer', () {
    expect(() => sftp.cancelActiveTransfer(), returnsNormally);
  });

  test('disconnectAll is safe before any connection is opened', () async {
    await sftp.disconnectAll();

    expect(sftp.connectionId, isNull);
    expect(sftp.state, SftpConnectionState.disconnected);
    expect(sftp.entriesRevision, 0);
  });

  test('missing connection config moves service to error state', () async {
    await sftp.connect('missing-connection');

    expect(sftp.state, SftpConnectionState.error);
    expect(sftp.errorMessage, 'Connection config not found');
  });

  test('connect opens a native stream when a peer binding resolves', () async {
    final storage = TestStorageAdapter();
    const connectionId = 'server-1';
    await storage.connectionRepository.addConnection(
      ConnectionConfig(
        id: connectionId,
        name: 'Server',
        host: 'peer-a',
        username: 'user',
        authMethod: AuthMethod.password,
      ),
    );
    await storage.credentialRepository.saveCredentials(
      connectionId: connectionId,
      password: 'pw',
    );
    final connector = _ThrowingSshConnector();
    final nativeSftp = SftpService(
      connectionRepository: storage.connectionRepository,
      credentialRepository: storage.credentialRepository,
      hostKeyRepository: storage.hostKeyRepository,
      nativeStreamConnector: connector,
      peerIdResolver: (config) => config.host,
    );
    addTearDown(nativeSftp.dispose);

    await nativeSftp.connect(connectionId);

    expect(connector.openedPeerIds, ['peer-a']);
    expect(nativeSftp.state, SftpConnectionState.error);
  });

  test('connect falls back to tcp when no peer binding resolves', () async {
    final storage = TestStorageAdapter();
    const connectionId = 'server-1';
    await storage.connectionRepository.addConnection(
      ConnectionConfig(
        id: connectionId,
        name: 'Server',
        host: '127.0.0.1',
        port: 1,
        username: 'user',
        authMethod: AuthMethod.password,
      ),
    );
    await storage.credentialRepository.saveCredentials(
      connectionId: connectionId,
      password: 'pw',
    );
    final connector = _ThrowingSshConnector();
    final nativeSftp = SftpService(
      connectionRepository: storage.connectionRepository,
      credentialRepository: storage.credentialRepository,
      hostKeyRepository: storage.hostKeyRepository,
      nativeStreamConnector: connector,
      // 解析器返回 null → 回退到原始 TCP，不打开 native 流。
      peerIdResolver: (_) => null,
    );
    addTearDown(nativeSftp.dispose);

    await nativeSftp.connect(connectionId);

    expect(connector.openedPeerIds, isEmpty);
    expect(nativeSftp.state, SftpConnectionState.error);
  });

  test('saving text without an active connection fails explicitly', () async {
    await sftp.connect(_textEntry.connectionId);

    await expectLater(
      sftp.saveTextFile(_textEntry, 'updated'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('SFTP is not connected'),
        ),
      ),
    );
  });

  test('text save checks UTF-8 byte size before opening remote file', () async {
    await expectLater(
      sftp.saveTextFile(_textEntry, '你好', maxBytes: 5),
      throwsA(
        isA<SftpTextSizeLimitException>()
            .having((error) => error.actualBytes, 'actualBytes', 6)
            .having((error) => error.maxBytes, 'maxBytes', 5),
      ),
    );
  });

  test('SftpTransferState models progress and copyWith and equality', () {
    const state = SftpTransferState(
      id: 'tx_123',
      name: 'test.bin',
      totalBytes: 1000,
      isUpload: true,
      bytesTransferred: 200,
    );

    expect(state.progress, 0.2);
    expect(state.isUpload, isTrue);

    final updated = state.copyWith(bytesTransferred: 500);
    expect(updated.bytesTransferred, 500);
    expect(updated.progress, 0.5);
    expect(updated.id, 'tx_123');

    final identicalState = SftpTransferState(
      id: 'tx_123',
      name: 'test.bin',
      totalBytes: 1000,
      isUpload: true,
      bytesTransferred: 200,
    );
    expect(state, identicalState);
    expect(state.hashCode, identicalState.hashCode);
  });
}

const _textEntry = SftpEntry(
  connectionId: 'missing-connection',
  targetFingerprint: 'missing-target',
  name: 'config.txt',
  path: '/etc/config.txt',
  lowerName: 'config.txt',
  isDirectory: false,
  isLink: false,
  sizeLabel: '6 B',
);

final class _ThrowingSshConnector implements ssh_core.SshNativeStreamConnector {
  final List<String> openedPeerIds = <String>[];

  @override
  Future<ssh_core.SshNativeStream> open({
    required String peerId,
    String service = ssh_core.kSshNativeStreamService,
    String? traceId,
  }) {
    openedPeerIds.add(peerId);
    throw StateError('native stream open failed');
  }

  @override
  Future<void> closeAll() async {}
}
