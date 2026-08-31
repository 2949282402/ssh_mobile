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
// operation when a device already has a telemetry credential.
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

	// Device credential management. RegisterDeviceCredential is reserved for
	// explicit proof-bound rotation; callers must not expose it as an admin API.
	RegisterDeviceCredential(ctx context.Context, deviceID, secretHash string) error
	GetDeviceCredential(ctx context.Context, deviceID string) (string, error)

	// Close releases store resources.
	Close() error
}

// MemoryStore provides a thread-safe in-memory Store for tests and hermetic execution.
type MemoryStore struct {
	mu                  sync.RWMutex
	catalog             *Catalog
	rawEvents           []TelemetryEnvelope
	receipts            map[string]time.Time // eventId -> receivedAt (never purged)
	receiptDevices      map[string]string    // eventId -> deviceId (never purged)
	credentials         map[string]string    // deviceId -> secretHash
	credentialMeta      map[string]DeviceCredential
	settings            TelemetrySettings
	settingsInitialized bool
	redisCache          RedisCache
}

const telemetryReceiptOwnershipConflictReason = "event id ownership conflict"

// telemetryReceiptIdentity performs only the bounded identity checks needed to
// look up an existing receipt before full catalog/schema validation. Invalid
// identities are left for the normal validator so callers still receive the
// precise schema rejection.
func telemetryReceiptIdentity(env TelemetryEnvelope) (eventID, deviceID string, ok bool) {
	if strings.TrimSpace(env.EventID) == "" || len([]byte(env.EventID)) > 64 {
		return "", "", false
	}
	if strings.TrimSpace(env.DeviceID) == "" || len([]byte(env.DeviceID)) > 128 {
		return "", "", false
	}
	return env.EventID, env.DeviceID, true
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
		catalog:        catalog,
		rawEvents:      make([]TelemetryEnvelope, 0),
		receipts:       make(map[string]time.Time),
		receiptDevices: make(map[string]string),
		credentials:    make(map[string]string),
		credentialMeta: make(map[string]DeviceCredential),
		settings:       DefaultSettings(),
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
	pending := make(map[string]string, len(envelopes))
	receiptOwners := make(map[string]string, len(envelopes))
	for _, env := range envelopes {
		eventID, _, ok := telemetryReceiptIdentity(env)
		if !ok {
			continue
		}
		if owner, exists := m.receiptDevices[eventID]; exists {
			receiptOwners[eventID] = owner
			continue
		}
		if _, exists := m.receipts[eventID]; exists {
			// Compatibility for a store value created before receiptDevices was
			// introduced: recover ownership from the retained raw row when one
			// is still available, otherwise fail closed as an ownership conflict.
			owner := ""
			for i := len(m.rawEvents) - 1; i >= 0; i-- {
				if m.rawEvents[i].EventID == eventID {
					owner = m.rawEvents[i].DeviceID
					break
				}
			}
			receiptOwners[eventID] = owner
		}
	}

	for i, env := range envelopes {
		// 1. Receipt lookup precedes schema/catalog validation. A durable
		// receipt is authoritative even when the current catalog no longer
		// accepts the historical payload.
		if owner, exists := receiptOwners[env.EventID]; exists {
			if owner == env.DeviceID {
				results[i] = IngestRecordResult{
					EventID: env.EventID,
					Status:  StatusAlreadySeen,
				}
			} else {
				results[i] = IngestRecordResult{
					EventID: env.EventID,
					Status:  StatusRejected,
					Reason:  telemetryReceiptOwnershipConflictReason,
				}
			}
			continue
		}

		// 2. Schema & Catalog Validation
		if err := m.catalog.ValidateEnvelopeAt(&env, now); err != nil {
			results[i] = IngestRecordResult{
				EventID: env.EventID,
				Status:  StatusRejected,
				Reason:  err.Error(),
			}
			continue
		}

		// 3. Check duplicate identities introduced within this batch.
		if _, exists := m.receipts[env.EventID]; exists {
			results[i] = IngestRecordResult{
				EventID: env.EventID,
				Status:  StatusAlreadySeen,
			}
			continue
		}
		if existingDevice, exists := pending[env.EventID]; exists {
			results[i] = IngestRecordResult{EventID: env.EventID}
			if existingDevice == env.DeviceID {
				results[i].Status = StatusAlreadySeen
			} else {
				results[i].Status = StatusRejected
				results[i].Reason = telemetryReceiptOwnershipConflictReason
			}
			continue
		}

		// Service.IngestBatch stamps ReceivedAt before reaching the store. Keep
		// that authoritative value; only legacy direct Store callers with a zero
		// value receive a compatibility timestamp.
		if env.ReceivedAt.IsZero() {
			env.ReceivedAt = now
		}
		accepted = append(accepted, env)
		pending[env.EventID] = env.DeviceID

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
		if m.receiptDevices == nil {
			m.receiptDevices = make(map[string]string)
		}
		m.receiptDevices[env.EventID] = env.DeviceID
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
	// Sort newest receivedAt first, then use the exact event ID as a stable
	// cursor tie-breaker. Service.IngestBatch stamps one timestamp for a whole
	// request, so receivedAt alone would make page boundaries nondeterministic.
	sort.Slice(filtered, func(i, j int) bool {
		if filtered[i].ReceivedAt.Equal(filtered[j].ReceivedAt) {
			return filtered[i].EventID > filtered[j].EventID
		}
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
	if m.settingsInitialized && settings.Policy.PolicyVersion <= m.settings.Policy.PolicyVersion {
		return fmt.Errorf("%w: current=%d incoming=%d", ErrPolicyVersionConflict, m.settings.Policy.PolicyVersion, settings.Policy.PolicyVersion)
	}
	settings.UpdatedAt = time.Now().UTC()
	m.settings = settings
	m.settingsInitialized = true
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
		// Sort oldest to newest with the same deterministic event-id tie-breaker
		// used by QueryEvents.
		sort.Slice(retained, func(i, j int) bool {
			if retained[i].ReceivedAt.Equal(retained[j].ReceivedAt) {
				return retained[i].EventID < retained[j].EventID
			}
			return retained[i].ReceivedAt.Before(retained[j].ReceivedAt)
		})
		excess := len(retained) - maxRows
		deletedCount += excess
		retained = retained[excess:]
	}

	m.rawEvents = retained
	return deletedCount, nil
}

func (m *MemoryStore) Close() error {
	return nil
}
