import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/terminal/models/terminal_keyboard_models.dart';
import 'package:ssh_mobile/features/terminal/viewmodels/terminal_session_viewmodel.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;
  late _RecordingSshService sshService;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = StorageService();
    await storageService.init();

    sshService = _RecordingSshService(storageService);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    sshService.dispose();
    await storageService.shutdown();
    storageService.dispose();
  });

  group('TerminalSessionViewModel Tests', () {
    test('Initialization values check', () {
      final viewModel = TerminalSessionViewModel(
        sshService: sshService,
        sessionId: 'session_123',
        connectionId: 'conn_123',
      );
      addTearDown(viewModel.dispose);

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
      addTearDown(viewModel.dispose);

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
      addTearDown(viewModel.dispose);

      viewModel.setFontSize(15.0);
      expect(viewModel.fontSize, equals(15.0));

      viewModel.setFontSize(3.0); // min is 4.0
      expect(viewModel.fontSize, equals(4.0));

      viewModel.setFontSize(32.0); // max is 28.0
      expect(viewModel.fontSize, equals(28.0));
    });

    test('submits multiline drafts through terminal paste and Enter', () {
      final viewModel = TerminalSessionViewModel(
        sshService: sshService,
        sessionId: 'session_123',
        connectionId: 'conn_123',
      );
      addTearDown(viewModel.dispose);
      viewModel.terminal.write('\x1b[?2004h');
      viewModel.commandInputController.text =
          'printf "first"\r\nprintf "second"';

      expect(viewModel.submitCommandInput(), isTrue);

      expect(sshService.sentData, [
        '\x1b[200~printf "first"\nprintf "second"\x1b[201~',
        '\r',
      ]);
      expect(viewModel.commandInputController.text, isEmpty);
    });

    test('recalls sent commands and restores the unsent draft', () {
      final viewModel = TerminalSessionViewModel(
        sshService: sshService,
        sessionId: 'session_123',
        connectionId: 'conn_123',
      );
      addTearDown(viewModel.dispose);

      viewModel.submitCommandText('git status');
      viewModel.submitCommandText('flutter test');
      viewModel.commandInputController.text = 'unfinished draft';

      expect(viewModel.showPreviousCommandInput(), isTrue);
      expect(viewModel.commandInputController.text, 'flutter test');
      expect(viewModel.showPreviousCommandInput(), isTrue);
      expect(viewModel.commandInputController.text, 'git status');
      expect(viewModel.showNextCommandInput(), isTrue);
      expect(viewModel.commandInputController.text, 'flutter test');
      expect(viewModel.showNextCommandInput(), isTrue);
      expect(viewModel.commandInputController.text, 'unfinished draft');
    });

    test('inserts command text at the current selection', () {
      final viewModel = TerminalSessionViewModel(
        sshService: sshService,
        sessionId: 'session_123',
        connectionId: 'conn_123',
      );
      addTearDown(viewModel.dispose);
      viewModel.commandInputController.value = const TextEditingValue(
        text: 'echo value',
        selection: TextSelection(baseOffset: 5, extentOffset: 10),
      );

      viewModel.insertCommandInputText(r'$HOME');

      expect(viewModel.commandInputController.text, r'echo $HOME');
      expect(viewModel.commandInputController.selection.baseOffset, 10);
    });

    test('sends Shift+Tab through xterm key encoding', () {
      final viewModel = TerminalSessionViewModel(
        sshService: sshService,
        sessionId: 'session_123',
        connectionId: 'conn_123',
      );
      addTearDown(viewModel.dispose);

      expect(
        viewModel.sendTerminalKeyboardStroke(
          const TerminalKeyboardStroke(key: TerminalKey.tab, shift: true),
        ),
        isTrue,
      );

      expect(sshService.sentData, ['\x1b[Z']);
    });

    test('sends Ctrl and Alt character combinations', () {
      final viewModel = TerminalSessionViewModel(
        sshService: sshService,
        sessionId: 'session_123',
        connectionId: 'conn_123',
      );
      addTearDown(viewModel.dispose);

      viewModel.sendTerminalKeyboardStroke(
        const TerminalKeyboardStroke(text: 'a', ctrl: true),
      );
      viewModel.sendTerminalKeyboardStroke(
        const TerminalKeyboardStroke(text: 'b', alt: true),
      );

      expect(sshService.sentData, ['\x01', '\x1bb']);
    });
  });
}

class _RecordingSshService extends SshService {
  _RecordingSshService(super.storageService);

  final List<String> sentData = <String>[];

  @override
  void sendData(String sessionId, String data) {
    sentData.add(data);
  }
}
