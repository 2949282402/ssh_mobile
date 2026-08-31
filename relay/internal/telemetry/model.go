// Telemetry data types, envelopes, and status models.

package telemetry

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"
)

const (
	// MinPolicyVersion and MaxPolicyVersion are the cross-platform bounds for
	// the monotonic policy concurrency token. Keep these values in sync with
	// contracts/telemetry/policy.schema.json and the Dart/TypeScript clients.
	MinPolicyVersion = 1
	MaxPolicyVersion = 2147483647
)

// ErrInvalidPolicyVersion identifies an incoming policy version outside the
// shared contract range. It is intentionally distinct from
// ErrPolicyVersionConflict: an invalid value is a malformed request, not a
// stale but otherwise valid writer.
var ErrInvalidPolicyVersion = errors.New("invalid telemetry policy version")

// IsValidPolicyVersion reports whether version is within the shared contract
// range. Policy versions are never clamped because they provide concurrency
// and ordering semantics.
func IsValidPolicyVersion(version int) bool {
	return version >= MinPolicyVersion && version <= MaxPolicyVersion
}

// ValidatePolicyVersion returns a typed error for an out-of-range version.
func ValidatePolicyVersion(version int) error {
	if IsValidPolicyVersion(version) {
		return nil
	}
	return fmt.Errorf("%w: must be between %d and %d", ErrInvalidPolicyVersion, MinPolicyVersion, MaxPolicyVersion)
}

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

// DeviceCredential is the durable telemetry credential state. Enrollment
// generation comes from Relay and lets bearer tokens be invalidated when the
// Relay enrollment is revoked or replaced.
type DeviceCredential struct {
	SecretHash           string
	EnrollmentGeneration int64
	RevokedAt            *time.Time
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

const (
	maxTelemetryBatchThreshold = 1000
	maxTelemetryInterval       = 3600
	maxTelemetryLocalRecords   = 1000000
	maxTelemetryRetentionDays  = 3650
	maxTelemetryRetentionRows  = 100000000
	maxTelemetryRedisRecords   = 10000
)

var allowedTelemetryTriggers = map[string]struct{}{
	"highPriorityError":        {},
	"appBackground":            {},
	"networkRecovered":         {},
	"appForegroundWithBacklog": {},
}

// SanitizeSettings normalizes non-version configuration values to the safe
// bounds shared by the JSON, Dart, TypeScript, and relay contracts. Policy
// versions are deliberately not changed here: callers must validate them with
// ValidatePolicyVersion before persistence so ordering semantics are never
// silently rewritten.
func SanitizeSettings(s *TelemetrySettings) {
	if s == nil {
		return
	}
	if s.Policy.BatchSizeThreshold < 1 {
		s.Policy.BatchSizeThreshold = 50
	} else if s.Policy.BatchSizeThreshold > maxTelemetryBatchThreshold {
		s.Policy.BatchSizeThreshold = maxTelemetryBatchThreshold
	}
	if s.Policy.TimeIntervalSeconds < 5 {
		s.Policy.TimeIntervalSeconds = 60
	} else if s.Policy.TimeIntervalSeconds > maxTelemetryInterval {
		s.Policy.TimeIntervalSeconds = maxTelemetryInterval
	}
	if s.Policy.MaxBatchSize < 1 {
		s.Policy.MaxBatchSize = 100
	} else if s.Policy.MaxBatchSize > MaxIngestBatchSize {
		s.Policy.MaxBatchSize = MaxIngestBatchSize
	}
	if s.Policy.ClientMaxLocalRecords < 100 {
		s.Policy.ClientMaxLocalRecords = 10000
	} else if s.Policy.ClientMaxLocalRecords > maxTelemetryLocalRecords {
		s.Policy.ClientMaxLocalRecords = maxTelemetryLocalRecords
	}
	triggers := make([]string, 0, len(s.Policy.SpecialTriggers))
	seen := make(map[string]struct{}, len(s.Policy.SpecialTriggers))
	for _, trigger := range s.Policy.SpecialTriggers {
		if _, ok := allowedTelemetryTriggers[trigger]; !ok {
			continue
		}
		if _, ok := seen[trigger]; ok {
			continue
		}
		seen[trigger] = struct{}{}
		triggers = append(triggers, trigger)
	}
	if len(triggers) == 0 {
		for trigger := range allowedTelemetryTriggers {
			triggers = append(triggers, trigger)
		}
		sort.Strings(triggers)
	}
	s.Policy.SpecialTriggers = triggers
	if s.RetentionDays < 1 {
		s.RetentionDays = 30
	} else if s.RetentionDays > maxTelemetryRetentionDays {
		s.RetentionDays = maxTelemetryRetentionDays
	}
	if s.RetentionMaxRows < 1000 {
		s.RetentionMaxRows = 500000
	} else if s.RetentionMaxRows > maxTelemetryRetentionRows {
		s.RetentionMaxRows = maxTelemetryRetentionRows
	}
	if s.RedisMaxRecords < 10 {
		s.RedisMaxRecords = 1000
	} else if s.RedisMaxRecords > maxTelemetryRedisRecords {
		s.RedisMaxRecords = maxTelemetryRedisRecords
	}
	if s.UpdatedAt.IsZero() {
		s.UpdatedAt = time.Now().UTC()
	}
}
