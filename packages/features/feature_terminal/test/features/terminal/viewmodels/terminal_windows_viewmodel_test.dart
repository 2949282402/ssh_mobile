import 'package:flutter_test/flutter_test.dart';
import 'package:feature_terminal/feature_terminal.dart';

import '../../../fakes/terminal_test_fakes.dart';

void main() {
  late FakeTerminalCapability terminal;
  late FakeSshSessionManager sshManager;
  late FakeTerminalSettings settings;

  setUp(() {
    terminal = FakeTerminalCapability();
    sshManager = FakeSshSessionManager(terminal);
    settings = FakeTerminalSettings(language: 'en');
  });

  tearDown(() async {
    settings.dispose();
    await terminal.close();
  });

  group('TerminalWindowsViewModel Tests', () {
    test('Initialization defaults checks', () {
      final viewModel = TerminalWindowsViewModel(
        sshSessionManager: sshManager,
        settings: settings,
      );

      expect(viewModel.sessions, isEmpty);
      expect(viewModel.selectedSessionIds, isEmpty);
      expect(viewModel.selectionMode, isFalse);
    });

    test('Toggling custom selections updates selectionMode', () {
      final viewModel = TerminalWindowsViewModel(
        sshSessionManager: sshManager,
        settings: settings,
      );

      viewModel.toggleSelection('session_1');
      expect(viewModel.selectedSessionIds, contains('session_1'));
      expect(viewModel.selectionMode, isTrue);

      viewModel.toggleSelection('session_1');
      expect(viewModel.selectedSessionIds, isEmpty);
      expect(viewModel.selectionMode, isFalse);
    });
  });
}
