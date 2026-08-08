import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'mcp_invocation_policy.dart';

// MCP 本地回环服务器的不可变设置快照。持久化由 App Shell 完成，本类只负责
// 规范化和安全约束，避免网络层自行读取全局设置。
// The public named argument must remain public while the stored set stays
// private behind an immutable getter.
// ignore_for_file: prefer_initializing_formals

enum McpApprovalMode { trustedAgent, reviewConfiguredTools }

class McpServerSettings {
  static const String defaultHost = '127.0.0.1';
  static const int defaultPort = 38321;
  static const int minPort = 1024;
  static const int maxPort = 65535;

  final bool enabled;
  final String host;
  final int port;
  final String token;
  final McpApprovalMode approvalMode;
  final Set<String> _secondaryReviewTools;
  final Set<String> _exposedTools;
  final bool exposureToolsConfigured;
  final bool enableSse;

  const McpServerSettings({
    this.enabled = false,
    this.host = defaultHost,
    this.port = defaultPort,
    this.token = '',
    this.approvalMode = McpApprovalMode.reviewConfiguredTools,
    Set<String> secondaryReviewTools =
        McpInvocationPolicy.defaultSecondaryReviewTools,
    Set<String> exposedTools = const {},
    this.exposureToolsConfigured = false,
    this.enableSse = false,
    // Kept only so older callers can migrate without a breaking constructor
    // change. These values are intentionally ignored by all new policy code.
    @Deprecated('Use approvalMode instead') bool? allowWriteTools,
    @Deprecated('Use approvalMode instead') bool? requireApprovalForWriteTools,
  }) : _secondaryReviewTools = secondaryReviewTools,
       _exposedTools = exposedTools;

  String get url => 'http://$host:$port/mcp';
  bool get hasToken => token.trim().isNotEmpty;
  bool get hasValidHost => isAllowedHost(host);
  bool get hasValidPort => isValidPort(port);
  Set<String> get secondaryReviewTools =>
      Set.unmodifiable(_secondaryReviewTools);
  Set<String> get exposedTools => Set.unmodifiable(_exposedTools);

  bool isToolExposed(String toolName) {
    return !exposureToolsConfigured || _exposedTools.contains(toolName);
  }

  @Deprecated('Use approvalMode and secondaryReviewTools instead')
  bool get allowWriteTools => true;

  @Deprecated('Use approvalMode and secondaryReviewTools instead')
  bool get requireApprovalForWriteTools =>
      approvalMode == McpApprovalMode.reviewConfiguredTools;

  McpServerSettings copyWith({
    bool? enabled,
    String? host,
    int? port,
    String? token,
    McpApprovalMode? approvalMode,
    Set<String>? secondaryReviewTools,
    Set<String>? exposedTools,
    bool? exposureToolsConfigured,
    bool? enableSse,
    @Deprecated('Use approvalMode instead') bool? allowWriteTools,
    @Deprecated('Use approvalMode instead') bool? requireApprovalForWriteTools,
  }) {
    return McpServerSettings(
      enabled: enabled ?? this.enabled,
      host: host == null ? this.host : normalizeHost(host),
      port: port ?? this.port,
      token: token ?? this.token,
      approvalMode: approvalMode ?? this.approvalMode,
      secondaryReviewTools: secondaryReviewTools ?? this.secondaryReviewTools,
      exposedTools: exposedTools ?? this.exposedTools,
      exposureToolsConfigured:
          exposureToolsConfigured ?? this.exposureToolsConfigured,
      enableSse: enableSse ?? this.enableSse,
    );
  }

  static String normalizeHost(String host) {
    final normalized = host.trim().toLowerCase();
    return normalized == 'localhost' ? 'localhost' : normalized;
  }

  static bool isAllowedHost(String host) {
    final normalized = normalizeHost(host);
    return normalized == '127.0.0.1' || normalized == 'localhost';
  }

  static bool isValidPort(int port) {
    return port >= minPort && port <= maxPort;
  }

  static int normalizePort(int? port) {
    if (port == null || !isValidPort(port)) {
      return defaultPort;
    }
    return port;
  }

  static String generateToken({int bytes = 32}) {
    final random = Random.secure();
    final data = Uint8List.fromList(
      List<int>.generate(bytes, (_) => random.nextInt(256)),
    );
    return base64UrlEncode(data).replaceAll('=', '');
  }
}
