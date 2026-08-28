// Telemetry data types, envelopes, and status models.

package telemetry

import (
	"context"
	"time"
)

// TelemetryEnrollmentRequest is the public request used to bootstrap a
// telemetry credential from the existing Relay device identity. All proof
// fields are request-only and are never persisted by the telemetry service.
type TelemetryEnrollmentRequest struct {
	DeviceID        string `json:"deviceId"`
	RelayCredential string `json:"relayCredential"`
	PublicKey       string `json:"publicKey"`
	Timestamp       int64  `json:"timestamp"`
	Nonce           string `json:"nonce"`
	Signature       string `json:"signature"`
}

// TelemetryEnrollmentResponse contains the one-time plaintext secret. The
// caller must persist it in platform secure storage immediately; the service
// only retains its derived hash.
type TelemetryEnrollmentResponse struct {
	DeviceID string `json:"deviceId"`
	Secret   string `json:"secret"`
}

// DeviceAttestationRequest is the proof forwarded by Admin to Relay. Keeping
// this capability in the telemetry package avoids a direct Relay dependency.
type DeviceAttestationRequest struct {
	DeviceID        string
	RelayCredential string
	PublicKey       string
	Timestamp       int64
	Nonce           string
	Signature       string
	// TranscriptPath binds the proof to the public operation. Empty values
	// default to the initial enrollment path for compatibility with callers.
	TranscriptPath string
}

// DeviceAttestation is the non-secret result of a successful Relay proof.
type DeviceAttestation struct {
	DeviceID             string
	EnrollmentGeneration int64
	ProtocolVersion      uint32
}

// DeviceAttestor validates an existing Relay enrollment without giving
// telemetry access to Relay storage or credential-signing keys.
type DeviceAttestor interface {
	ValidateDeviceCredential(context.Context, DeviceAttestationRequest) (DeviceAttestation, error)
}

type RecordType string

const (
	RecordTypeAnalytics  RecordType = "analytics"
	RecordTypeDiagnostic RecordType = "diagnostic"
)

type Severity string

const (
	SeverityInfo     Severity = "info"
	SeverityWarn     Severity = "warn"
	SeverityError    Severity = "error"
	SeverityCritical Severity = "critical"
)

type IngestStatus string

const (
	StatusAccepted    IngestStatus = "accepted"
	StatusAlreadySeen IngestStatus = "already_seen"
	StatusRejected    IngestStatus = "rejected"
)

type SyncState string

const (
	SyncStatePending  SyncState = "pending"
	SyncStateSynced   SyncState = "synced"
	SyncStateRejected SyncState = "rejected"
)

// TelemetryError represents structured error detail on a record.
type TelemetryError struct {
	ErrorCode       string `json:"errorCode"`
	Category        string `json:"category"`
	TerminalFailure bool   `json:"terminalFailure"`
	Message         string `json:"message,omitempty"`
	StackTrace      string `json:"stackTrace,omitempty"`
}

// TelemetryEnvelope represents the standard payload shape received from clients.
type TelemetryEnvelope struct {
	EventID        string          `json:"eventId"`
	RecordType     RecordType      `json:"recordType"`
	EventName      string          `json:"eventName"`
	EventVersion   int             `json:"eventVersion"`
	DeviceID       string          `json:"deviceId"`
	SessionID      string          `json:"sessionId"`
	TraceID        string          `json:"traceId"`
	OccurredAt     time.Time       `json:"occurredAt"`
	ReceivedAt     time.Time       `json:"receivedAt,omitempty"`
	Feature        string          `json:"feature"`
	Severity       Severity        `json:"severity"`
	AppVersion     string          `json:"appVersion"`
	BuildNumber    string          `json:"buildNumber"`
	Platform       string          `json:"platform"`
	ReleaseChannel string          `json:"releaseChannel,omitempty"`
	Properties     map[string]any  `json:"properties,omitempty"`
	Error          *TelemetryError `json:"error,omitempty"`
}

// IngestRecordResult represents the acknowledgment for a single event in a batch.
type IngestRecordResult struct {
	EventID string       `json:"eventId"`
	Status  IngestStatus `json:"status"`
	Reason  string       `json:"reason,omitempty"`
}

// IngestBatchRequest represents the batch upload body from clients.
type IngestBatchRequest struct {
	Records []TelemetryEnvelope `json:"records"`
}

// IngestBatchResponse represents the response containing per-record ACK.
type IngestBatchResponse struct {
	Results []IngestRecordResult `json:"results"`
}

// TelemetryUploadPolicy represents the configuration governing client upload behaviors.
type TelemetryUploadPolicy struct {
	UploadEnabled         bool     `json:"uploadEnabled"`
	BatchSizeThreshold    int      `json:"batchSizeThreshold"`
	TimeIntervalSeconds   int      `json:"timeIntervalSeconds"`
	MaxBatchSize          int      `json:"maxBatchSize"`
	ClientMaxLocalRecords int      `json:"clientMaxLocalRecords"`
	SpecialTriggers       []string `json:"specialTriggers"`
	PolicyVersion         int      `json:"policyVersion"`
}

// DefaultUploadPolicy returns safe default settings for client telemetry upload.
func DefaultUploadPolicy() TelemetryUploadPolicy {
	return TelemetryUploadPolicy{
		UploadEnabled:         true,
		BatchSizeThreshold:    50,
		TimeIntervalSeconds:   60,
		MaxBatchSize:          100,
		ClientMaxLocalRecords: 10000,
		SpecialTriggers: []string{
			"highPriorityError",
			"appBackground",
			"networkRecovered",
			"appForegroundWithBacklog",
		},
		PolicyVersion: 1,
	}
}

// TelemetrySettings represents combined settings managed in Admin.
type TelemetrySettings struct {
	Policy               TelemetryUploadPolicy `json:"policy"`
	RetentionDays        int                   `json:"retentionDays"`
	RetentionMaxRows     int                   `json:"retentionMaxRows"`
	RetentionTimeEnabled bool                  `json:"retentionTimeEnabled"`
	RetentionRowsEnabled bool                  `json:"retentionRowsEnabled"`
	RedisCacheEnabled    bool                  `json:"redisCacheEnabled"`
	RedisMaxRecords      int                   `json:"redisMaxRecords"`
	UpdatedAt            time.Time             `json:"updatedAt"`
}

// DefaultSettings returns safe server defaults for telemetry.
func DefaultSettings() TelemetrySettings {
	return TelemetrySettings{
		Policy:               DefaultUploadPolicy(),
		RetentionDays:        30,
		RetentionMaxRows:     500000,
		RetentionTimeEnabled: true,
		RetentionRowsEnabled: true,
		RedisCacheEnabled:    true,
		RedisMaxRecords:      1000,
		UpdatedAt:            time.Now().UTC(),
	}
}

// SanitizeSettings validates and clamps configuration values to safe bounds.
func SanitizeSettings(s *TelemetrySettings) {
	if s.Policy.BatchSizeThreshold < 1 {
		s.Policy.BatchSizeThreshold = 50
	}
	if s.Policy.TimeIntervalSeconds < 5 {
		s.Policy.TimeIntervalSeconds = 60
	}
	if s.Policy.MaxBatchSize < 1 {
		s.Policy.MaxBatchSize = 100
	}
	if s.Policy.ClientMaxLocalRecords < 100 {
		s.Policy.ClientMaxLocalRecords = 10000
	}
	if s.RetentionDays < 1 {
		s.RetentionDays = 30
	}
	if s.RetentionMaxRows < 1000 {
		s.RetentionMaxRows = 500000
	}
	if s.RedisMaxRecords < 10 {
		s.RedisMaxRecords = 1000
	}
	if s.UpdatedAt.IsZero() {
		s.UpdatedAt = time.Now().UTC()
	}
}
