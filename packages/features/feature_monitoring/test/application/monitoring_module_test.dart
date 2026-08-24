import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:feature_monitoring/feature_monitoring.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../fakes/monitoring_test_fakes.dart';

void main() {
  test('module activation does not start polling by itself', () async {
    final ssh = FakeMonitoringSshPort();
    final catalog = FakeMonitoringConnectionCatalog();
    final logger = FakeMonitoringLogger();
    final background = FakeMonitoringBackground();
    final module = MonitoringModule();

    await module.register(
      ModuleContext.fromMap({
        MonitoringSshPort: ssh,
        MonitoringConnectionCatalogPort: catalog,
        MonitoringLoggerPort: logger,
        MonitoringBackgroundPort: background,
      }),
    );
    await module.initialize();
    await module.activate();

    expect(module.state, ModuleState.active);
    expect(module.service.isRunning, isFalse);
    expect(ssh.callCount, 0);
    expect(background.startCount, 0);

    await module.deactivate();
    expect(module.state, ModuleState.inactive);
    await module.dispose();
    expect(module.state, ModuleState.disposed);
  });

  test(
    'sampling marks SSH requests low priority and can stop its timer',
    () async {
      final ssh = FakeMonitoringSshPort();
      final service = MonitoringService(
        sshPort: ssh,
        connectionCatalog: FakeMonitoringConnectionCatalog(),
        logger: FakeMonitoringLogger(),
        background: FakeMonitoringBackground(),
      );

      service.toggleSelection('server-1');
      await service.startMonitoring();

      expect(service.isRunning, isTrue);
      expect(ssh.callCount, 1);
      expect(ssh.lastPriority, MonitoringRequestPriority.low);
      expect(service.samplesFor('server-1'), hasLength(1));

      service.stopMonitoring();
      expect(service.isRunning, isFalse);
      service.dispose();
    },
  );

  test('late sample success cannot write into a restarted run', () async {
    final oldBinding = _binding('old.example.test');
    final newBinding = _binding('new.example.test');
    final ssh = _ControlledMonitoringSshPort();
    final catalog = FakeMonitoringConnectionCatalog(binding: oldBinding);
    final service = MonitoringService(
      sshPort: ssh,
      connectionCatalog: catalog,
      logger: FakeMonitoringLogger(),
    );
    addTearDown(service.dispose);
    service.toggleSelection(oldBinding.id);

    final oldStart = service.startMonitoring();
    expect(ssh.calls, hasLength(1));
    service.stopMonitoring();
    catalog.binding = newBinding;
    final newStart = service.startMonitoring();
    expect(ssh.calls, hasLength(2));

    ssh.calls[1].result.complete(_windowsResult(cpuPercent: 44));
    await newStart;
    ssh.calls[0].result.complete(_windowsResult(cpuPercent: 11));
    await oldStart;

    expect(ssh.calls.map((call) => call.binding.config.host), [
      'old.example.test',
      'new.example.test',
    ]);
    expect(service.samplesFor(oldBinding.id), hasLength(1));
    expect(service.samplesFor(oldBinding.id).single.cpuPercent, 44);
  });

  test(
    'late sample error cannot retry or publish into a restarted run',
    () async {
      final oldBinding = _binding('old.example.test');
      final newBinding = _binding('new.example.test');
      final ssh = _ControlledMonitoringSshPort();
      final logger = FakeMonitoringLogger();
      final catalog = FakeMonitoringConnectionCatalog(binding: oldBinding);
      final service = MonitoringService(
        sshPort: ssh,
        connectionCatalog: catalog,
        logger: logger,
      );
      addTearDown(service.dispose);
      service.toggleSelection(oldBinding.id);

      final oldStart = service.startMonitoring();
      service.stopMonitoring();
      catalog.binding = newBinding;
      final newStart = service.startMonitoring();
      ssh.calls[1].result.complete(_windowsResult(cpuPercent: 55));
      await newStart;

      ssh.calls[0].result.completeError(StateError('stale failure'));
      await oldStart;

      expect(ssh.calls, hasLength(2));
      expect(logger.warnings, isEmpty);
      expect(logger.errors, isEmpty);
      expect(service.errorsByConnection, isEmpty);
      expect(service.samplesFor(oldBinding.id).single.cpuPercent, 55);
    },
  );
}

ssh_core.SshTargetBinding _binding(String host) =>
    ssh_core.SshTargetBinding.fromConfig(
      ConnectionConfig(
        id: 'server-1',
        name: 'Server 1',
        host: host,
        username: 'monitor',
        serverPlatform: ServerPlatform.windows,
      ),
    );

ssh_core.RemoteCommandResult _windowsResult({required double cpuPercent}) =>
    ssh_core.RemoteCommandResult(
      exitCode: 0,
      stdout:
          '{"cpuPercent":$cpuPercent,"memoryPercent":34,'
          '"diskBytesPerSecond":5,"networkBytesPerSecond":6,'
          '"disks":[],"ports":[],"applications":[],"services":[]}',
      stderr: '',
    );

final class _ControlledMonitoringCall {
  _ControlledMonitoringCall(this.binding);

  final ssh_core.SshTargetBinding binding;
  final Completer<ssh_core.RemoteCommandResult> result = Completer();
}

final class _ControlledMonitoringSshPort implements MonitoringSshPort {
  final List<_ControlledMonitoringCall> calls = [];

  @override
  Future<ssh_core.RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    required Duration timeout,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    MonitoringRequestPriority priority = MonitoringRequestPriority.low,
  }) => Future.error(StateError('Unbound monitoring calls are forbidden.'));

  @override
  Future<ssh_core.RemoteCommandResult> runOneShotCommandForBinding({
    required ssh_core.SshTargetBinding binding,
    required String command,
    required Duration timeout,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    MonitoringRequestPriority priority = MonitoringRequestPriority.low,
  }) {
    final call = _ControlledMonitoringCall(binding);
    calls.add(call);
    return call.result.future;
  }
}
