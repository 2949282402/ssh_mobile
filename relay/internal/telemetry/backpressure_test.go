package telemetry

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestHandlePublicIngestRejectsOversizeBodyBeforeParsing(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	deviceID := "dev-body-limit"
	token := mustAuth(t, service, store, deviceID)
	handler := NewHandler(service)
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	body := bytes.Repeat([]byte("x"), MaxRequestBodyBytes+1)
	req := httptest.NewRequest(http.MethodPost, PathPublicIngest, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Device-Id", deviceID)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversize body status = %d, want 413: %s", rec.Code, rec.Body.String())
	}
	assertErrorCode(t, rec, "PAYLOAD_TOO_LARGE")
}

func TestHandlePublicIngestRejectsBatchAboveConfiguredLimit(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	deviceID := "dev-batch-limit"
	token := mustAuth(t, service, store, deviceID)
	handler := NewHandlerWithConfig(service, IngestConfig{
		MaxBatchSize:             2,
		MaxConcurrentWriters:     4,
		RateLimitCapacity:        10,
		RateLimitRefillPerSecond: 10,
	})
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	batch := IngestBatchRequest{Records: []TelemetryEnvelope{
		testEnvelope("evt-batch-1", deviceID),
		testEnvelope("evt-batch-2", deviceID),
		testEnvelope("evt-batch-3", deviceID),
	}}
	body, err := json.Marshal(batch)
	if err != nil {
		t.Fatalf("marshal batch: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, PathPublicIngest, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Device-Id", deviceID)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversize batch status = %d, want 413: %s", rec.Code, rec.Body.String())
	}
	assertErrorCode(t, rec, "BATCH_TOO_LARGE")
	if _, total, err := store.QueryEvents(context.Background(), QueryFilter{}); err != nil || total != 0 {
		t.Fatalf("oversize batch persisted data: total=%d err=%v", total, err)
	}
}

func TestHandlePublicIngestWriterSaturationReturnsBoundedRetry(t *testing.T) {
	base := NewMemoryStore(DefaultCatalog())
	deviceID := "dev-writer-saturation"
	_, deviceHash := registerDevice(t, base, deviceID)
	blocking := &blockingStore{
		Store:   base,
		started: make(chan struct{}, 8),
		release: make(chan struct{}),
	}
	service := NewServiceWithSecret(blocking, DefaultCatalog(), &NoopRedisCache{}, testAuthSecret)
	exp := futureEpoch()
	token, _, err := service.AuthenticateDevice(context.Background(), deviceID, deviceProof(deviceID, deviceHash, exp), exp)
	if err != nil {
		t.Fatalf("authenticate device: %v", err)
	}
	handler := NewHandlerWithConfig(service, IngestConfig{
		MaxConcurrentWriters:     4,
		RateLimitCapacity:        100,
		RateLimitRefillPerSecond: 100,
		RetryAfterSeconds:        1,
	})
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	var requests sync.WaitGroup
	for i := 0; i < 4; i++ {
		requests.Add(1)
		go func(i int) {
			defer requests.Done()
			req := ingestRequest(t, token, deviceID, testEnvelope("evt-blocked-"+string(rune('a'+i)), deviceID))
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code != http.StatusOK {
				t.Errorf("blocked writer request %d status = %d: %s", i, rec.Code, rec.Body.String())
			}
		}(i)
	}
	for i := 0; i < 4; i++ {
		select {
		case <-blocking.started:
		case <-time.After(time.Second):
			t.Fatal("timed out waiting for writer slot")
		}
	}

	probe := ingestRequest(t, token, deviceID, testEnvelope("evt-overloaded", deviceID))
	probeRec := httptest.NewRecorder()
	mux.ServeHTTP(probeRec, probe)
	if probeRec.Code != http.StatusTooManyRequests {
		t.Fatalf("saturated writer status = %d, want 429: %s", probeRec.Code, probeRec.Body.String())
	}
	if got := probeRec.Header().Get("Retry-After"); got != "1" {
		t.Fatalf("Retry-After = %q, want 1", got)
	}
	assertErrorCode(t, probeRec, "INGEST_OVERLOADED")

	close(blocking.release)
	requests.Wait()
}

func TestDeviceRateLimiterBurstRefillIsolationAndBoundedCleanup(t *testing.T) {
	now := time.Unix(100, 0).UTC()
	config := normalizeIngestConfig(IngestConfig{
		RateLimitCapacity:        2,
		RateLimitRefillPerSecond: 1,
		RateLimitMaxDevices:      2,
		RateLimitDeviceTTL:       10 * time.Second,
		Clock:                    func() time.Time { return now },
	})
	limiter := newDeviceRateLimiter(config)

	if allowed, _ := limiter.allow("device-a", now); !allowed {
		t.Fatal("first burst token should be accepted")
	}
	if allowed, _ := limiter.allow("device-a", now); !allowed {
		t.Fatal("second burst token should be accepted")
	}
	if allowed, retry := limiter.allow("device-a", now); allowed || retry != time.Second {
		t.Fatalf("third burst result = allowed %v retry %v, want false/1s", allowed, retry)
	}
	if allowed, _ := limiter.allow("device-b", now); !allowed {
		t.Fatal("device-b must have an isolated bucket")
	}
	if allowed, _ := limiter.allow("device-c", now); allowed {
		t.Fatal("new device must not evict active buckets when cardinality is full")
	}

	now = now.Add(11 * time.Second)
	if allowed, _ := limiter.allow("device-c", now); !allowed {
		t.Fatal("expired buckets should be cleaned up before admitting a new device")
	}
	if got := limiter.entryCount(); got != 1 {
		t.Fatalf("rate limiter entries after TTL cleanup = %d, want 1", got)
	}

	now = now.Add(time.Second)
	if allowed, _ := limiter.allow("device-c", now); !allowed {
		t.Fatal("device-c should refill after one second")
	}
}

func TestNormalizeIngestConfigAppliesHardBounds(t *testing.T) {
	config := normalizeIngestConfig(IngestConfig{
		MaxBodyBytes:             maxIngestBodyBytes * 2,
		MaxBatchSize:             maxIngestBatchSize * 2,
		MaxConcurrentWriters:     maxIngestConcurrentWriters * 2,
		RateLimitCapacity:        maxIngestRateLimitCapacity * 2,
		RateLimitRefillPerSecond: maxIngestRateLimitRefill * 2,
		RateLimitMaxDevices:      maxIngestRateLimitDevices * 2,
		RateLimitDeviceTTL:       maxIngestDeviceTTL * 2,
		RetryAfterSeconds:        maxIngestRetryAfterSeconds * 2,
	})
	if config.MaxBodyBytes != maxIngestBodyBytes || config.MaxBatchSize != maxIngestBatchSize ||
		config.MaxConcurrentWriters != maxIngestConcurrentWriters ||
		config.RateLimitCapacity != maxIngestRateLimitCapacity ||
		config.RateLimitRefillPerSecond != maxIngestRateLimitRefill ||
		config.RateLimitMaxDevices != maxIngestRateLimitDevices ||
		config.RateLimitDeviceTTL != maxIngestDeviceTTL ||
		config.RetryAfterSeconds != maxIngestRetryAfterSeconds {
		t.Fatalf("normalized config exceeded hard bounds: %+v", config)
	}
	if config.RateLimitRefillPerSec != config.RateLimitRefillPerSecond || config.Clock == nil {
		t.Fatalf("normalized refill alias/clock mismatch: %+v", config)
	}
}

func TestIngestConfigFromEnvironment(t *testing.T) {
	t.Setenv("TELEMETRY_MAX_BODY_BYTES", "2048")
	t.Setenv("TELEMETRY_MAX_BATCH_SIZE", "7")
	t.Setenv("TELEMETRY_MAX_CONCURRENT_WRITERS", "8")
	t.Setenv("TELEMETRY_RATE_LIMIT_CAPACITY", "12")
	t.Setenv("TELEMETRY_RATE_LIMIT_REFILL_PER_SECOND", "2.5")
	t.Setenv("TELEMETRY_RATE_LIMIT_MAX_DEVICES", "32")
	t.Setenv("TELEMETRY_RATE_LIMIT_DEVICE_TTL", "30s")
	t.Setenv("TELEMETRY_RETRY_AFTER_SECONDS", "3")

	config, err := IngestConfigFromEnvironment()
	if err != nil {
		t.Fatalf("read ingest config: %v", err)
	}
	if config.MaxBodyBytes != 2048 || config.MaxBatchSize != 7 || config.MaxConcurrentWriters != 8 ||
		config.RateLimitCapacity != 12 || config.RateLimitRefillPerSecond != 2.5 ||
		config.RateLimitMaxDevices != 32 || config.RateLimitDeviceTTL != 30*time.Second || config.RetryAfterSeconds != 3 {
		t.Fatalf("unexpected environment config: %+v", config)
	}

	t.Setenv("TELEMETRY_MAX_BATCH_SIZE", "invalid")
	if _, err := IngestConfigFromEnvironment(); err == nil {
		t.Fatal("invalid environment config should fail closed")
	}
}

func TestHandlePublicIngestDoesNotRateLimitSpoofedIdentity(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	deviceA := "dev-rate-a"
	tokenA := mustAuth(t, service, store, deviceA)
	handler := NewHandlerWithConfig(service, IngestConfig{
		RateLimitCapacity:        1,
		RateLimitRefillPerSecond: 1,
		RateLimitMaxDevices:      8,
	})
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	spoofed := ingestRequest(t, tokenA, "dev-rate-b", testEnvelope("evt-spoofed", deviceA))
	spoofedRec := httptest.NewRecorder()
	mux.ServeHTTP(spoofedRec, spoofed)
	if spoofedRec.Code != http.StatusUnauthorized {
		t.Fatalf("spoofed identity status = %d, want 401", spoofedRec.Code)
	}
	if got := handler.limiter.entryCount(); got != 0 {
		t.Fatalf("spoofed identity created rate-limit entry count=%d", got)
	}

	valid := ingestRequest(t, tokenA, deviceA, testEnvelope("evt-valid", deviceA))
	validRec := httptest.NewRecorder()
	mux.ServeHTTP(validRec, valid)
	if validRec.Code != http.StatusOK {
		t.Fatalf("valid identity status = %d: %s", validRec.Code, validRec.Body.String())
	}
}

func TestHandlePublicIngestPartialInvalidAndDuplicateBatch(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	deviceID := "dev-partial-batch"
	token := mustAuth(t, service, store, deviceID)
	handler := NewHandlerWithConfig(service, IngestConfig{
		RateLimitCapacity:        10,
		RateLimitRefillPerSecond: 10,
	})
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	invalid := testEnvelope("evt-partial-invalid", deviceID)
	invalid.Feature = "network"
	batch := IngestBatchRequest{Records: []TelemetryEnvelope{
		testEnvelope("evt-partial", deviceID),
		testEnvelope("evt-partial", deviceID),
		invalid,
	}}
	body, err := json.Marshal(batch)
	if err != nil {
		t.Fatalf("marshal batch: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, PathPublicIngest, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Device-Id", deviceID)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("partial batch status = %d: %s", rec.Code, rec.Body.String())
	}
	var response IngestBatchResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode partial response: %v", err)
	}
	if len(response.Results) != 3 || response.Results[0].Status != StatusAccepted ||
		response.Results[1].Status != StatusAlreadySeen || response.Results[2].Status != StatusRejected {
		t.Fatalf("partial batch results = %+v", response.Results)
	}
	if _, total, err := store.QueryEvents(context.Background(), QueryFilter{}); err != nil || total != 1 {
		t.Fatalf("partial batch stored total=%d err=%v, want 1", total, err)
	}
}

func TestMemoryStoreConcurrentDuplicateEventIDs(t *testing.T) {
	store := NewMemoryStore(DefaultCatalog())
	envelope := testEnvelope("evt-concurrent-duplicate", "dev-concurrent")
	const calls = 16
	results := make(chan IngestStatus, calls)
	var wait sync.WaitGroup
	for i := 0; i < calls; i++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			got, err := store.IngestBatch(context.Background(), []TelemetryEnvelope{envelope})
			if err != nil {
				t.Errorf("concurrent ingest: %v", err)
				return
			}
			results <- got[0].Status
		}()
	}
	wait.Wait()
	close(results)

	var accepted, alreadySeen int
	for status := range results {
		switch status {
		case StatusAccepted:
			accepted++
		case StatusAlreadySeen:
			alreadySeen++
		default:
			t.Fatalf("unexpected concurrent status %q", status)
		}
	}
	if accepted != 1 || alreadySeen != calls-1 {
		t.Fatalf("concurrent statuses accepted=%d alreadySeen=%d, want 1/%d", accepted, alreadySeen, calls-1)
	}
	if _, total, err := store.QueryEvents(context.Background(), QueryFilter{}); err != nil || total != 1 {
		t.Fatalf("concurrent duplicate stored total=%d err=%v, want 1", total, err)
	}
}

func TestHandlePublicIngestReleasesWriterAfterStoreFailure(t *testing.T) {
	base := NewMemoryStore(DefaultCatalog())
	deviceID := "dev-recovery"
	_, deviceHash := registerDevice(t, base, deviceID)
	recovering := &recoveringStore{Store: base}
	service := NewServiceWithSecret(recovering, DefaultCatalog(), &NoopRedisCache{}, testAuthSecret)
	exp := futureEpoch()
	token, _, err := service.AuthenticateDevice(context.Background(), deviceID, deviceProof(deviceID, deviceHash, exp), exp)
	if err != nil {
		t.Fatalf("authenticate device: %v", err)
	}
	handler := NewHandlerWithConfig(service, IngestConfig{MaxConcurrentWriters: 4, RetryAfterSeconds: 1})
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	first := ingestRequest(t, token, deviceID, testEnvelope("evt-recovery-fail", deviceID))
	firstRec := httptest.NewRecorder()
	mux.ServeHTTP(firstRec, first)
	if firstRec.Code != http.StatusServiceUnavailable {
		t.Fatalf("failed store status = %d, want 503", firstRec.Code)
	}

	second := ingestRequest(t, token, deviceID, testEnvelope("evt-recovery-ok", deviceID))
	secondRec := httptest.NewRecorder()
	mux.ServeHTTP(secondRec, second)
	if secondRec.Code != http.StatusOK {
		t.Fatalf("recovered store status = %d: %s", secondRec.Code, secondRec.Body.String())
	}
}

func TestMySQLStoreConcurrentDuplicateEventIDs(t *testing.T) {
	dsn := os.Getenv("TELEMETRY_TEST_MYSQL_DSN")
	if dsn == "" {
		dsn = os.Getenv("TELEMETRY_MYSQL_DSN")
	}
	if dsn == "" {
		t.Skip("TELEMETRY_TEST_MYSQL_DSN or TELEMETRY_MYSQL_DSN not set; skipping MySQL integration test")
	}

	store, err := NewMySQLStoreFromDSN(dsn, DefaultCatalog())
	if err != nil {
		t.Fatalf("open telemetry MySQL store: %v", err)
	}
	defer store.Close()
	const eventID = "evt-concurrent-mysql-duplicate"
	const deviceID = "dev-concurrent-mysql"
	cleanup := func() {
		_, _ = store.db.ExecContext(context.Background(), "DELETE FROM telemetry_events WHERE event_id = ?", eventID)
		_, _ = store.db.ExecContext(context.Background(), "DELETE FROM telemetry_ingest_receipts WHERE event_id = ?", eventID)
	}
	cleanup()
	t.Cleanup(cleanup)

	envelope := testEnvelope(eventID, deviceID)
	const calls = 8
	statuses := make(chan IngestStatus, calls)
	var wait sync.WaitGroup
	for i := 0; i < calls; i++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			got, err := store.IngestBatch(context.Background(), []TelemetryEnvelope{envelope})
			if err != nil {
				t.Errorf("concurrent MySQL ingest: %v", err)
				return
			}
			statuses <- got[0].Status
		}()
	}
	wait.Wait()
	close(statuses)

	var accepted, alreadySeen int
	for status := range statuses {
		switch status {
		case StatusAccepted:
			accepted++
		case StatusAlreadySeen:
			alreadySeen++
		default:
			t.Fatalf("unexpected MySQL concurrent status %q", status)
		}
	}
	if accepted != 1 || alreadySeen != calls-1 {
		t.Fatalf("MySQL concurrent statuses accepted=%d alreadySeen=%d, want 1/%d", accepted, alreadySeen, calls-1)
	}
}

func ingestRequest(t *testing.T, token, deviceID string, envelope TelemetryEnvelope) *http.Request {
	t.Helper()
	body, err := json.Marshal(IngestBatchRequest{Records: []TelemetryEnvelope{envelope}})
	if err != nil {
		t.Fatalf("marshal ingest request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, PathPublicIngest, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Device-Id", deviceID)
	return req
}

func assertErrorCode(t *testing.T, rec *httptest.ResponseRecorder, want string) {
	t.Helper()
	var payload struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if payload.Error.Code != want {
		t.Fatalf("error code = %q, want %q; body=%s", payload.Error.Code, want, rec.Body.String())
	}
}

type blockingStore struct {
	Store
	started chan struct{}
	release chan struct{}
}

func (s *blockingStore) IngestBatch(ctx context.Context, envelopes []TelemetryEnvelope) ([]IngestRecordResult, error) {
	s.started <- struct{}{}
	select {
	case <-s.release:
		return s.Store.IngestBatch(ctx, envelopes)
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

type recoveringStore struct {
	Store
	failed atomic.Bool
}

func (s *recoveringStore) IngestBatch(ctx context.Context, envelopes []TelemetryEnvelope) ([]IngestRecordResult, error) {
	if s.failed.CompareAndSwap(false, true) {
		return nil, errors.New("temporary database failure")
	}
	return s.Store.IngestBatch(ctx, envelopes)
}
