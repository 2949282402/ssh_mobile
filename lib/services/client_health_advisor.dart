import 'client_system_tool_service.dart';
import 'tool_secret_policy.dart';

enum ClientRuntimeHealthStatus {
  ok,
  warning,
  blocking,
}

enum ClientHealthCheckProfile {
  general,
  agentExecution,
  background,
}

class ClientHealthCheckOptions {
  final bool requireNetwork;
  final bool requireBackgroundService;
  final bool requireNotifications;
  final bool longRunning;

  const ClientHealthCheckOptions({
    this.requireNetwork = true,
    this.requireBackgroundService = false,
    this.requireNotifications = false,
    this.longRunning = false,
  });

  factory ClientHealthCheckOptions.forProfile(
    ClientHealthCheckProfile profile,
  ) {
    switch (profile) {
      case ClientHealthCheckProfile.general:
        return const ClientHealthCheckOptions();
      case ClientHealthCheckProfile.agentExecution:
        return const ClientHealthCheckOptions(
          requireNetwork: true,
          requireBackgroundService: true,
          requireNotifications: true,
          longRunning: true,
        );
      case ClientHealthCheckProfile.background:
        return const ClientHealthCheckOptions(
          requireNetwork: true,
          requireBackgroundService: true,
          requireNotifications: true,
          longRunning: true,
        );
    }
  }
}

class ClientRuntimeHealthIssue {
  final String code;
  final ClientRuntimeHealthStatus severity;
  final String title;
  final String detail;
  final String recommendation;

  const ClientRuntimeHealthIssue({
    required this.code,
    required this.severity,
    required this.title,
    required this.detail,
    required this.recommendation,
  });

  Map<String, dynamic> toJson() {
    return {
      'code': code,
      'severity': severity.name,
      'title': title,
      'detail': detail,
      'recommendation': recommendation,
    };
  }
}

class ClientRuntimeHealthReport {
  final ClientRuntimeHealthStatus status;
  final List<ClientRuntimeHealthIssue> issues;
  final Map<String, dynamic> raw;

  const ClientRuntimeHealthReport({
    required this.status,
    required this.issues,
    required this.raw,
  });

  bool get canProceed => status != ClientRuntimeHealthStatus.blocking;

  List<String> get recommendations {
    final seen = <String>{};
    return [
      for (final issue in issues)
        if (seen.add(issue.recommendation)) issue.recommendation,
    ];
  }

  Map<String, dynamic> toJson() {
    return {
      'execution': 'client',
      'target': 'client_device',
      'status': status.name,
      'canProceed': canProceed,
      'issues': issues.map((issue) => issue.toJson()).toList(),
      'recommendations': recommendations,
      'raw': raw,
    };
  }
}

abstract interface class ClientHealthAdvisorAdapter {
  Future<ClientRuntimeHealthReport> check({
    ClientHealthCheckProfile profile,
  });
}

class ClientHealthAdvisor implements ClientHealthAdvisorAdapter {
  final ClientSystemToolAdapter clientSystemToolService;
  final ToolSecretPolicy secretPolicy;

  const ClientHealthAdvisor({
    required this.clientSystemToolService,
    this.secretPolicy = const ToolSecretPolicy(),
  });

  @override
  Future<ClientRuntimeHealthReport> check({
    ClientHealthCheckProfile profile = ClientHealthCheckProfile.general,
  }) async {
    final options = ClientHealthCheckOptions.forProfile(profile);
    final results = await Future.wait<Map<String, dynamic>>([
      _guard('permission', clientSystemToolService.getPermissionStatus),
      _guard('network', clientSystemToolService.getNetworkInfo),
      _guard('battery', clientSystemToolService.getBatteryStatus),
    ]);
    final permission = results[0];
    final network = results[1];
    final battery = results[2];

    final issues = <ClientRuntimeHealthIssue>[];
    _checkNetwork(issues, network, options);
    _checkPermission(issues, permission, options);
    _checkBattery(issues, battery, options);

    final status = issues.any(
      (issue) => issue.severity == ClientRuntimeHealthStatus.blocking,
    )
        ? ClientRuntimeHealthStatus.blocking
        : issues.isNotEmpty
            ? ClientRuntimeHealthStatus.warning
            : ClientRuntimeHealthStatus.ok;

    final raw = secretPolicy.redactValue(
      {
        'profile': profile.name,
        'permission': permission,
        'network': network,
        'battery': battery,
      },
      truncateLongStrings: true,
      maxChars: 300,
    );

    return ClientRuntimeHealthReport(
      status: status,
      issues: issues,
      raw: raw is Map<String, dynamic> ? raw : <String, dynamic>{},
    );
  }

  Future<Map<String, dynamic>> _guard(
    String source,
    Future<Map<String, dynamic>> Function() load,
  ) async {
    try {
      return await load();
    } catch (e) {
      return {
        'supported': true,
        'error': e.toString(),
        'source': source,
      };
    }
  }

  void _checkNetwork(
    List<ClientRuntimeHealthIssue> issues,
    Map<String, dynamic> network,
    ClientHealthCheckOptions options,
  ) {
    if (!options.requireNetwork) return;
    if (network['supported'] == false) return;
    if (network['error'] != null) {
      issues.add(const ClientRuntimeHealthIssue(
        code: 'network_status_unavailable',
        severity: ClientRuntimeHealthStatus.warning,
        title: 'Network status unavailable',
        detail: 'The client network state could not be read.',
        recommendation:
            'Verify the device network manually before starting long agent work.',
      ));
      return;
    }

    final connected = network['connected'];
    if (connected == false) {
      issues.add(const ClientRuntimeHealthIssue(
        code: 'network_disconnected',
        severity: ClientRuntimeHealthStatus.blocking,
        title: 'No client network connection',
        detail: 'The Android device is not connected to an active network.',
        recommendation:
            'Connect the device to a stable network before executing the plan.',
      ));
      return;
    }

    final validated = network['validated'];
    if (connected == true && validated == false) {
      issues.add(const ClientRuntimeHealthIssue(
        code: 'network_not_validated',
        severity: ClientRuntimeHealthStatus.blocking,
        title: 'Network has no validated internet access',
        detail:
            'Android reports the active network is connected but not validated.',
        recommendation:
            'Switch networks or sign in to the captive portal before running remote tools.',
      ));
    }

    if (network['metered'] == true) {
      issues.add(const ClientRuntimeHealthIssue(
        code: 'metered_network',
        severity: ClientRuntimeHealthStatus.warning,
        title: 'Metered network active',
        detail: 'The client is on a metered network.',
        recommendation:
            'Use Wi-Fi for large SFTP transfers or long monitoring sessions when possible.',
      ));
    }
    if (network['vpnActive'] == true) {
      issues.add(const ClientRuntimeHealthIssue(
        code: 'vpn_active',
        severity: ClientRuntimeHealthStatus.warning,
        title: 'VPN is active',
        detail: 'A client-side VPN may affect SSH routing or latency.',
        recommendation:
            'Confirm the VPN route can reach the target servers before executing.',
      ));
    }
    final proxyHost = network['httpProxyHost'];
    if (proxyHost is String && proxyHost.trim().isNotEmpty) {
      issues.add(const ClientRuntimeHealthIssue(
        code: 'http_proxy_active',
        severity: ClientRuntimeHealthStatus.warning,
        title: 'HTTP proxy detected',
        detail: 'A client proxy is configured on the active network.',
        recommendation:
            'Confirm the proxy does not interfere with model or web requests.',
      ));
    }
  }

  void _checkPermission(
    List<ClientRuntimeHealthIssue> issues,
    Map<String, dynamic> permission,
    ClientHealthCheckOptions options,
  ) {
    if (permission['error'] != null) {
      issues.add(const ClientRuntimeHealthIssue(
        code: 'permission_status_unavailable',
        severity: ClientRuntimeHealthStatus.warning,
        title: 'Permission status unavailable',
        detail: 'The client permission state could not be read.',
        recommendation:
            'Open app settings if background notifications or services do not work.',
      ));
      return;
    }
    if (options.requireBackgroundService &&
        permission['supportsNativeBackgroundService'] == false) {
      issues.add(const ClientRuntimeHealthIssue(
        code: 'background_service_unavailable',
        severity: ClientRuntimeHealthStatus.blocking,
        title: 'Background service unavailable',
        detail: 'This platform cannot keep long SSH work in a native service.',
        recommendation:
            'Keep the app foregrounded, or run the task on Android/iOS with background service support.',
      ));
    }
    if (options.requireNotifications &&
        permission['notificationGranted'] == false) {
      issues.add(const ClientRuntimeHealthIssue(
        code: 'notification_permission_denied',
        severity: ClientRuntimeHealthStatus.blocking,
        title: 'Notification permission denied',
        detail:
            'Foreground/background agent work needs notification permission for reliable status updates.',
        recommendation:
            'Grant notification permission in system app settings before starting long-running work.',
      ));
    }
    if (options.longRunning &&
        permission['supportsBatteryOptimizationExemption'] == true &&
        permission['ignoringBatteryOptimizations'] == false) {
      issues.add(const ClientRuntimeHealthIssue(
        code: 'battery_optimization_active',
        severity: ClientRuntimeHealthStatus.warning,
        title: 'Battery optimization may stop background work',
        detail:
            'Android may restrict the app while SSH sessions or monitor sampling are running.',
        recommendation:
            'Allow battery optimization exemption for SSH Mobile if you expect long background execution.',
      ));
    }
  }

  void _checkBattery(
    List<ClientRuntimeHealthIssue> issues,
    Map<String, dynamic> battery,
    ClientHealthCheckOptions options,
  ) {
    if (!options.longRunning) return;
    if (battery['error'] != null || battery['supported'] == false) return;
    if (battery['powerSaveMode'] == true) {
      issues.add(const ClientRuntimeHealthIssue(
        code: 'power_save_mode',
        severity: ClientRuntimeHealthStatus.warning,
        title: 'Power save mode is active',
        detail: 'Power save mode can delay network and background work.',
        recommendation:
            'Disable power save mode before long SSH, SFTP, or monitoring tasks.',
      ));
    }
    final percent = _numValue(battery['batteryPercent']);
    final plugged = battery['plugged'];
    final isPlugged = plugged is Map &&
        (plugged['ac'] == true ||
            plugged['usb'] == true ||
            plugged['wireless'] == true);
    if (percent != null && percent < 20 && !isPlugged) {
      issues.add(ClientRuntimeHealthIssue(
        code: 'low_battery',
        severity: ClientRuntimeHealthStatus.warning,
        title: 'Low battery',
        detail:
            'Battery is at ${percent.toStringAsFixed(percent < 10 ? 1 : 0)}% and the device is not charging.',
        recommendation:
            'Charge the device before starting long agent execution.',
      ));
    }
    final thermal = (battery['thermalStatus'] as String?)?.toLowerCase();
    if (thermal == 'moderate' ||
        thermal == 'severe' ||
        thermal == 'critical' ||
        thermal == 'emergency' ||
        thermal == 'shutdown') {
      issues.add(ClientRuntimeHealthIssue(
        code: 'thermal_pressure',
        severity: ClientRuntimeHealthStatus.warning,
        title: 'Device thermal pressure',
        detail: 'Android thermal status is $thermal.',
        recommendation:
            'Let the device cool down before running long model/tool loops.',
      ));
    }
  }

  num? _numValue(Object? value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value);
    return null;
  }
}
