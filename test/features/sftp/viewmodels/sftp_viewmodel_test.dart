import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/sftp/viewmodels/sftp_viewmodel.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;
  late SftpService sftpService;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = StorageService();
    await storageService.init();

    sftpService = SftpService(storageService);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    storageService.dispose();
  });

  group('SftpViewModel Tests', () {
    test('Initialization values', () {
      final viewModel = SftpViewModel(sftpService: sftpService);

      expect(viewModel.connectionId, isNull);
      expect(viewModel.currentPath, equals('.'));
      expect(viewModel.state, equals(SftpConnectionState.disconnected));
      expect(viewModel.entries, isEmpty);
      expect(viewModel.isConnected, isFalse);
      expect(viewModel.isBusy, isFalse);
      expect(viewModel.activeTransfer, isNull);
      expect(viewModel.hasActiveTransfer, isFalse);
    });

    test('isConnectionBusy and isConnectionOpen basic values', () {
      final viewModel = SftpViewModel(sftpService: sftpService);
      expect(viewModel.isConnectionBusy('conn_1'), isFalse);
      expect(viewModel.isConnectionOpen('conn_1'), isFalse);
    });

    test('disconnect and refresh methods call without throw', () {
      final viewModel = SftpViewModel(sftpService: sftpService);
      expect(() => viewModel.disconnect(), returnsNormally);
      expect(() => viewModel.refresh(), returnsNormally);
    });

    test('cancelActiveTransfer calls service without throw', () {
      final viewModel = SftpViewModel(sftpService: sftpService);
      expect(() => viewModel.cancelActiveTransfer(), returnsNormally);
    });
  });
}
