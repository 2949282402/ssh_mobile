import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/client_health_advisor.dart';
import 'package:ssh_mobile/services/client_system_tool_service.dart';

void main() {
  group('ClientHealthAdvisor', () {
    test('returns ok when client runtime is healthy', () async {
      final advisor = ClientHealthAdvisor(
        clientSystemToolService: _FakeClientSystem(),
      );

      final report = await advisor.check(
        profile: ClientHealthCheckProfile.agentExecution,
      );

      expect(report.status, ClientRuntimeHealthStatus.ok);
      expect(report.issues, isEmpty);
      expect(report.canProceed, isTrue);
    });

    test('blocks when network is disconnected', () async {
      final advisor = ClientHealthAdvisor(
        clientSystemToolService: _FakeClientSystem(
          network: {'supported': true, 'connected': false},
        ),
      );

      final report = await advisor.check(
        profile: ClientHealthCheckProfile.agentExecution,
      );

      expect(report.status, ClientRuntimeHealthStatus.blocking);
      expect(
        report.issues.map((issue) => issue.code),
        contains('network_disconnected'),
      );
    });

    test('blocks when Android network is not validated', () async {
      final advisor = ClientHealthAdvisor(
        clientSystemToolService: _FakeClientSystem(
          network: {'supported': true, 'connected': true, 'validated': false},
        ),
      );

      final report = await advisor.check(
        profile: ClientHealthCheckProfile.agentExecution,
      );

      expect(report.status, ClientRuntimeHealthStatus.blocking);
      expect(
        report.issues.map((issue) => issue.code),
        contains('network_not_validated'),
      );
    });

    test('warns for low battery and power save mode', () async {
      final advisor = ClientHealthAdvisor(
        clientSystemToolService: _FakeClientSystem(
          battery: {
            'supported': true,
            'batteryPercent': 12,
            'powerSaveMode': true,
            'plugged': {'ac': false, 'usb': false, 'wireless': false},
          },
        ),
      );

      final report = await advisor.check(
        profile: ClientHealthCheckProfile.agentExecution,
      );

      expect(report.status, ClientRuntimeHealthStatus.warning);
      expect(report.canProceed, isTrue);
      expect(
        report.issues.map((issue) => issue.code),
        containsAll(['low_battery', 'power_save_mode']),
      );
    });

    test('warns when battery optimization exemption is missing', () async {
      final advisor = ClientHealthAdvisor(
        clientSystemToolService: _FakeClientSystem(
          permission: {
            'notificationGranted': true,
            'supportsNativeBackgroundService': true,
            'supportsBatteryOptimizationExemption': true,
            'ignoringBatteryOptimizations': false,
          },
        ),
      );

      final report = await advisor.check(
        profile: ClientHealthCheckProfile.agentExecution,
      );

      expect(report.status, ClientRuntimeHealthStatus.warning);
      expect(
        report.issues.map((issue) => issue.code),
        contains('battery_optimization_active'),
      );
    });

    test(
      'blocks when notification permission is denied for agent execution',
      () async {
        final advisor = ClientHealthAdvisor(
          clientSystemToolService: _FakeClientSystem(
            permission: {
              'notificationGranted': false,
              'supportsNativeBackgroundService': true,
              'supportsBatteryOptimizationExemption': true,
              'ignoringBatteryOptimizations': true,
            },
          ),
        );

        final report = await advisor.check(
          profile: ClientHealthCheckProfile.agentExecution,
        );

        expect(report.status, ClientRuntimeHealthStatus.blocking);
        expect(
          report.issues.map((issue) => issue.code),
          contains('notification_permission_denied'),
        );
      },
    );

    test(
      'serializes warning details and covers network, proxy, and thermal signals',
      () async {
        final advisor = ClientHealthAdvisor(
          clientSystemToolService: _FakeClientSystem(
            network: {
              'supported': true,
              'connected': true,
              'validated': true,
              'metered': true,
              'vpnActive': true,
              'httpProxyHost': 'proxy.example.test',
            },
            battery: {
              'supported': true,
              'batteryPercent': '9',
              'powerSaveMode': false,
              'thermalStatus': 'severe',
              'plugged': {'ac': false, 'usb': false, 'wireless': false},
            },
          ),
        );

        final report = await advisor.check(
          profile: ClientHealthCheckProfile.agentExecution,
        );
        expect(
          report.issues.map((issue) => issue.code),
          containsAll(<String>[
            'metered_network',
            'vpn_active',
            'http_proxy_active',
            'low_battery',
            'thermal_pressure',
          ]),
        );
        final issueJson = report.issues.first.toJson();
        expect(issueJson['severity'], isA<String>());
        expect(issueJson['recommendation'], isNotEmpty);
        final json = report.toJson();
        expect(json['execution'], 'client');
        expect(json['target'], 'client_device');
        expect(json['issues'], isA<List<dynamic>>());
        expect(json['recommendations'], isA<List<dynamic>>());
        expect(json['raw'], isA<Map<String, dynamic>>());
      },
    );

    test('turns client status read failures into typed warnings', () async {
      final advisor = ClientHealthAdvisor(
        clientSystemToolService: _FakeClientSystem(
          networkError: StateError('network unavailable'),
          batteryError: StateError('battery unavailable'),
          permissionError: StateError('permission unavailable'),
        ),
      );

      final report = await advisor.check(
        profile: ClientHealthCheckProfile.general,
      );
      expect(
        report.issues.map((issue) => issue.code),
        containsAll(<String>[
          'network_status_unavailable',
          'permission_status_unavailable',
        ]),
      );
      expect(report.status, ClientRuntimeHealthStatus.warning);
    });

    test(
      'blocks when the required native background service is unavailable',
      () async {
        final advisor = ClientHealthAdvisor(
          clientSystemToolService: _FakeClientSystem(
            permission: {
              'supportsNativeBackgroundService': false,
              'notificationGranted': true,
              'supportsBatteryOptimizationExemption': false,
              'ignoringBatteryOptimizations': true,
            },
          ),
        );

        final report = await advisor.check(
          profile: ClientHealthCheckProfile.background,
        );
        expect(report.status, ClientRuntimeHealthStatus.blocking);
        expect(
          report.issues.map((issue) => issue.code),
          contains('background_service_unavailable'),
        );
      },
    );
  });
}

class _FakeClientSystem implements ClientSystemToolAdapter {
  final Map<String, dynamic> network;
  final Map<String, dynamic> battery;
  final Map<String, dynamic> permission;
  final Object? networkError;
  final Object? batteryError;
  final Object? permissionError;

  _FakeClientSystem({
    Map<String, dynamic>? network,
    Map<String, dynamic>? battery,
    Map<String, dynamic>? permission,
    this.networkError,
    this.batteryError,
    this.permissionError,
  }) : network =
           network ??
           {
             'supported': true,
             'connected': true,
             'validated': true,
             'metered': false,
             'vpnActive': false,
           },
       battery =
           battery ??
           {
             'supported': true,
             'batteryPercent': 80,
             'powerSaveMode': false,
             'thermalStatus': 'none',
             'plugged': {'ac': false, 'usb': false, 'wireless': false},
           },
       permission =
           permission ??
           {
             'notificationGranted': true,
             'supportsNativeBackgroundService': true,
             'supportsBatteryOptimizationExemption': true,
             'ignoringBatteryOptimizations': true,
           };

  @override
  Map<String, dynamic> getClientTime() => const {};

  @override
  Map<String, dynamic> getClientDeviceInfo() => const {};

  @override
  Future<Map<String, dynamic>> getNetworkInfo() async {
    final error = networkError;
    if (error != null) throw error;
    return network;
  }

  @override
  Future<Map<String, dynamic>> getBatteryStatus() async {
    final error = batteryError;
    if (error != null) throw error;
    return battery;
  }

  @override
  Future<Map<String, dynamic>> getPermissionStatus() async {
    final error = permissionError;
    if (error != null) throw error;
    return permission;
  }

  @override
  Future<Map<String, dynamic>> openAppSettings() async => const {};

  @override
  Future<Map<String, dynamic>> setClipboard(String text) async => const {};

  @override
  Future<Map<String, dynamic>> setAlarm({
    String? triggerAt,
    int? delaySeconds,
    int? delayMinutes,
    String? label,
    bool useSystemAlarm = true,
  }) async => const {};

  @override
  Future<Map<String, dynamic>> listAlarms() async => const {};

  @override
  Future<Map<String, dynamic>> cancelAlarm(String alarmId) async => const {};

  @override
  Future<Map<String, dynamic>> queryLogs({
    String? level,
    String? contains,
    int limit = 50,
  }) async => const {};

  @override
  Future<Map<String, dynamic>> getLogCounts() async => const {};

  @override
  Future<Map<String, dynamic>> deleteLogEntries(List<int> ids) async =>
      const {};

  @override
  Future<Map<String, dynamic>> clearLogs() async => const {};

  @override
  Future<Map<String, dynamic>> saveBytesToFile({
    required String fileName,
    required List<int> bytes,
    String? dialogTitle,
  }) async => const {};

  @override
  Future<ClientPickedFile?> pickFile({
    List<String>? allowedExtensions,
    String? dialogTitle,
  }) async => null;
}
