// GENERATED DO NOT EDIT, regenerate via dart run tool/gen_telemetry_contract.dart
// Code generated from contracts/telemetry/*.yaml; DO NOT EDIT.

export type TelemetryRecordType = 'analytics' | 'diagnostic';
export type TelemetrySeverity = 'info' | 'warn' | 'error' | 'critical';

export type TelemetryPropertyType = 'string' | 'integer' | 'boolean';

export interface TelemetryPropertyDefinition {
  readonly name: string;
  readonly type: TelemetryPropertyType;
  readonly required: boolean;
}

export interface TelemetryEventDefinition {
  readonly name: string;
  readonly version: number;
  readonly recordType: TelemetryRecordType;
  readonly feature: string;
  readonly severity: TelemetrySeverity;
  readonly operationGroup: string;
  readonly operationRole: string;
  readonly businessOperation: boolean;
  readonly description: string;
  readonly allowedProperties: readonly TelemetryPropertyDefinition[];
  readonly requiredProperties: readonly string[];
}

export interface TelemetryErrorCodeDefinition {
  readonly code: string;
  readonly category: string;
  readonly terminalFailure: boolean;
  readonly description: string;
}

export class TelemetryEvents {
  static readonly appLifecycleStarted: TelemetryEventDefinition = {
    name: "app.lifecycle.started",
    version: 1,
    recordType: "analytics",
    feature: "app",
    severity: "info",
    operationGroup: "app.lifecycle",
    operationRole: "started",
    businessOperation: false,
    description: "Emitted when the application process completes bootstrap and starts.",
    allowedProperties: [
      {
        name: "start_type",
        type: "string",
        required: false,
      },
      {
        name: "cold_start",
        type: "boolean",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly appLifecycleBackgrounded: TelemetryEventDefinition = {
    name: "app.lifecycle.backgrounded",
    version: 1,
    recordType: "analytics",
    feature: "app",
    severity: "info",
    operationGroup: "app.lifecycle",
    operationRole: "state_change",
    businessOperation: false,
    description: "Emitted when the application transitions to the background.",
    allowedProperties: [
      {
        name: "active_sessions",
        type: "integer",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly appLifecycleForegrounded: TelemetryEventDefinition = {
    name: "app.lifecycle.foregrounded",
    version: 1,
    recordType: "analytics",
    feature: "app",
    severity: "info",
    operationGroup: "app.lifecycle",
    operationRole: "state_change",
    businessOperation: false,
    description: "Emitted when the application returns to the foreground.",
    allowedProperties: [
      {
        name: "background_duration_ms",
        type: "integer",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly networkQuicConnected: TelemetryEventDefinition = {
    name: "network.quic.connected",
    version: 1,
    recordType: "analytics",
    feature: "network",
    severity: "info",
    operationGroup: "network.quic",
    operationRole: "success",
    businessOperation: true,
    description: "Emitted when a direct QUIC network path is established.",
    allowedProperties: [
      {
        name: "rtt_ms",
        type: "integer",
        required: false,
      },
      {
        name: "protocol_version",
        type: "string",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly networkQuicFailed: TelemetryEventDefinition = {
    name: "network.quic.failed",
    version: 1,
    recordType: "diagnostic",
    feature: "network",
    severity: "warn",
    operationGroup: "network.quic",
    operationRole: "failure",
    businessOperation: true,
    description: "Emitted when QUIC connection attempt fails.",
    allowedProperties: [
      {
        name: "reason",
        type: "string",
        required: false,
      },
      {
        name: "fallback_used",
        type: "boolean",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly networkRelayConnected: TelemetryEventDefinition = {
    name: "network.relay.connected",
    version: 1,
    recordType: "analytics",
    feature: "network",
    severity: "info",
    operationGroup: "network.relay",
    operationRole: "success",
    businessOperation: true,
    description: "Emitted when connected to the Relay control or data plane.",
    allowedProperties: [
      {
        name: "relay_region",
        type: "string",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly networkRelayFallback: TelemetryEventDefinition = {
    name: "network.relay.fallback",
    version: 1,
    recordType: "diagnostic",
    feature: "network",
    severity: "warn",
    operationGroup: "network.relay",
    operationRole: "fallback",
    businessOperation: false,
    description: "Emitted when connection falls back from direct path to Relay.",
    allowedProperties: [
      {
        name: "direct_error",
        type: "string",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly networkRelayFailed: TelemetryEventDefinition = {
    name: "network.relay.failed",
    version: 1,
    recordType: "diagnostic",
    feature: "network",
    severity: "error",
    operationGroup: "network.relay",
    operationRole: "failure",
    businessOperation: true,
    description: "Emitted when a Relay connection attempt fails.",
    allowedProperties: [
      {
        name: "reason",
        type: "string",
        required: false,
      },
      {
        name: "fallback_used",
        type: "boolean",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly sshSessionStarted: TelemetryEventDefinition = {
    name: "ssh.session.started",
    version: 1,
    recordType: "analytics",
    feature: "ssh",
    severity: "info",
    operationGroup: "ssh.session",
    operationRole: "started",
    businessOperation: true,
    description: "Emitted when an SSH interactive terminal or command session starts.",
    allowedProperties: [
      {
        name: "session_type",
        type: "string",
        required: false,
      },
      {
        name: "auth_method",
        type: "string",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly sshSessionTerminated: TelemetryEventDefinition = {
    name: "ssh.session.terminated",
    version: 1,
    recordType: "analytics",
    feature: "ssh",
    severity: "info",
    operationGroup: "ssh.session",
    operationRole: "success",
    businessOperation: true,
    description: "Emitted when an SSH session closes normally.",
    allowedProperties: [
      {
        name: "duration_ms",
        type: "integer",
        required: false,
      },
      {
        name: "exit_code",
        type: "integer",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly sshSessionFailed: TelemetryEventDefinition = {
    name: "ssh.session.failed",
    version: 1,
    recordType: "diagnostic",
    feature: "ssh",
    severity: "error",
    operationGroup: "ssh.session",
    operationRole: "failure",
    businessOperation: true,
    description: "Emitted when an SSH connection or authentication fails.",
    allowedProperties: [
      {
        name: "stage",
        type: "string",
        required: false,
      },
      {
        name: "retry_count",
        type: "integer",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly sshSessionConnected: TelemetryEventDefinition = {
    name: "ssh.session.connected",
    version: 1,
    recordType: "analytics",
    feature: "ssh",
    severity: "info",
    operationGroup: "ssh.session",
    operationRole: "success",
    businessOperation: true,
    description: "Emitted when an SSH session connection is established.",
    allowedProperties: [
      {
        name: "session_type",
        type: "string",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly sftpTransferStarted: TelemetryEventDefinition = {
    name: "sftp.transfer.started",
    version: 1,
    recordType: "analytics",
    feature: "sftp",
    severity: "info",
    operationGroup: "sftp.transfer",
    operationRole: "started",
    businessOperation: true,
    description: "Emitted when an SFTP file upload or download begins.",
    allowedProperties: [
      {
        name: "direction",
        type: "string",
        required: true,
      },
      {
        name: "file_size_bytes",
        type: "integer",
        required: false,
      },
    ],
    requiredProperties: ["direction"],
  };

  static readonly sftpTransferCompleted: TelemetryEventDefinition = {
    name: "sftp.transfer.completed",
    version: 1,
    recordType: "analytics",
    feature: "sftp",
    severity: "info",
    operationGroup: "sftp.transfer",
    operationRole: "success",
    businessOperation: true,
    description: "Emitted when an SFTP file transfer completes successfully.",
    allowedProperties: [
      {
        name: "direction",
        type: "string",
        required: true,
      },
      {
        name: "bytes_transferred",
        type: "integer",
        required: true,
      },
      {
        name: "duration_ms",
        type: "integer",
        required: false,
      },
    ],
    requiredProperties: ["direction", "bytes_transferred"],
  };

  static readonly sftpTransferFailed: TelemetryEventDefinition = {
    name: "sftp.transfer.failed",
    version: 1,
    recordType: "diagnostic",
    feature: "sftp",
    severity: "error",
    operationGroup: "sftp.transfer",
    operationRole: "failure",
    businessOperation: true,
    description: "Emitted when an SFTP transfer fails.",
    allowedProperties: [
      {
        name: "direction",
        type: "string",
        required: true,
      },
      {
        name: "bytes_transferred",
        type: "integer",
        required: false,
      },
      {
        name: "stage",
        type: "string",
        required: false,
      },
    ],
    requiredProperties: ["direction"],
  };

  static readonly lanDiscoveryPeerFound: TelemetryEventDefinition = {
    name: "lan.discovery.peer_found",
    version: 1,
    recordType: "analytics",
    feature: "lan_share",
    severity: "info",
    operationGroup: "lan.discovery",
    operationRole: "success",
    businessOperation: true,
    description: "Emitted when a LAN peer is discovered.",
    allowedProperties: [
      {
        name: "peer_count",
        type: "integer",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly lanTransferCompleted: TelemetryEventDefinition = {
    name: "lan.transfer.completed",
    version: 1,
    recordType: "analytics",
    feature: "lan_share",
    severity: "info",
    operationGroup: "lan.transfer",
    operationRole: "success",
    businessOperation: true,
    description: "Emitted when LAN file transfer completes.",
    allowedProperties: [
      {
        name: "bytes_transferred",
        type: "integer",
        required: true,
      },
      {
        name: "duration_ms",
        type: "integer",
        required: false,
      },
    ],
    requiredProperties: ["bytes_transferred"],
  };

  static readonly aiChatRequest: TelemetryEventDefinition = {
    name: "ai.chat.request",
    version: 1,
    recordType: "analytics",
    feature: "ai",
    severity: "info",
    operationGroup: "ai.chat",
    operationRole: "started",
    businessOperation: true,
    description: "Emitted when a client-side AI chat prompt request is sent.",
    allowedProperties: [
      {
        name: "model_type",
        type: "string",
        required: false,
      },
      {
        name: "token_estimate",
        type: "integer",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly aiChatResponse: TelemetryEventDefinition = {
    name: "ai.chat.response",
    version: 1,
    recordType: "analytics",
    feature: "ai",
    severity: "info",
    operationGroup: "ai.chat",
    operationRole: "success",
    businessOperation: true,
    description: "Emitted when an AI response is successfully received.",
    allowedProperties: [
      {
        name: "latency_ms",
        type: "integer",
        required: false,
      },
      {
        name: "status",
        type: "string",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly aiChatFailed: TelemetryEventDefinition = {
    name: "ai.chat.failed",
    version: 1,
    recordType: "diagnostic",
    feature: "ai",
    severity: "error",
    operationGroup: "ai.chat",
    operationRole: "failure",
    businessOperation: true,
    description: "Emitted when an AI chat request fails.",
    allowedProperties: [
      {
        name: "provider",
        type: "string",
        required: false,
      },
      {
        name: "http_status",
        type: "integer",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly appDiagnosticLog: TelemetryEventDefinition = {
    name: "app.diagnostic.log",
    version: 1,
    recordType: "diagnostic",
    feature: "app",
    severity: "warn",
    operationGroup: "app.diagnostic",
    operationRole: "diagnostic",
    businessOperation: false,
    description: "General diagnostic log entry for client and system diagnostics.",
    allowedProperties: [
      {
        name: "message",
        type: "string",
        required: false,
      },
      {
        name: "category",
        type: "string",
        required: false,
      },
      {
        name: "stage",
        type: "string",
        required: false,
      },
      {
        name: "direct_error",
        type: "string",
        required: false,
      },
      {
        name: "details",
        type: "string",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly appErrorCaptured: TelemetryEventDefinition = {
    name: "app.error.captured",
    version: 1,
    recordType: "diagnostic",
    feature: "app",
    severity: "error",
    operationGroup: "app.error",
    operationRole: "failure",
    businessOperation: false,
    description: "Emitted when an uncaught application error is captured.",
    allowedProperties: [
      {
        name: "message",
        type: "string",
        required: true,
      },
      {
        name: "category",
        type: "string",
        required: false,
      },
      {
        name: "stage",
        type: "string",
        required: false,
      },
      {
        name: "details",
        type: "string",
        required: false,
      },
    ],
    requiredProperties: ["message"],
  };

  static readonly appCrashReported: TelemetryEventDefinition = {
    name: "app.crash.reported",
    version: 1,
    recordType: "diagnostic",
    feature: "app",
    severity: "critical",
    operationGroup: "app.crash",
    operationRole: "failure",
    businessOperation: false,
    description: "Emitted when a fatal application crash is reported.",
    allowedProperties: [
      {
        name: "message",
        type: "string",
        required: true,
      },
      {
        name: "category",
        type: "string",
        required: false,
      },
      {
        name: "stage",
        type: "string",
        required: false,
      },
      {
        name: "details",
        type: "string",
        required: false,
      },
    ],
    requiredProperties: ["message"],
  };

  static readonly telemetryBatchUploaded: TelemetryEventDefinition = {
    name: "telemetry.batch.uploaded",
    version: 1,
    recordType: "analytics",
    feature: "telemetry",
    severity: "info",
    operationGroup: "telemetry.batch",
    operationRole: "success",
    businessOperation: false,
    description: "Emitted when a telemetry batch is successfully acknowledged by server.",
    allowedProperties: [
      {
        name: "record_count",
        type: "integer",
        required: true,
      },
      {
        name: "duration_ms",
        type: "integer",
        required: false,
      },
    ],
    requiredProperties: ["record_count"],
  };

  static readonly telemetryBatchFailed: TelemetryEventDefinition = {
    name: "telemetry.batch.failed",
    version: 1,
    recordType: "diagnostic",
    feature: "telemetry",
    severity: "warn",
    operationGroup: "telemetry.batch",
    operationRole: "failure",
    businessOperation: false,
    description: "Emitted when a telemetry batch upload fails.",
    allowedProperties: [
      {
        name: "error_type",
        type: "string",
        required: false,
      },
      {
        name: "http_status",
        type: "integer",
        required: false,
      },
      {
        name: "retry_count",
        type: "integer",
        required: false,
      },
    ],
    requiredProperties: [],
  };

  static readonly all: readonly TelemetryEventDefinition[] = [
    TelemetryEvents.appLifecycleStarted,
    TelemetryEvents.appLifecycleBackgrounded,
    TelemetryEvents.appLifecycleForegrounded,
    TelemetryEvents.networkQuicConnected,
    TelemetryEvents.networkQuicFailed,
    TelemetryEvents.networkRelayConnected,
    TelemetryEvents.networkRelayFallback,
    TelemetryEvents.networkRelayFailed,
    TelemetryEvents.sshSessionStarted,
    TelemetryEvents.sshSessionTerminated,
    TelemetryEvents.sshSessionFailed,
    TelemetryEvents.sshSessionConnected,
    TelemetryEvents.sftpTransferStarted,
    TelemetryEvents.sftpTransferCompleted,
    TelemetryEvents.sftpTransferFailed,
    TelemetryEvents.lanDiscoveryPeerFound,
    TelemetryEvents.lanTransferCompleted,
    TelemetryEvents.aiChatRequest,
    TelemetryEvents.aiChatResponse,
    TelemetryEvents.aiChatFailed,
    TelemetryEvents.appDiagnosticLog,
    TelemetryEvents.appErrorCaptured,
    TelemetryEvents.appCrashReported,
    TelemetryEvents.telemetryBatchUploaded,
    TelemetryEvents.telemetryBatchFailed,
  ];

  private constructor() {}
}

export class TelemetryErrorCodes {
  static readonly netQuicConnRefused: TelemetryErrorCodeDefinition = {
    code: "NET_QUIC_CONN_REFUSED",
    category: "network",
    terminalFailure: false,
    description: "Direct QUIC connection refused by peer or relay; fallback may proceed.",
  };

  static readonly netQuicTimeout: TelemetryErrorCodeDefinition = {
    code: "NET_QUIC_TIMEOUT",
    category: "network",
    terminalFailure: false,
    description: "Direct QUIC connection handshake timed out.",
  };

  static readonly netQuicFailed: TelemetryErrorCodeDefinition = {
    code: "NET_QUIC_FAILED",
    category: "network",
    terminalFailure: false,
    description: "Direct QUIC connection failed for an unclassified reason; fallback may proceed.",
  };

  static readonly netRelayUnavailable: TelemetryErrorCodeDefinition = {
    code: "NET_RELAY_UNAVAILABLE",
    category: "network",
    terminalFailure: true,
    description: "Relay server is unreachable or returned a service unavailable error.",
  };

  static readonly sshAuthFailed: TelemetryErrorCodeDefinition = {
    code: "SSH_AUTH_FAILED",
    category: "ssh",
    terminalFailure: true,
    description: "SSH password, public key, or interactive authentication failed.",
  };

  static readonly sshHostKeyMismatch: TelemetryErrorCodeDefinition = {
    code: "SSH_HOST_KEY_MISMATCH",
    category: "ssh",
    terminalFailure: true,
    description: "Remote host key verification failed or did not match known hosts.",
  };

  static readonly sshTimeout: TelemetryErrorCodeDefinition = {
    code: "SSH_TIMEOUT",
    category: "ssh",
    terminalFailure: true,
    description: "SSH connection or banner exchange timed out.",
  };

  static readonly sshConnectFailed: TelemetryErrorCodeDefinition = {
    code: "SSH_CONNECT_FAILED",
    category: "ssh",
    terminalFailure: true,
    description: "SSH connection failed for a reason not covered by a more specific code.",
  };

  static readonly sftpPermissionDenied: TelemetryErrorCodeDefinition = {
    code: "SFTP_PERMISSION_DENIED",
    category: "sftp",
    terminalFailure: true,
    description: "Remote filesystem operation denied due to lack of permissions.",
  };

  static readonly sftpFileNotFound: TelemetryErrorCodeDefinition = {
    code: "SFTP_FILE_NOT_FOUND",
    category: "sftp",
    terminalFailure: true,
    description: "Remote target file or directory does not exist.",
  };

  static readonly sftpTransferAborted: TelemetryErrorCodeDefinition = {
    code: "SFTP_TRANSFER_ABORTED",
    category: "sftp",
    terminalFailure: true,
    description: "SFTP file transfer was aborted by user or connection drop.",
  };

  static readonly sftpQuotaExceeded: TelemetryErrorCodeDefinition = {
    code: "SFTP_QUOTA_EXCEEDED",
    category: "sftp",
    terminalFailure: true,
    description: "Remote filesystem quota or available space was exhausted.",
  };

  static readonly sftpOperationFailed: TelemetryErrorCodeDefinition = {
    code: "SFTP_OPERATION_FAILED",
    category: "sftp",
    terminalFailure: true,
    description: "SFTP operation failed for an unclassified reason.",
  };

  static readonly lanPeerDisconnected: TelemetryErrorCodeDefinition = {
    code: "LAN_PEER_DISCONNECTED",
    category: "lan",
    terminalFailure: false,
    description: "LAN peer disconnected during discovery or session.",
  };

  static readonly lanHandshakeFailed: TelemetryErrorCodeDefinition = {
    code: "LAN_HANDSHAKE_FAILED",
    category: "lan",
    terminalFailure: true,
    description: "LAN encryption or pairing handshake failed.",
  };

  static readonly aiRateLimited: TelemetryErrorCodeDefinition = {
    code: "AI_RATE_LIMITED",
    category: "ai",
    terminalFailure: false,
    description: "AI provider rate limit reached; retryable.",
  };

  static readonly aiServiceUnavailable: TelemetryErrorCodeDefinition = {
    code: "AI_SERVICE_UNAVAILABLE",
    category: "ai",
    terminalFailure: true,
    description: "AI provider service unavailable or invalid API key.",
  };

  static readonly appUncaughtError: TelemetryErrorCodeDefinition = {
    code: "APP_UNCAUGHT_ERROR",
    category: "app",
    terminalFailure: false,
    description: "An uncaught application error was captured without a confirmed fatal crash.",
  };

  static readonly appFatalError: TelemetryErrorCodeDefinition = {
    code: "APP_FATAL_ERROR",
    category: "app",
    terminalFailure: true,
    description: "A fatal application error or crash was captured.",
  };

  static readonly telemetryAuthFailed: TelemetryErrorCodeDefinition = {
    code: "TELEMETRY_AUTH_FAILED",
    category: "telemetry",
    terminalFailure: true,
    description: "Device authentication to telemetry endpoint failed.",
  };

  static readonly telemetryNetworkError: TelemetryErrorCodeDefinition = {
    code: "TELEMETRY_NETWORK_ERROR",
    category: "telemetry",
    terminalFailure: false,
    description: "Transient network failure during telemetry upload.",
  };

  static readonly telemetryStorageFull: TelemetryErrorCodeDefinition = {
    code: "TELEMETRY_STORAGE_FULL",
    category: "telemetry",
    terminalFailure: false,
    description: "Local storage limit reached; overflow state exposed.",
  };

  static readonly all: readonly TelemetryErrorCodeDefinition[] = [
    TelemetryErrorCodes.netQuicConnRefused,
    TelemetryErrorCodes.netQuicTimeout,
    TelemetryErrorCodes.netQuicFailed,
    TelemetryErrorCodes.netRelayUnavailable,
    TelemetryErrorCodes.sshAuthFailed,
    TelemetryErrorCodes.sshHostKeyMismatch,
    TelemetryErrorCodes.sshTimeout,
    TelemetryErrorCodes.sshConnectFailed,
    TelemetryErrorCodes.sftpPermissionDenied,
    TelemetryErrorCodes.sftpFileNotFound,
    TelemetryErrorCodes.sftpTransferAborted,
    TelemetryErrorCodes.sftpQuotaExceeded,
    TelemetryErrorCodes.sftpOperationFailed,
    TelemetryErrorCodes.lanPeerDisconnected,
    TelemetryErrorCodes.lanHandshakeFailed,
    TelemetryErrorCodes.aiRateLimited,
    TelemetryErrorCodes.aiServiceUnavailable,
    TelemetryErrorCodes.appUncaughtError,
    TelemetryErrorCodes.appFatalError,
    TelemetryErrorCodes.telemetryAuthFailed,
    TelemetryErrorCodes.telemetryNetworkError,
    TelemetryErrorCodes.telemetryStorageFull,
  ];

  private constructor() {}
}
