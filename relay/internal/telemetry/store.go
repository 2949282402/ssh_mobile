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
	TimeRange      string     `json:"timeRange,omitempty"`
	StartTime      time.Time  `json:"startTime,omitempty"`
	EndTime        time.Time  `json:"endTime,omitempty"`
	DeviceID       string     `json:"deviceId,omitempty"`
	TraceID        string     `json:"traceId,omitempty"`
	EventName      string     `json:"eventName,omitempty"`
	Feature        string     `json:"feature,omitempty"`
	Severity       Severity   `json:"severity,omitempty"`
	ErrorCode      string     `json:"errorCode,omitempty"`
	AppVersion     string     `json:"appVersion,omitempty"`
	Platform       string     `json:"platform,omitempty"`
	ReleaseChannel string     `json:"releaseChannel,omitempty"`
	RecordType     RecordType `json:"recordType,omitempty"`
	Page           int        `json:"page"`
	PageSize       int        `json:"pageSize"`
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
	if len(envelopes) > MaxIngestBatchSize {
		return nil, fmt.Errorf("%w: maximum is %d records", ErrIngestBatchTooLarge, MaxIngestBatchSize)
	}
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}

	now := time.Now().UTC()
	results := make([]IngestRecordResult, len(envelopes))
	accepted := make([]TelemetryEnvelope, 0, len(envelopes))
	pending := make(map[string]struct{}, len(envelopes))

	for i, env := range envelopes {
		// 1. Schema & Catalog Validation
		if err := m.catalog.ValidateEnvelopeAt(&env, now); err != nil {
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
		if _, exists := pending[env.EventID]; exists {
			results[i] = IngestRecordResult{
				EventID: env.EventID,
				Status:  StatusAlreadySeen,
			}
			continue
		}

		// 3. Set trusted receivedAt. The in-memory implementation mirrors
		// MySQL: every newly accepted row receives the current server time,
		// regardless of any client-supplied value.
		env.ReceivedAt = now
		accepted = append(accepted, env)
		pending[env.EventID] = struct{}{}

		results[i] = IngestRecordResult{
			EventID: env.EventID,
			Status:  StatusAccepted,
		}
	}
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}
	// Commit accepted rows only after validation and the final context check so
	// cancellation cannot leave a partial in-memory batch behind the same
	// transactional contract enforced by MySQL.
	m.rawEvents = append(m.rawEvents, accepted...)
	for _, env := range accepted {
		m.receipts[env.EventID] = env.ReceivedAt
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
	if f.ReleaseChannel != "" && env.ReleaseChannel != f.ReleaseChannel {
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
