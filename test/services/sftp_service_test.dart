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
}
