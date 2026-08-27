// Telemetry Service orchestrating Store, Catalog, Cache, and Retention.

package telemetry

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"sync"
	"time"
)

type Service struct {
	store      Store
	catalog    *Catalog
	redisCache RedisCache
	tokenKey   []byte
	mu         sync.RWMutex
}

func NewService(store Store, catalog *Catalog, redisCache RedisCache) *Service {
	if catalog == nil {
		catalog = DefaultCatalog()
	}
	if redisCache == nil {
		redisCache = &NoopRedisCache{}
	}
	return &Service{
		store:      store,
		catalog:    catalog,
		redisCache: redisCache,
		tokenKey:   []byte("telemetry-device-auth-secret-v1"),
	}
}

func (s *Service) IngestBatch(ctx context.Context, envelopes []TelemetryEnvelope) ([]IngestRecordResult, error) {
	results, err := s.store.IngestBatch(ctx, envelopes)
	if err != nil {
		return nil, err
	}

	// Hot cache update for accepted diagnostics
	settings, _ := s.store.GetSettings(ctx)
	cacheEnabled := settings == nil || settings.RedisCacheEnabled
	maxRecords := 1000
	if settings != nil && settings.RedisMaxRecords > 0 {
		maxRecords = settings.RedisMaxRecords
	}

	if cacheEnabled {
		for i, res := range results {
			if res.Status == StatusAccepted && envelopes[i].RecordType == RecordTypeDiagnostic {
				// Best-effort push to Redis cache
				_ = s.redisCache.PushDiagnostic(ctx, envelopes[i], maxRecords)
			}
		}
	}

	return results, nil
}

func (s *Service) QueryOverview(ctx context.Context, filter QueryFilter) (*OverviewMetrics, error) {
	return s.store.QueryOverview(ctx, filter)
}

func (s *Service) QueryEvents(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, error) {
	return s.store.QueryEvents(ctx, filter)
}

func (s *Service) QueryDiagnostics(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, string, error) {
	settings, _ := s.store.GetSettings(ctx)
	canUseRedis := (settings == nil || settings.RedisCacheEnabled) &&
		filter.DeviceID == "" &&
		filter.TraceID == "" &&
		filter.EventName == "" &&
		filter.Feature == "" &&
		filter.ErrorCode == "" &&
		filter.Severity == "" &&
		filter.Platform == "" &&
		filter.AppVersion == "" &&
		filter.Page <= 1

	if canUseRedis {
		limit := filter.PageSize
		if limit <= 0 {
			limit = 50
		}
		cached, err := s.redisCache.GetRecentDiagnostics(ctx, limit)
		if err == nil && len(cached) > 0 {
			return cached, len(cached), "redis_cache", nil
		}
	}

	// Fallback to MySQL Store
	records, total, err := s.store.QueryDiagnostics(ctx, filter)
	if err != nil {
		return nil, 0, "mysql", err
	}
	return records, total, "mysql", nil
}

func (s *Service) GetPolicy(ctx context.Context) (*TelemetryUploadPolicy, error) {
	settings, err := s.store.GetSettings(ctx)
	if err != nil {
		return nil, err
	}
	return &settings.Policy, nil
}

func (s *Service) GetSettings(ctx context.Context) (*TelemetrySettings, error) {
	return s.store.GetSettings(ctx)
}

func (s *Service) UpdateSettings(ctx context.Context, settings TelemetrySettings) error {
	return s.store.SaveSettings(ctx, settings)
}

// GenerateDeviceToken creates a scoped authentication token for a device.
func (s *Service) GenerateDeviceToken(deviceID string) string {
	mac := hmac.New(sha256.New, s.tokenKey)
	mac.Write([]byte("telemetry:auth:" + deviceID))
	return hex.EncodeToString(mac.Sum(nil))
}

// VerifyDeviceToken checks if the bearer token matches the device identity.
func (s *Service) VerifyDeviceToken(deviceID, token string) bool {
	if strings.TrimSpace(deviceID) == "" || strings.TrimSpace(token) == "" {
		return false
	}
	expected := s.GenerateDeviceToken(deviceID)
	return hmac.Equal([]byte(expected), []byte(token))
}

// PurgeRetention executes one retention cycle.
func (s *Service) PurgeRetention(ctx context.Context) (int, error) {
	settings, err := s.store.GetSettings(ctx)
	if err != nil {
		return 0, err
	}

	var cutoff time.Time
	if settings.RetentionTimeEnabled && settings.RetentionDays > 0 {
		cutoff = time.Now().UTC().Add(-time.Duration(settings.RetentionDays) * 24 * time.Hour)
	}

	maxRows := 0
	if settings.RetentionRowsEnabled && settings.RetentionMaxRows > 0 {
		maxRows = settings.RetentionMaxRows
	}

	if cutoff.IsZero() && maxRows == 0 {
		return 0, nil
	}

	return s.store.PurgeRetention(ctx, cutoff, maxRows, 500)
}
