/// Centralized URL path constants and endpoint configuration for Telemetry.
class TelemetryEndpoints {
  const TelemetryEndpoints._();

  static const String publicAuthPath = '/api/v1/telemetry/auth';
  static const String publicIngestPath = '/api/v1/telemetry/ingest';
  static const String publicPolicyPath = '/api/v1/telemetry/policy';

  static const String adminOverviewPath = '/api/admin/v1/telemetry/overview';
  static const String adminEventsPath = '/api/admin/v1/telemetry/events';
  static const String adminDiagnosticsPath =
      '/api/admin/v1/telemetry/diagnostics';
  static const String adminSettingsPath = '/api/admin/v1/telemetry/settings';

  /// Resolves a full URI from a base URL and endpoint path.
  static Uri resolveUri(String baseUrl, String path) {
    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$cleanBase$cleanPath');
  }
}
