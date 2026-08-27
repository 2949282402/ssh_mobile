// GENERATED DO NOT EDIT, regenerate via dart run tool/gen_telemetry_contract.dart
// Code generated from contracts/telemetry/*.yaml; DO NOT EDIT.

package generated

type AllowedProperty struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	Required bool   `json:"required"`
}

type EventDefinition struct {
	Name              string            `json:"name"`
	Version           int               `json:"version"`
	RecordType        string            `json:"recordType"`
	Feature           string            `json:"feature"`
	Severity          string            `json:"severity"`
	OperationGroup    string            `json:"operationGroup"`
	OperationRole     string            `json:"operationRole"`
	Description       string            `json:"description"`
	AllowedProperties []AllowedProperty `json:"allowedProperties"`
}

type ErrorCodeDefinition struct {
	Code            string `json:"code"`
	Category        string `json:"category"`
	TerminalFailure bool   `json:"terminalFailure"`
	Description     string `json:"description"`
}

var TelemetryEvents = []EventDefinition{
	{
		Name:           "app.lifecycle.started",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "app",
		Severity:       "info",
		OperationGroup: "app.lifecycle",
		OperationRole:  "started",
		Description:    "Emitted when the application process completes bootstrap and starts.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "start_type",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "cold_start",
				Type:     "boolean",
				Required: false,
			},
		},
	},
	{
		Name:           "app.lifecycle.backgrounded",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "app",
		Severity:       "info",
		OperationGroup: "app.lifecycle",
		OperationRole:  "state_change",
		Description:    "Emitted when the application transitions to the background.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "active_sessions",
				Type:     "integer",
				Required: false,
			},
		},
	},
	{
		Name:           "app.lifecycle.foregrounded",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "app",
		Severity:       "info",
		OperationGroup: "app.lifecycle",
		OperationRole:  "state_change",
		Description:    "Emitted when the application returns to the foreground.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "background_duration_ms",
				Type:     "integer",
				Required: false,
			},
		},
	},
	{
		Name:           "network.quic.connected",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "network",
		Severity:       "info",
		OperationGroup: "network.quic",
		OperationRole:  "success",
		Description:    "Emitted when a direct QUIC network path is established.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "rtt_ms",
				Type:     "integer",
				Required: false,
			},
			{
				Name:     "protocol_version",
				Type:     "string",
				Required: false,
			},
		},
	},
	{
		Name:           "network.quic.failed",
		Version:        1,
		RecordType:     "diagnostic",
		Feature:        "network",
		Severity:       "warn",
		OperationGroup: "network.quic",
		OperationRole:  "failure",
		Description:    "Emitted when QUIC connection attempt fails.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "reason",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "fallback_used",
				Type:     "boolean",
				Required: false,
			},
		},
	},
	{
		Name:           "network.relay.connected",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "network",
		Severity:       "info",
		OperationGroup: "network.relay",
		OperationRole:  "success",
		Description:    "Emitted when connected to the Relay control or data plane.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "relay_region",
				Type:     "string",
				Required: false,
			},
		},
	},
	{
		Name:           "network.relay.fallback",
		Version:        1,
		RecordType:     "diagnostic",
		Feature:        "network",
		Severity:       "warn",
		OperationGroup: "network.relay",
		OperationRole:  "fallback",
		Description:    "Emitted when connection falls back from direct path to Relay.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "direct_error",
				Type:     "string",
				Required: false,
			},
		},
	},
	{
		Name:           "network.relay.failed",
		Version:        1,
		RecordType:     "diagnostic",
		Feature:        "network",
		Severity:       "error",
		OperationGroup: "network.relay",
		OperationRole:  "failure",
		Description:    "Emitted when a Relay connection attempt fails.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "reason",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "fallback_used",
				Type:     "boolean",
				Required: false,
			},
		},
	},
	{
		Name:           "ssh.session.started",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "ssh",
		Severity:       "info",
		OperationGroup: "ssh.session",
		OperationRole:  "started",
		Description:    "Emitted when an SSH interactive terminal or command session starts.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "session_type",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "auth_method",
				Type:     "string",
				Required: false,
			},
		},
	},
	{
		Name:           "ssh.session.terminated",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "ssh",
		Severity:       "info",
		OperationGroup: "ssh.session",
		OperationRole:  "success",
		Description:    "Emitted when an SSH session closes normally.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "duration_ms",
				Type:     "integer",
				Required: false,
			},
			{
				Name:     "exit_code",
				Type:     "integer",
				Required: false,
			},
		},
	},
	{
		Name:           "ssh.session.failed",
		Version:        1,
		RecordType:     "diagnostic",
		Feature:        "ssh",
		Severity:       "error",
		OperationGroup: "ssh.session",
		OperationRole:  "failure",
		Description:    "Emitted when an SSH connection or authentication fails.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "stage",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "retry_count",
				Type:     "integer",
				Required: false,
			},
		},
	},
	{
		Name:           "ssh.session.connected",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "ssh",
		Severity:       "info",
		OperationGroup: "ssh.session",
		OperationRole:  "success",
		Description:    "Emitted when an SSH session connection is established.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "session_type",
				Type:     "string",
				Required: false,
			},
		},
	},
	{
		Name:           "sftp.transfer.started",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "sftp",
		Severity:       "info",
		OperationGroup: "sftp.transfer",
		OperationRole:  "started",
		Description:    "Emitted when an SFTP file upload or download begins.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "direction",
				Type:     "string",
				Required: true,
			},
			{
				Name:     "file_size_bytes",
				Type:     "integer",
				Required: false,
			},
		},
	},
	{
		Name:           "sftp.transfer.completed",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "sftp",
		Severity:       "info",
		OperationGroup: "sftp.transfer",
		OperationRole:  "success",
		Description:    "Emitted when an SFTP file transfer completes successfully.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "direction",
				Type:     "string",
				Required: true,
			},
			{
				Name:     "bytes_transferred",
				Type:     "integer",
				Required: true,
			},
			{
				Name:     "duration_ms",
				Type:     "integer",
				Required: false,
			},
		},
	},
	{
		Name:           "sftp.transfer.failed",
		Version:        1,
		RecordType:     "diagnostic",
		Feature:        "sftp",
		Severity:       "error",
		OperationGroup: "sftp.transfer",
		OperationRole:  "failure",
		Description:    "Emitted when an SFTP transfer fails.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "direction",
				Type:     "string",
				Required: true,
			},
			{
				Name:     "bytes_transferred",
				Type:     "integer",
				Required: false,
			},
			{
				Name:     "stage",
				Type:     "string",
				Required: false,
			},
		},
	},
	{
		Name:           "lan.discovery.peer_found",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "lan_share",
		Severity:       "info",
		OperationGroup: "lan.discovery",
		OperationRole:  "success",
		Description:    "Emitted when a LAN peer is discovered.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "peer_count",
				Type:     "integer",
				Required: false,
			},
		},
	},
	{
		Name:           "lan.transfer.completed",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "lan_share",
		Severity:       "info",
		OperationGroup: "lan.transfer",
		OperationRole:  "success",
		Description:    "Emitted when LAN file transfer completes.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "bytes_transferred",
				Type:     "integer",
				Required: true,
			},
			{
				Name:     "duration_ms",
				Type:     "integer",
				Required: false,
			},
		},
	},
	{
		Name:           "ai.chat.request",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "ai",
		Severity:       "info",
		OperationGroup: "ai.chat",
		OperationRole:  "started",
		Description:    "Emitted when a client-side AI chat prompt request is sent.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "model_type",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "token_estimate",
				Type:     "integer",
				Required: false,
			},
		},
	},
	{
		Name:           "ai.chat.response",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "ai",
		Severity:       "info",
		OperationGroup: "ai.chat",
		OperationRole:  "success",
		Description:    "Emitted when an AI response is successfully received.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "latency_ms",
				Type:     "integer",
				Required: false,
			},
			{
				Name:     "status",
				Type:     "string",
				Required: false,
			},
		},
	},
	{
		Name:           "ai.chat.failed",
		Version:        1,
		RecordType:     "diagnostic",
		Feature:        "ai",
		Severity:       "error",
		OperationGroup: "ai.chat",
		OperationRole:  "failure",
		Description:    "Emitted when an AI chat request fails.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "provider",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "http_status",
				Type:     "integer",
				Required: false,
			},
		},
	},
	{
		Name:           "app.diagnostic.log",
		Version:        1,
		RecordType:     "diagnostic",
		Feature:        "app",
		Severity:       "warn",
		OperationGroup: "app.diagnostic",
		OperationRole:  "diagnostic",
		Description:    "General diagnostic log entry for client and system diagnostics.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "message",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "category",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "stage",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "direct_error",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "details",
				Type:     "string",
				Required: false,
			},
		},
	},
	{
		Name:           "app.error.captured",
		Version:        1,
		RecordType:     "diagnostic",
		Feature:        "app",
		Severity:       "error",
		OperationGroup: "app.error",
		OperationRole:  "failure",
		Description:    "Emitted when an uncaught application error is captured.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "message",
				Type:     "string",
				Required: true,
			},
			{
				Name:     "category",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "stage",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "details",
				Type:     "string",
				Required: false,
			},
		},
	},
	{
		Name:           "app.crash.reported",
		Version:        1,
		RecordType:     "diagnostic",
		Feature:        "app",
		Severity:       "critical",
		OperationGroup: "app.crash",
		OperationRole:  "failure",
		Description:    "Emitted when a fatal application crash is reported.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "message",
				Type:     "string",
				Required: true,
			},
			{
				Name:     "category",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "stage",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "details",
				Type:     "string",
				Required: false,
			},
		},
	},
	{
		Name:           "telemetry.batch.uploaded",
		Version:        1,
		RecordType:     "analytics",
		Feature:        "telemetry",
		Severity:       "info",
		OperationGroup: "telemetry.batch",
		OperationRole:  "success",
		Description:    "Emitted when a telemetry batch is successfully acknowledged by server.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "record_count",
				Type:     "integer",
				Required: true,
			},
			{
				Name:     "duration_ms",
				Type:     "integer",
				Required: false,
			},
		},
	},
	{
		Name:           "telemetry.batch.failed",
		Version:        1,
		RecordType:     "diagnostic",
		Feature:        "telemetry",
		Severity:       "warn",
		OperationGroup: "telemetry.batch",
		OperationRole:  "failure",
		Description:    "Emitted when a telemetry batch upload fails.",
		AllowedProperties: []AllowedProperty{
			{
				Name:     "error_type",
				Type:     "string",
				Required: false,
			},
			{
				Name:     "http_status",
				Type:     "integer",
				Required: false,
			},
			{
				Name:     "retry_count",
				Type:     "integer",
				Required: false,
			},
		},
	},
}

var TelemetryErrorCodes = []ErrorCodeDefinition{
	{
		Code:            "NET_QUIC_CONN_REFUSED",
		Category:        "network",
		TerminalFailure: false,
		Description:     "Direct QUIC connection refused by peer or relay; fallback may proceed.",
	},
	{
		Code:            "NET_QUIC_TIMEOUT",
		Category:        "network",
		TerminalFailure: false,
		Description:     "Direct QUIC connection handshake timed out.",
	},
	{
		Code:            "NET_RELAY_UNAVAILABLE",
		Category:        "network",
		TerminalFailure: true,
		Description:     "Relay server is unreachable or returned a service unavailable error.",
	},
	{
		Code:            "SSH_AUTH_FAILED",
		Category:        "ssh",
		TerminalFailure: true,
		Description:     "SSH password, public key, or interactive authentication failed.",
	},
	{
		Code:            "SSH_HOST_KEY_MISMATCH",
		Category:        "ssh",
		TerminalFailure: true,
		Description:     "Remote host key verification failed or did not match known hosts.",
	},
	{
		Code:            "SSH_TIMEOUT",
		Category:        "ssh",
		TerminalFailure: true,
		Description:     "SSH connection or banner exchange timed out.",
	},
	{
		Code:            "SSH_CONNECT_FAILED",
		Category:        "ssh",
		TerminalFailure: true,
		Description:     "SSH connection failed for a reason not covered by a more specific code.",
	},
	{
		Code:            "SFTP_PERMISSION_DENIED",
		Category:        "sftp",
		TerminalFailure: true,
		Description:     "Remote filesystem operation denied due to lack of permissions.",
	},
	{
		Code:            "SFTP_FILE_NOT_FOUND",
		Category:        "sftp",
		TerminalFailure: true,
		Description:     "Remote target file or directory does not exist.",
	},
	{
		Code:            "SFTP_TRANSFER_ABORTED",
		Category:        "sftp",
		TerminalFailure: true,
		Description:     "SFTP file transfer was aborted by user or connection drop.",
	},
	{
		Code:            "SFTP_QUOTA_EXCEEDED",
		Category:        "sftp",
		TerminalFailure: true,
		Description:     "Remote filesystem quota or available space was exhausted.",
	},
	{
		Code:            "SFTP_OPERATION_FAILED",
		Category:        "sftp",
		TerminalFailure: true,
		Description:     "SFTP operation failed for an unclassified reason.",
	},
	{
		Code:            "LAN_PEER_DISCONNECTED",
		Category:        "lan",
		TerminalFailure: false,
		Description:     "LAN peer disconnected during discovery or session.",
	},
	{
		Code:            "LAN_HANDSHAKE_FAILED",
		Category:        "lan",
		TerminalFailure: true,
		Description:     "LAN encryption or pairing handshake failed.",
	},
	{
		Code:            "AI_RATE_LIMITED",
		Category:        "ai",
		TerminalFailure: false,
		Description:     "AI provider rate limit reached; retryable.",
	},
	{
		Code:            "AI_SERVICE_UNAVAILABLE",
		Category:        "ai",
		TerminalFailure: true,
		Description:     "AI provider service unavailable or invalid API key.",
	},
	{
		Code:            "APP_UNCAUGHT_ERROR",
		Category:        "app",
		TerminalFailure: false,
		Description:     "An uncaught application error was captured without a confirmed fatal crash.",
	},
	{
		Code:            "APP_FATAL_ERROR",
		Category:        "app",
		TerminalFailure: true,
		Description:     "A fatal application error or crash was captured.",
	},
	{
		Code:            "TELEMETRY_AUTH_FAILED",
		Category:        "telemetry",
		TerminalFailure: true,
		Description:     "Device authentication to telemetry endpoint failed.",
	},
	{
		Code:            "TELEMETRY_NETWORK_ERROR",
		Category:        "telemetry",
		TerminalFailure: false,
		Description:     "Transient network failure during telemetry upload.",
	},
	{
		Code:            "TELEMETRY_STORAGE_FULL",
		Category:        "telemetry",
		TerminalFailure: false,
		Description:     "Local storage limit reached; overflow state exposed.",
	},
}
