import 'package:app_core/app_core.dart';
import 'package:feature_monitoring/feature_monitoring.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
