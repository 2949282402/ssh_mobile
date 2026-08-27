import 'dart:io';

/// Centralized URL path constants and endpoint configuration for Telemetry.
class TelemetryEndpoints {
  const TelemetryEndpoints._();

  static const String publicAuthPath = '/api/v1/telemetry/auth';
  static const String publicEnrollPath = '/api/v1/telemetry/enroll';
  static const String publicRotatePath = '/api/v1/telemetry/enroll/rotate';
  static const String publicIngestPath = '/api/v1/telemetry/ingest';
  static const String publicPolicyPath = '/api/v1/telemetry/policy';

  static const String adminOverviewPath = '/api/admin/v1/telemetry/overview';
  static const String adminEventsPath = '/api/admin/v1/telemetry/events';
  static const String adminDiagnosticsPath =
      '/api/admin/v1/telemetry/diagnostics';
  static const String adminSettingsPath = '/api/admin/v1/telemetry/settings';

  /// Validates and normalizes a telemetry service origin.
  ///
  /// Production origins must use HTTPS. Plain HTTP is available only when a
  /// caller explicitly opts into the repository's loopback integration-test
  /// exception; it is never inferred from the hostname or build mode.
  static Uri? validateOrigin(String baseUrl, {bool allowLoopbackHttp = false}) {
    final endpoint = Uri.tryParse(baseUrl);
    final scheme = endpoint?.scheme.toLowerCase();
    final isSecureOrigin = scheme == 'https';
    final isLoopbackHttp =
        allowLoopbackHttp &&
        scheme == 'http' &&
        endpoint != null &&
        _isLoopbackHost(endpoint.host);
    if (endpoint == null ||
        (!isSecureOrigin && !isLoopbackHttp) ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.query.isNotEmpty ||
        endpoint.fragment.isNotEmpty ||
        (endpoint.path.isNotEmpty && endpoint.path != '/')) {
      return null;
    }
    return endpoint.replace(path: '', query: null, fragment: null);
  }

  /// Resolves a full URI from a base URL and endpoint path.
  static Uri resolveUri(String baseUrl, String path) {
    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$cleanBase$cleanPath');
  }
}

bool _isLoopbackHost(String host) {
  if (host.toLowerCase() == 'localhost') return true;
  return InternetAddress.tryParse(host)?.isLoopback ?? false;
}
