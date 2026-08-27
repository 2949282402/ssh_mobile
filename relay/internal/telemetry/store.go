// Telemetry Store interface and MemoryStore implementation.

package telemetry

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// QueryFilter defines filtering criteria for telemetry queries.
type QueryFilter struct {
	TimeRange  string     `json:"timeRange,omitempty"`
	StartTime  time.Time  `json:"startTime,omitempty"`
	EndTime    time.Time  `json:"endTime,omitempty"`
	DeviceID   string     `json:"deviceId,omitempty"`
	TraceID    string     `json:"traceId,omitempty"`
	EventName  string     `json:"eventName,omitempty"`
	Feature    string     `json:"feature,omitempty"`
	Severity   Severity   `json:"severity,omitempty"`
	ErrorCode  string     `json:"errorCode,omitempty"`
	AppVersion string     `json:"appVersion,omitempty"`
	Platform   string     `json:"platform,omitempty"`
	RecordType RecordType `json:"recordType,omitempty"`
	Page       int        `json:"page"`
	PageSize   int        `json:"pageSize"`
}

// OverviewMetrics holds aggregated metrics for the dashboard.
type OverviewMetrics struct {
	TotalEvents              int64                  `json:"totalEvents"`
	TotalDiagnostics         int64                  `json:"totalDiagnostics"`
	RecentActiveDevices      int64                  `json:"recentActiveDevices"`
	ErrorCount               int64                  `json:"errorCount"`
	CriticalErrorCount       int64                  `json:"criticalErrorCount"`
	AffectedDevicesCount     int64                  `json:"affectedDevicesCount"`
	CoreOperationSuccessRate float64                `json:"coreOperationSuccessRate"`
	ErrorFreeSessionRate     float64                `json:"errorFreeSessionRate"`
	EventsTrend              []TelemetryMetricPoint `json:"eventsTrend"`
	ErrorsTrend              []TelemetryMetricPoint `json:"errorsTrend"`
	PipelineHealth           PipelineHealthStats    `json:"pipelineHealth"`
}

type TelemetryMetricPoint struct {
	Timestamp string  `json:"timestamp"`
	Value     float64 `json:"value"`
}

type PipelineHealthStats struct {
	Status                string  `json:"status"` // healthy, degraded, unhealthy
	ServerIngestLatencyMs float64 `json:"serverIngestLatencyMs"`
	ServerIngestErrorRate float64 `json:"serverIngestErrorRate"`
	RedisCacheStatus      string  `json:"redisCacheStatus"`
}

// Store defines persistence operations for telemetry data.
type Store interface {
	// IngestBatch persists valid envelopes and records receipts atomically.
	IngestBatch(ctx context.Context, envelopes []TelemetryEnvelope) ([]IngestRecordResult, error)

	// QueryOverview computes aggregated dashboard metrics.
	QueryOverview(ctx context.Context, filter QueryFilter) (*OverviewMetrics, error)

	// QueryEvents searches raw telemetry records with filters and pagination.
	QueryEvents(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, error)

	// QueryDiagnostics searches diagnostic records with filters and pagination.
	QueryDiagnostics(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, error)

	// GetSettings returns current telemetry configuration.
	GetSettings(ctx context.Context) (*TelemetrySettings, error)

	// SaveSettings persists updated telemetry configuration.
	SaveSettings(ctx context.Context, settings TelemetrySettings) error

	// PurgeRetention purges old raw events based on time cutoff and/or maxRows limit.
	// Receipts in ingest_receipts are NEVER deleted.
	PurgeRetention(ctx context.Context, cutoff time.Time, maxRows int, batchSize int) (int, error)

	// Device credential management
	RegisterDeviceCredential(ctx context.Context, deviceID, secretHash string) error
	GetDeviceCredential(ctx context.Context, deviceID string) (string, error)

	// Close releases store resources.
	Close() error
}

// MemoryStore provides a thread-safe in-memory Store for tests and hermetic execution.
type MemoryStore struct {
	mu          sync.RWMutex
	catalog     *Catalog
	rawEvents   []TelemetryEnvelope
	receipts    map[string]time.Time // eventId -> receivedAt (never purged)
	credentials map[string]string    // deviceId -> secretHash
	settings    TelemetrySettings
}

// NewMemoryStore creates an initialized MemoryStore.
func NewMemoryStore(catalog *Catalog) *MemoryStore {
	if catalog == nil {
		catalog = DefaultCatalog()
	}
	return &MemoryStore{
		catalog:     catalog,
		rawEvents:   make([]TelemetryEnvelope, 0),
		receipts:    make(map[string]time.Time),
		credentials: make(map[string]string),
		settings:    DefaultSettings(),
	}
}

func (m *MemoryStore) IngestBatch(ctx context.Context, envelopes []TelemetryEnvelope) ([]IngestRecordResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	now := time.Now().UTC()
	results := make([]IngestRecordResult, len(envelopes))

	for i, env := range envelopes {
		// 1. Schema & Catalog Validation
		if err := m.catalog.ValidateEnvelope(&env); err != nil {
			results[i] = IngestRecordResult{
				EventID: env.EventID,
				Status:  StatusRejected,
				Reason:  err.Error(),
			}
			continue
		}

		// 2. Check Idempotent Receipt
		if _, exists := m.receipts[env.EventID]; exists {
			results[i] = IngestRecordResult{
				EventID: env.EventID,
				Status:  StatusAlreadySeen,
			}
			continue
		}

		// 3. Set trusted receivedAt
		if env.ReceivedAt.IsZero() {
			env.ReceivedAt = now
		}

		// 4. Atomic Insert of raw event + receipt
		m.rawEvents = append(m.rawEvents, env)
		m.receipts[env.EventID] = env.ReceivedAt

		results[i] = IngestRecordResult{
			EventID: env.EventID,
			Status:  StatusAccepted,
		}
	}

	return results, nil
}

func (m *MemoryStore) matchesFilter(env *TelemetryEnvelope, f *QueryFilter) bool {
	if f.RecordType != "" && env.RecordType != f.RecordType {
		return false
	}
	if f.DeviceID != "" && env.DeviceID != f.DeviceID {
		return false
	}
	if f.TraceID != "" && env.TraceID != f.TraceID {
		return false
	}
	if f.EventName != "" && env.EventName != f.EventName {
		return false
	}
	if f.Feature != "" && env.Feature != f.Feature {
		return false
	}
	if f.Severity != "" && env.Severity != f.Severity {
		return false
	}
	if f.AppVersion != "" && env.AppVersion != f.AppVersion {
		return false
	}
	if f.Platform != "" && env.Platform != f.Platform {
		return false
	}
	if f.ErrorCode != "" {
		if env.Error == nil || env.Error.ErrorCode != f.ErrorCode {
			return false
		}
	}
	if !f.StartTime.IsZero() && env.ReceivedAt.Before(f.StartTime) {
		return false
	}
	if !f.EndTime.IsZero() && env.ReceivedAt.After(f.EndTime) {
		return false
	}
	return true
}

func (m *MemoryStore) QueryEvents(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var filtered []TelemetryEnvelope
	for _, env := range m.rawEvents {
		if m.matchesFilter(&env, &filter) {
			filtered = append(filtered, env)
		}
	}

	total := len(filtered)
	// Sort newest receivedAt first
	sort.Slice(filtered, func(i, j int) bool {
		return filtered[i].ReceivedAt.After(filtered[j].ReceivedAt)
	})

	page := filter.Page
	if page < 1 {
		page = 1
	}
	pageSize := filter.PageSize
	if pageSize < 1 {
		pageSize = 50
	}

	start := (page - 1) * pageSize
	if start >= total {
		return []TelemetryEnvelope{}, total, nil
	}
	end := start + pageSize
	if end > total {
		end = total
	}

	return filtered[start:end], total, nil
}

func (m *MemoryStore) QueryDiagnostics(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, error) {
	filter.RecordType = RecordTypeDiagnostic
	return m.QueryEvents(ctx, filter)
}

func (m *MemoryStore) QueryOverview(ctx context.Context, filter QueryFilter) (*OverviewMetrics, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var totalEvents int64
	var totalDiagnostics int64
	var errorCount int64
	var criticalCount int64

	devicesSet := make(map[string]struct{})
	errorDevicesSet := make(map[string]struct{})
	sessionTotal := make(map[string]struct{})
	sessionErrors := make(map[string]struct{})

	var coreOperationsTotal int64
	var coreOperationsSuccess int64

	hourlyEvents := make(map[string]float64)
	hourlyErrors := make(map[string]float64)

	for _, env := range m.rawEvents {
		if !filter.StartTime.IsZero() && env.ReceivedAt.Before(filter.StartTime) {
			continue
		}
		if !filter.EndTime.IsZero() && env.ReceivedAt.After(filter.EndTime) {
			continue
		}

		devicesSet[env.DeviceID] = struct{}{}

		if env.RecordType == RecordTypeAnalytics {
			totalEvents++
		} else if env.RecordType == RecordTypeDiagnostic {
			totalDiagnostics++
		}

		if env.Severity == SeverityError || env.Severity == SeverityCritical {
			errorCount++
			errorDevicesSet[env.DeviceID] = struct{}{}
			sessionErrors[env.SessionID] = struct{}{}
		}
		if env.Severity == SeverityCritical {
			criticalCount++
		}

		sessionTotal[env.SessionID] = struct{}{}

		// Core operations (SSH/SFTP sessions)
		if strings.HasPrefix(env.EventName, "ssh.session.") || strings.HasPrefix(env.EventName, "sftp.transfer.") {
			coreOperationsTotal++
			if env.EventName == "ssh.session.terminated" || env.EventName == "sftp.transfer.completed" {
				coreOperationsSuccess++
			}
		}

		hourKey := env.ReceivedAt.UTC().Format("2006-01-02T15:00:00Z")
		hourlyEvents[hourKey]++
		if env.Severity == SeverityError || env.Severity == SeverityCritical {
			hourlyErrors[hourKey]++
		}
	}

	var coreSuccessRate float64 = 1.0
	if coreOperationsTotal > 0 {
		coreSuccessRate = float64(coreOperationsSuccess) / float64(coreOperationsTotal)
	}

	var errorFreeSessionRate float64 = 1.0
	if len(sessionTotal) > 0 {
		errorFreeSessions := len(sessionTotal) - len(sessionErrors)
		if errorFreeSessions < 0 {
			errorFreeSessions = 0
		}
		errorFreeSessionRate = float64(errorFreeSessions) / float64(len(sessionTotal))
	}

	var eventsTrend []TelemetryMetricPoint
	for ts, val := range hourlyEvents {
		eventsTrend = append(eventsTrend, TelemetryMetricPoint{Timestamp: ts, Value: val})
	}
	sort.Slice(eventsTrend, func(i, j int) bool {
		return eventsTrend[i].Timestamp < eventsTrend[j].Timestamp
	})

	var errorsTrend []TelemetryMetricPoint
	for ts, val := range hourlyErrors {
		errorsTrend = append(errorsTrend, TelemetryMetricPoint{Timestamp: ts, Value: val})
	}
	sort.Slice(errorsTrend, func(i, j int) bool {
		return errorsTrend[i].Timestamp < errorsTrend[j].Timestamp
	})

	return &OverviewMetrics{
		TotalEvents:              totalEvents,
		TotalDiagnostics:         totalDiagnostics,
		RecentActiveDevices:      int64(len(devicesSet)),
		ErrorCount:               errorCount,
		CriticalErrorCount:       criticalCount,
		AffectedDevicesCount:     int64(len(errorDevicesSet)),
		CoreOperationSuccessRate: coreSuccessRate,
		ErrorFreeSessionRate:     errorFreeSessionRate,
		EventsTrend:              eventsTrend,
		ErrorsTrend:              errorsTrend,
		PipelineHealth: PipelineHealthStats{
			Status:                "degraded",
			ServerIngestLatencyMs: 1.5,
			ServerIngestErrorRate: 0.0,
			RedisCacheStatus:      "disabled",
		},
	}, nil
}

func (m *MemoryStore) GetSettings(ctx context.Context) (*TelemetrySettings, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	s := m.settings
	return &s, nil
}

func (m *MemoryStore) SaveSettings(ctx context.Context, settings TelemetrySettings) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	SanitizeSettings(&settings)
	settings.UpdatedAt = time.Now().UTC()
	m.settings = settings
	return nil
}

func (m *MemoryStore) PurgeRetention(ctx context.Context, cutoff time.Time, maxRows int, batchSize int) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	var retained []TelemetryEnvelope
	deletedCount := 0

	// 1. Time-based purge
	for _, env := range m.rawEvents {
		if !cutoff.IsZero() && env.ReceivedAt.Before(cutoff) {
			deletedCount++
			continue
		}
		retained = append(retained, env)
	}

	// 2. Max rows purge: keep newest maxRows
	if maxRows > 0 && len(retained) > maxRows {
		// Sort oldest to newest
		sort.Slice(retained, func(i, j int) bool {
			return retained[i].ReceivedAt.Before(retained[j].ReceivedAt)
		})
		excess := len(retained) - maxRows
		deletedCount += excess
		retained = retained[excess:]
	}

	m.rawEvents = retained
	return deletedCount, nil
}

func (m *MemoryStore) RegisterDeviceCredential(ctx context.Context, deviceID, secretHash string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if strings.TrimSpace(deviceID) == "" || strings.TrimSpace(secretHash) == "" {
		return fmt.Errorf("invalid deviceId or secretHash")
	}
	m.credentials[deviceID] = secretHash
	return nil
}

func (m *MemoryStore) GetDeviceCredential(ctx context.Context, deviceID string) (string, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	hash, ok := m.credentials[deviceID]
	if !ok {
		return "", fmt.Errorf("device credential not found")
	}
	return hash, nil
}

func (m *MemoryStore) Close() error {
	return nil
}
