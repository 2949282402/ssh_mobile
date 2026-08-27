// Telemetry Store interface and MemoryStore implementation.

package telemetry

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// ErrDeviceCredentialAlreadyExists is returned by the create-only enrollment
// operation when a device already has a telemetry credential. Existing admin
// registration remains an explicit upsert for backward compatibility.
var ErrDeviceCredentialAlreadyExists = errors.New("device telemetry credential already exists")

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
	Latency                  LatencyStats           `json:"latency"`
	PipelineHealth           PipelineHealthStats    `json:"pipelineHealth"`
}

// LatencyStats holds completion latency percentiles (in milliseconds) for
// terminal operations in the queried time range. Samples == 0 means no latency
// data is available.
type LatencyStats struct {
	P50Ms   float64 `json:"p50Ms"`
	P95Ms   float64 `json:"p95Ms"`
	P99Ms   float64 `json:"p99Ms"`
	Samples int64   `json:"samples"`
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
	redisCache  RedisCache
}

// CreateDeviceCredential persists a credential hash exactly once. It is
// separate from RegisterDeviceCredential because public device enrollment must
// never silently rotate a credential after a replay or lost response.
func (m *MemoryStore) CreateDeviceCredential(ctx context.Context, deviceID, secretHash string) error {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return err
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if strings.TrimSpace(deviceID) == "" || strings.TrimSpace(secretHash) == "" {
		return fmt.Errorf("invalid deviceId or secretHash")
	}
	if _, exists := m.credentials[deviceID]; exists {
		return ErrDeviceCredentialAlreadyExists
	}
	m.credentials[deviceID] = secretHash
	return nil
}

// SetRedisCache wires a cache used for pipeline health probing in QueryOverview.
func (m *MemoryStore) SetRedisCache(cache RedisCache) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.redisCache = cache
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

	var succeededCount int64
	var failedCount int64
	var latencyValues []float64

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

		// Terminal outcome classification: successRate = succeeded / (succeeded + failed).
		// In-progress events (started/request) count toward neither denominator.
		switch {
		case isTerminalFailureEvent(&env):
			failedCount++
		case isTerminalSuccessEvent(&env):
			succeededCount++
		}

		// Latency samples from terminal successful operations carrying duration_ms/latency_ms.
		if d, ok := extractLatencyFromProps(env.Properties); ok {
			latencyValues = append(latencyValues, d)
		}

		hourKey := env.ReceivedAt.UTC().Format("2006-01-02T15:00:00Z")
		hourlyEvents[hourKey]++
		if env.Severity == SeverityError || env.Severity == SeverityCritical {
			hourlyErrors[hourKey]++
		}
	}

	coreSuccessRate := 1.0
	if terminalTotal := succeededCount + failedCount; terminalTotal > 0 {
		coreSuccessRate = float64(succeededCount) / float64(terminalTotal)
	}

	latency := latencyStats(latencyValues)

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

	// Live service health for the in-memory store: MySQL is not backed by a real
	// database so only the cache status is reported dynamically.
	redisStatus := redisHealthStatus(ctx, m.redisCache)
	status := "healthy"
	if redisStatus != "active" {
		status = "degraded"
	}

	var ingestErrorRate float64
	if terminalTotal := succeededCount + failedCount; terminalTotal > 0 {
		ingestErrorRate = float64(failedCount) / float64(terminalTotal)
	}

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
		Latency:                  latency,
		PipelineHealth: PipelineHealthStats{
			Status:                status,
			ServerIngestLatencyMs: latency.P50Ms,
			ServerIngestErrorRate: ingestErrorRate,
			RedisCacheStatus:      redisStatus,
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
		return "", fmt.Errorf("%w: %s", ErrDeviceCredentialNotFound, deviceID)
	}
	return hash, nil
}

func (m *MemoryStore) Close() error {
	return nil
}
