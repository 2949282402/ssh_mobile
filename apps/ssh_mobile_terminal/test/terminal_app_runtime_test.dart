import 'package:app_core/app_core.dart';
import 'package:drift/native.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_core/ssh_core.dart';

import 'package:ssh_mobile_terminal/app/terminal_app_ports.dart';
import 'package:ssh_mobile_terminal/app/terminal_app.dart';
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

  test('one owner failure does not skip later Runtime cleanup', () async {
    final logger = AppLoggerImpl();
    final events = <String>[];
    final network = _FakeNetworkRuntime(events: events);
    final capability = TerminalOnlyCapability();
    final manager = _FakeSshSessionManager(
      capability,
      events: events,
      closeError: StateError('injected SSH close failure'),
    );
    final settings = TerminalOnlySettings();
    final shortcuts = TerminalOnlyShortcuts();
    final module = TerminalModule();
    final runtime = TerminalAppRuntime.forTesting(
      logger: logger,
      networkRuntime: network,
      sshSessionManager: manager,
      terminalCapability: capability,
      terminalModule: module,
      settings: settings,
      shortcuts: shortcuts,
      connections: TerminalOnlyConnections(terminal: capability),
      terminalLogger: TerminalOnlyLogger(logger),
    );

    await expectLater(runtime.dispose(), throwsA(isA<StateError>()));

    expect(events, <String>['ssh.close', 'network.dispose']);
    expect(network.disposeCount, 1);
    expect(logger.isDisposed, isTrue);
  });

  testWidgets('Terminal App Widget owner exposes an idempotent exit barrier', (
    tester,
  ) async {
    final logger = AppLoggerImpl();
    final network = _FakeNetworkRuntime();
    final capability = TerminalOnlyCapability();
    final manager = _FakeSshSessionManager(capability);
    final module = TerminalModule(
      databaseFactory: () =>
          TerminalDatabase.forTesting(NativeDatabase.memory()),
    );
    await module.register(ModuleContext.fromMap({SshSessionManager: manager}));
    await module.initialize();
    await module.activate();
    final settings = TerminalOnlySettings();
    final shortcuts = TerminalOnlyShortcuts();
    final runtime = TerminalAppRuntime.forTesting(
      logger: logger,
      networkRuntime: network,
      sshSessionManager: manager,
      terminalCapability: capability,
      terminalModule: module,
      settings: settings,
      shortcuts: shortcuts,
      connections: TerminalOnlyConnections(terminal: capability),
      terminalLogger: TerminalOnlyLogger(logger),
    );
    final key = GlobalKey<TerminalOnlyAppState>();

    await tester.pumpWidget(TerminalOnlyApp(key: key, runtime: runtime));
    final first = key.currentState!.shutdown();
    final second = key.currentState!.shutdown();

    expect(identical(first, second), isTrue);
    await tester.pump();
    await first;
    expect(runtime.isDisposed, isTrue);
    expect(manager.closeCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
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
  _FakeNetworkRuntime({this.events});

  final List<String>? events;
  int disposeCount = 0;

  @override
  NetworkRuntimeState get state => NetworkRuntimeState.idle;

  @override
  NetworkRuntimeDiagnostics get diagnostics => NetworkRuntimeDiagnostics(
    state: state,
    activeConnections: 0,
    nativeHandles: 0,
    readyCapabilities: const <NetworkCapability>[],
  );

  @override
  Future<void> ensureCapability(NetworkCapability capability) async {}

  @override
  Future<NetworkCommandGateway> openCommandGateway() async =>
      throw UnsupportedError('fake runtime has no command gateway');

  @override
  Future<NetworkRealtimeGateway> openRealtimeGateway() async =>
      throw UnsupportedError('fake runtime has no realtime gateway');

  @override
  bool isCapabilityReady(NetworkCapability capability) => false;

  @override
  Future<void> dispose() async {
    events?.add('network.dispose');
    disposeCount++;
  }
}

final class _FakeSshSessionManager implements SshSessionManager {
  _FakeSshSessionManager(
    this.terminalCapability, {
    this.events,
    this.closeError,
  });

  @override
  final SshTerminalCapability terminalCapability;

  int closeCount = 0;
  final List<String>? events;
  final Object? closeError;

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
    events?.add('ssh.close');
    closeCount++;
    final error = closeError;
    if (error != null) throw error;
  }
}
