// Telemetry data types, envelopes, and status models.

package telemetry

import (
	"time"
)

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
	EventID      string          `json:"eventId"`
	RecordType   RecordType      `json:"recordType"`
	EventName    string          `json:"eventName"`
	EventVersion int             `json:"eventVersion"`
	DeviceID     string          `json:"deviceId"`
	SessionID    string          `json:"sessionId"`
	TraceID      string          `json:"traceId"`
	OccurredAt   time.Time       `json:"occurredAt"`
	ReceivedAt   time.Time       `json:"receivedAt,omitempty"`
	Feature      string          `json:"feature"`
	Severity     Severity        `json:"severity"`
	AppVersion   string          `json:"appVersion"`
	BuildNumber  string          `json:"buildNumber"`
	Platform     string          `json:"platform"`
	Properties   map[string]any  `json:"properties,omitempty"`
	Error        *TelemetryError `json:"error,omitempty"`
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
