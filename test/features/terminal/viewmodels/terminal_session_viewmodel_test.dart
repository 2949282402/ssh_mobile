import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/terminal/viewmodels/terminal_session_viewmodel.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;
  late SshService sshService;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = StorageService();
    await storageService.init();

    sshService = SshService(storageService);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    storageService.dispose();
  });

  group('TerminalSessionViewModel Tests', () {
    test('Initialization values check', () {
      final viewModel = TerminalSessionViewModel(
        sshService: sshService,
        sessionId: 'session_123',
        connectionId: 'conn_123',
      );

      expect(viewModel.ctrlActive, isFalse);
      expect(viewModel.altActive, isFalse);
      expect(viewModel.reconnectInProgress, isFalse);
      expect(viewModel.isConnected, isFalse);
      expect(viewModel.terminal, isNotNull);
      expect(viewModel.terminalController, isNotNull);
    });

    test('Toggling Ctrl and Alt state modifiers', () {
      final viewModel = TerminalSessionViewModel(
        sshService: sshService,
        sessionId: 'session_123',
        connectionId: 'conn_123',
      );

      viewModel.toggleCtrl();
      expect(viewModel.ctrlActive, isTrue);

      viewModel.toggleAlt();
      expect(viewModel.altActive, isTrue);

      viewModel.setCtrlActive(false);
      expect(viewModel.ctrlActive, isFalse);
    });

    test('Changing and clamping Font Size', () {
      final viewModel = TerminalSessionViewModel(
        sshService: sshService,
        sessionId: 'session_123',
        connectionId: 'conn_123',
      );

      viewModel.setFontSize(15.0);
      expect(viewModel.fontSize, equals(15.0));

      viewModel.setFontSize(3.0); // min is 4.0
      expect(viewModel.fontSize, equals(4.0));

      viewModel.setFontSize(32.0); // max is 28.0
      expect(viewModel.fontSize, equals(28.0));
    });
  });
}
