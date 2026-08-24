import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:ssh_core/ssh_core.dart';
import 'package:xterm/xterm.dart';

import '../../../fakes/terminal_test_fakes.dart';

void main() {
  late FakeTerminalCapability terminal;
  late FakeSshSessionManager sshManager;

  setUp(() {
    terminal = FakeTerminalCapability();
    sshManager = FakeSshSessionManager(terminal);
  });

  tearDown(() => terminal.close());

  group('TerminalSessionViewModel Tests', () {
    test('Initialization values check', () {
      final viewModel = TerminalSessionViewModel(
        sshSessionManager: sshManager,
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
        sshSessionManager: sshManager,
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
        sshSessionManager: sshManager,
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
        sshSessionManager: sshManager,
        sessionId: 'session_123',
        connectionId: 'conn_123',
      );
      addTearDown(viewModel.dispose);
      viewModel.terminal.write('\x1b[?2004h');
      viewModel.commandInputController.text =
          'printf "first"\r\nprintf "second"';

      expect(viewModel.submitCommandInput(), isTrue);

      expect(terminal.sentData, [
        '\x1b[200~printf "first"\nprintf "second"\x1b[201~',
        '\r',
      ]);
      expect(viewModel.commandInputController.text, isEmpty);
    });

    test('recalls sent commands and restores the unsent draft', () {
      final viewModel = TerminalSessionViewModel(
        sshSessionManager: sshManager,
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
        sshSessionManager: sshManager,
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
        sshSessionManager: sshManager,
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

      expect(terminal.sentData, ['\x1b[Z']);
    });

    test('sends Ctrl and Alt character combinations', () {
      final viewModel = TerminalSessionViewModel(
        sshSessionManager: sshManager,
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

      expect(terminal.sentData, ['\x01', '\x1bb']);
    });

    test(
      'bounds live output retained while history loading is delayed',
      () async {
        final output = StreamController<String>.broadcast(sync: true);
        final history = Completer<String>();
        terminal = FakeTerminalCapability(
          sessions: <SshTerminalSession>[
            SshTerminalSession(
              id: 'session_123',
              connectionId: 'conn_123',
              connectionName: 'server',
              displayName: 'window',
              tmuxSessionName: null,
              tmuxAutoDeleteSeconds: null,
              fontSize: 13,
              state: SshConnectionState.connected,
              errorMessage: null,
              createdAt: DateTime(2026),
              updatedAt: DateTime(2026),
              output: output.stream,
              outputText: '',
              estimatedMemoryBytes: 0,
            ),
          ],
        )..historyLoader = (_) => history.future;
        sshManager = FakeSshSessionManager(terminal);
        final viewModel = TerminalSessionViewModel(
          sshSessionManager: sshManager,
          sessionId: 'session_123',
          connectionId: 'conn_123',
        );
        addTearDown(viewModel.dispose);
        addTearDown(output.close);
        await Future<void>.delayed(Duration.zero);

        output.add('begin-${_repeat('x', 240000)}-end\r\n');
        history.complete('');
        await Future<void>.delayed(const Duration(milliseconds: 250));

        final rendered = viewModel.terminal.buffer.getText();
        expect(rendered, isNot(contains('begin-')));
        expect(rendered, contains('-end'));
      },
    );

    test('redacts sensitive asynchronous stream errors', () async {
      final output = StreamController<String>.broadcast(sync: true);
      terminal = FakeTerminalCapability(
        sessions: <SshTerminalSession>[
          SshTerminalSession(
            id: 'session_123',
            connectionId: 'conn_123',
            connectionName: 'server',
            displayName: 'window',
            tmuxSessionName: null,
            tmuxAutoDeleteSeconds: null,
            fontSize: 13,
            state: SshConnectionState.connected,
            errorMessage: null,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
            output: output.stream,
            outputText: 'ready',
            estimatedMemoryBytes: 0,
          ),
        ],
      );
      sshManager = FakeSshSessionManager(terminal);
      final viewModel = TerminalSessionViewModel(
        sshSessionManager: sshManager,
        sessionId: 'session_123',
        connectionId: 'conn_123',
      );
      addTearDown(viewModel.dispose);
      addTearDown(output.close);
      await Future<void>.delayed(Duration.zero);

      output.addError(StateError('password=hunter2'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final rendered = viewModel.terminal.buffer.getText();
      expect(rendered, contains('password=[REDACTED]'));
      expect(rendered, isNot(contains('hunter2')));
    });
  });
}

String _repeat(String value, int count) =>
    List<String>.filled(count, value, growable: false).join();
