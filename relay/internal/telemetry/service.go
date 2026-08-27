// Telemetry Service orchestrating Store, Catalog, Cache, and Retention.

package telemetry

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Service struct {
	store      Store
	catalog    *Catalog
	redisCache RedisCache
	tokenKey   []byte
	authSecret string
	mu         sync.RWMutex
}

func NewService(store Store, catalog *Catalog, redisCache RedisCache) *Service {
	return NewServiceWithSecret(store, catalog, redisCache, "")
}

func NewServiceWithSecret(store Store, catalog *Catalog, redisCache RedisCache, authSecret string) *Service {
	if catalog == nil {
		catalog = DefaultCatalog()
	}
	if redisCache == nil {
		redisCache = &NoopRedisCache{}
	}
	key := []byte("telemetry-device-auth-secret-v1")
	trimmedSecret := strings.TrimSpace(authSecret)
	if len(trimmedSecret) >= 16 {
		key = []byte(trimmedSecret)
	}
	return &Service{
		store:      store,
		catalog:    catalog,
		redisCache: redisCache,
		tokenKey:   key,
		authSecret: trimmedSecret,
	}
}

func hashSecret(secret string) string {
	h := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(h[:])
}

// AuthenticateDevice verifies credentials if configured and issues an expiring token.
func (s *Service) AuthenticateDevice(ctx context.Context, deviceID, secret string) (string, int64, error) {
	if strings.TrimSpace(deviceID) == "" {
		return "", 0, fmt.Errorf("missing deviceId")
	}

	// 1. Check if per-device credential exists in store
	credHash, err := s.store.GetDeviceCredential(ctx, deviceID)
	if err == nil && credHash != "" {
		if hashSecret(secret) != credHash && secret != credHash {
			return "", 0, fmt.Errorf("invalid device credential")
		}
	} else if s.authSecret != "" {
		// 2. If server has global auth secret configured, verify secret matches
		if secret != s.authSecret && hashSecret(secret) != hashSecret(s.authSecret) {
			return "", 0, fmt.Errorf("invalid auth secret")
		}
	}

	token, exp := s.GenerateDeviceToken(deviceID, 30*24*time.Hour)
	expiresIn := exp - time.Now().UTC().Unix()
	if expiresIn <= 0 {
		expiresIn = 86400 * 30
	}
	return token, expiresIn, nil
}

// GenerateDeviceToken creates a scoped authentication token for a device with an expiration timestamp.
func (s *Service) GenerateDeviceToken(deviceID string, expiryDuration time.Duration) (string, int64) {
	if expiryDuration <= 0 {
		expiryDuration = 30 * 24 * time.Hour
	}
	exp := time.Now().UTC().Add(expiryDuration).Unix()
	payload := fmt.Sprintf("%s:%d", deviceID, exp)
	mac := hmac.New(sha256.New, s.tokenKey)
	mac.Write([]byte("telemetry:auth:" + payload))
	sig := hex.EncodeToString(mac.Sum(nil))
	token := fmt.Sprintf("%d.%s", exp, sig)
	return token, exp
}

// VerifyDeviceToken checks if the bearer token matches the device identity and has not expired.
func (s *Service) VerifyDeviceToken(deviceID, token string) bool {
	if strings.TrimSpace(deviceID) == "" || strings.TrimSpace(token) == "" {
		return false
	}
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		// Fallback for legacy simple hash tokens
		mac := hmac.New(sha256.New, s.tokenKey)
		mac.Write([]byte("telemetry:auth:" + deviceID))
		expected := hex.EncodeToString(mac.Sum(nil))
		return hmac.Equal([]byte(expected), []byte(token))
	}

	exp, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return false
	}

	// Verify expiration
	if time.Now().UTC().Unix() > exp {
		return false
	}

	payload := fmt.Sprintf("%s:%d", deviceID, exp)
	mac := hmac.New(sha256.New, s.tokenKey)
	mac.Write([]byte("telemetry:auth:" + payload))
	expectedSig := hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(expectedSig), []byte(parts[1]))
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
		filter.StartTime.IsZero() &&
		filter.EndTime.IsZero() &&
		(filter.TimeRange == "" || filter.TimeRange == "all") &&
		filter.Page <= 1

	if canUseRedis {
		limit := filter.PageSize
		if limit <= 0 {
			limit = 50
		}
		cached, err := s.redisCache.GetRecentDiagnostics(ctx, limit)
		if err == nil && len(cached) > 0 {
			// Query real total count from store for accurate pagination
			_, total, err := s.store.QueryDiagnostics(ctx, QueryFilter{RecordType: RecordTypeDiagnostic, PageSize: 1})
			if err == nil && total >= len(cached) {
				return cached, total, "redis_cache", nil
			}
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

// Close closes the underlying store and cache resources.
func (s *Service) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var firstErr error
	if s.store != nil {
		if err := s.store.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	if s.redisCache != nil {
		if err := s.redisCache.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}
