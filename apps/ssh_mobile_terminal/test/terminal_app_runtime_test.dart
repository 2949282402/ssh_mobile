import 'package:app_core/app_core.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_core/ssh_core.dart';

import 'package:ssh_mobile_terminal/app/terminal_app_ports.dart';
import 'package:ssh_mobile_terminal/app/terminal_app_runtime.dart';
import 'package:ssh_mobile_terminal/app/terminal_only_capability.dart';

void main() {
  test('Terminal-only Runtime releases every injected Owner once', () async {
    final logger = AppLoggerImpl();
    final network = _FakeNetworkRuntime();
    final capability = TerminalOnlyCapability();
    final manager = _FakeSshSessionManager(capability);
    final settings = TerminalOnlySettings();
    final shortcuts = TerminalOnlyShortcuts();
    final module = TerminalModule();
    final connections = TerminalOnlyConnections(terminal: capability);
    final terminalLogger = TerminalOnlyLogger(logger);
    final runtime = TerminalAppRuntime.forTesting(
      logger: logger,
      networkRuntime: network,
      sshSessionManager: manager,
      terminalCapability: capability,
      terminalModule: module,
      settings: settings,
      shortcuts: shortcuts,
      connections: connections,
      terminalLogger: terminalLogger,
    );

    final firstDispose = runtime.dispose();
    final secondDispose = runtime.dispose();

    expect(identical(firstDispose, secondDispose), isTrue);
    await firstDispose;
    expect(manager.closeCount, 1);
    expect(network.disposeCount, 1);
    expect(logger.isDisposed, isTrue);
    await capability.close();
  });

  test('Terminal-only Capability never creates a session', () async {
    final capability = TerminalOnlyCapability();

    expect(capability.sessions, isEmpty);
    expect(await capability.openSession('connection-id'), isNull);
    expect(await capability.ensureConnected('connection-id'), isFalse);
    expect(capability.errorMessage, isNotEmpty);

    await capability.close();
  });
}

final class _FakeNetworkRuntime implements NetworkRuntime {
  int disposeCount = 0;

  @override
  NetworkRuntimeState get state => NetworkRuntimeState.idle;

  @override
  Future<void> ensureCapability(NetworkCapability capability) async {}

  @override
  bool isCapabilityReady(NetworkCapability capability) => false;

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

final class _FakeSshSessionManager implements SshSessionManager {
  _FakeSshSessionManager(this.terminalCapability);

  @override
  final SshTerminalCapability terminalCapability;

  int closeCount = 0;

  @override
  bool get initialized => true;

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<SshSessionLease> acquire({
    required String sessionId,
    required Future<SshSession> Function() create,
  }) {
    throw UnsupportedError('This lifecycle test does not acquire a lease.');
  }

  @override
  Future<void> close() async {
    closeCount++;
  }
}
