import 'package:feature_monitoring/feature_monitoring.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/monitoring_test_fakes.dart';

void main() {
  test(
    'MonitoringViewModel exposes route state without owning the service',
    () async {
      final service = MonitoringService(
        sshPort: FakeMonitoringSshPort(),
        connectionCatalog: FakeMonitoringConnectionCatalog(),
        logger: FakeMonitoringLogger(),
        background: FakeMonitoringBackground(),
      );
      final viewModel = MonitoringViewModel(service);

      expect(viewModel.activeTabIndex, 0);
      expect(viewModel.serversCollapsed, isFalse);
      expect(viewModel.activeConnectionId, isNull);
      expect(viewModel.isRunning, isFalse);
      expect(viewModel.selectedConnectionIds, isEmpty);

      var notified = false;
      viewModel.addListener(() => notified = true);
      viewModel.setTabIndex(2);
      viewModel.setServersCollapsed(true);
      viewModel.setActiveConnection('server-1');

      expect(viewModel.activeTabIndex, 2);
      expect(viewModel.serversCollapsed, isTrue);
      expect(viewModel.activeConnectionId, 'server-1');
      expect(notified, isTrue);

      viewModel.dispose();
      service.dispose();
    },
  );
}
