import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  late StorageService storage;
  late SftpService sftp;

  setUp(() {
    storage = StorageService();
    sftp = SftpService(storage);
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
  name: 'config.txt',
  path: '/etc/config.txt',
  lowerName: 'config.txt',
  isDirectory: false,
  isLink: false,
  sizeLabel: '6 B',
);
