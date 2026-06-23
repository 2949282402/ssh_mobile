import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/performance/viewmodels/performance_viewmodel.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;
  late SshService sshService;
  late PerformanceMonitorService monitorService;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = StorageService();
    await storageService.init();

    sshService = SshService(storageService);
    monitorService = PerformanceMonitorService(sshService, storageService);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    storageService.dispose();
  });

  group('PerformanceMonitorViewModel Tests', () {
    test('Initialization values', () {
      final viewModel =
          PerformanceMonitorViewModel(monitorService: monitorService);

      expect(viewModel.activeTabIndex, equals(0));
      expect(viewModel.serversCollapsed, isFalse);
      expect(viewModel.activeConnectionId, isNull);
      expect(viewModel.isRunning, isFalse);
      expect(viewModel.isSampling, isFalse);
      expect(viewModel.selectedConnectionIds, isEmpty);
      expect(viewModel.monitoringConnectionIds, isEmpty);
    });

    test('TabIndex, serversCollapsed, and activeConnection state modifications',
        () {
      final viewModel =
          PerformanceMonitorViewModel(monitorService: monitorService);

      bool notified = false;
      viewModel.addListener(() {
        notified = true;
      });

      viewModel.setTabIndex(2);
      expect(viewModel.activeTabIndex, equals(2));
      expect(notified, isTrue);

      notified = false;
      viewModel.setServersCollapsed(true);
      expect(viewModel.serversCollapsed, isTrue);
      expect(notified, isTrue);

      notified = false;
      viewModel.setActiveConnection('conn_123');
      expect(viewModel.activeConnectionId, equals('conn_123'));
      expect(notified, isTrue);
    });

    test('startMonitoring and stopMonitoring calls correctly', () {
      final viewModel =
          PerformanceMonitorViewModel(monitorService: monitorService);

      expect(viewModel.isRunning, isFalse);
      viewModel.stopMonitoring();
      expect(viewModel.isRunning, isFalse);
    });
  });

  group('ServerHealthSnapshot Tests', () {
    test('equality compares value fields and details', () {
      final updatedAt = DateTime(2026, 6, 21, 10, 30);
      final first = ServerHealthSnapshot(
        connectionId: 'server-1',
        level: ServerHealthLevel.warning,
        score: 72,
        summary: 'Warning',
        details: const ['CPU 86.0%'],
        updatedAt: updatedAt,
        maxDiskUsedPercent: 42.5,
      );
      final second = ServerHealthSnapshot(
        connectionId: 'server-1',
        level: ServerHealthLevel.warning,
        score: 72,
        summary: 'Warning',
        details: const ['CPU 86.0%'],
        updatedAt: updatedAt,
        maxDiskUsedPercent: 42.5,
      );
      final changedDetails = ServerHealthSnapshot(
        connectionId: 'server-1',
        level: ServerHealthLevel.warning,
        score: 72,
        summary: 'Warning',
        details: const ['Memory 86.0%'],
        updatedAt: updatedAt,
        maxDiskUsedPercent: 42.5,
      );

      expect(first, equals(second));
      expect(first.hashCode, equals(second.hashCode));
      expect(first, isNot(equals(changedDetails)));
    });
  });
}
