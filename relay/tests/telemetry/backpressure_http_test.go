package telemetry_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
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

	body, err := json.Marshal(IngestBatchRequest{Records: []TelemetryEnvelope{
		testEnvelope("evt-batch-1", deviceID),
		testEnvelope("evt-batch-2", deviceID),
		testEnvelope("evt-batch-3", deviceID),
	}})
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

func TestPublicIngestRateLimitUsesAuthenticatedIdentityAndExpiresBuckets(t *testing.T) {
	t.Run("burst refill", func(t *testing.T) {
		service, store := newTestService(testAuthSecret)
		deviceID := "dev-rate-burst"
		token := mustAuth(t, service, store, deviceID)
		now := time.Unix(100, 0).UTC()
		handler := NewHandlerWithConfig(service, IngestConfig{
			RateLimitCapacity:        2,
			RateLimitRefillPerSecond: 1,
			RateLimitMaxDevices:      8,
			RateLimitDeviceTTL:       10 * time.Second,
			RetryAfterSeconds:        2,
			Clock:                    func() time.Time { return now },
		})
		mux := http.NewServeMux()
		handler.RegisterPublicRoutes(mux)

		send := func(id string) *httptest.ResponseRecorder {
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, ingestRequest(t, token, deviceID, testEnvelope(id, deviceID)))
			return rec
		}
		if rec := send("evt-rate-1"); rec.Code != http.StatusOK {
			t.Fatalf("first burst status = %d: %s", rec.Code, rec.Body.String())
		}
		if rec := send("evt-rate-2"); rec.Code != http.StatusOK {
			t.Fatalf("second burst status = %d: %s", rec.Code, rec.Body.String())
		}
		if rec := send("evt-rate-3"); rec.Code != http.StatusTooManyRequests {
			t.Fatalf("third burst status = %d, want 429", rec.Code)
		}
		now = now.Add(time.Second)
		if rec := send("evt-rate-refilled"); rec.Code != http.StatusOK {
			t.Fatalf("refilled request status = %d: %s", rec.Code, rec.Body.String())
		}
	})

	t.Run("bounded device cardinality and expiry", func(t *testing.T) {
		service, store := newTestService(testAuthSecret)
		now := time.Unix(200, 0).UTC()
		handler := NewHandlerWithConfig(service, IngestConfig{
			RateLimitCapacity:        10,
			RateLimitRefillPerSecond: 10,
			RateLimitMaxDevices:      2,
			RateLimitDeviceTTL:       10 * time.Second,
			RetryAfterSeconds:        2,
			Clock:                    func() time.Time { return now },
		})
		mux := http.NewServeMux()
		handler.RegisterPublicRoutes(mux)
		tokens := make(map[string]string)
		for _, deviceID := range []string{"dev-card-a", "dev-card-b", "dev-card-c"} {
			tokens[deviceID] = mustAuth(t, service, store, deviceID)
		}
		send := func(deviceID, eventID string) *httptest.ResponseRecorder {
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, ingestRequest(t, tokens[deviceID], deviceID, testEnvelope(eventID, deviceID)))
			return rec
		}
		if rec := send("dev-card-a", "evt-card-a"); rec.Code != http.StatusOK {
			t.Fatalf("device A status = %d: %s", rec.Code, rec.Body.String())
		}
		if rec := send("dev-card-b", "evt-card-b"); rec.Code != http.StatusOK {
			t.Fatalf("device B status = %d: %s", rec.Code, rec.Body.String())
		}
		if rec := send("dev-card-c", "evt-card-c"); rec.Code != http.StatusTooManyRequests {
			t.Fatalf("new device over cardinality limit status = %d, want 429", rec.Code)
		}
		now = now.Add(11 * time.Second)
		if rec := send("dev-card-c", "evt-card-c-after-expiry"); rec.Code != http.StatusOK {
			t.Fatalf("expired bucket cleanup status = %d: %s", rec.Code, rec.Body.String())
		}
	})
}

func TestHandlePublicIngestRejectsSpoofedIdentityBeforeRateAdmission(t *testing.T) {
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
	body, err := json.Marshal(IngestBatchRequest{Records: []TelemetryEnvelope{
		testEnvelope("evt-partial", deviceID),
		testEnvelope("evt-partial", deviceID),
		invalid,
	}})
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

	firstRec := httptest.NewRecorder()
	mux.ServeHTTP(firstRec, ingestRequest(t, token, deviceID, testEnvelope("evt-recovery-fail", deviceID)))
	if firstRec.Code != http.StatusServiceUnavailable {
		t.Fatalf("failed store status = %d, want 503", firstRec.Code)
	}

	secondRec := httptest.NewRecorder()
	mux.ServeHTTP(secondRec, ingestRequest(t, token, deviceID, testEnvelope("evt-recovery-ok", deviceID)))
	if secondRec.Code != http.StatusOK {
		t.Fatalf("recovered store status = %d: %s", secondRec.Code, secondRec.Body.String())
	}
}

func TestHandlePublicIngestReleasesWriterAfterStorePanic(t *testing.T) {
	base := NewMemoryStore(DefaultCatalog())
	deviceID := "dev-panic-recovery"
	_, deviceHash := registerDevice(t, base, deviceID)
	panicStore := &panicOnceStore{Store: base}
	service := NewServiceWithSecret(panicStore, DefaultCatalog(), &NoopRedisCache{}, testAuthSecret)
	exp := futureEpoch()
	token, _, err := service.AuthenticateDevice(context.Background(), deviceID, deviceProof(deviceID, deviceHash, exp), exp)
	if err != nil {
		t.Fatalf("authenticate device: %v", err)
	}
	handler := NewHandlerWithConfig(service, IngestConfig{MaxConcurrentWriters: 4, RetryAfterSeconds: 1})
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	func() {
		defer func() {
			if recovered := recover(); recovered == nil {
				t.Fatal("expected first store call to panic")
			}
		}()
		mux.ServeHTTP(httptest.NewRecorder(), ingestRequest(t, token, deviceID, testEnvelope("evt-panic", deviceID)))
	}()

	recovered := httptest.NewRecorder()
	mux.ServeHTTP(recovered, ingestRequest(t, token, deviceID, testEnvelope("evt-after-panic", deviceID)))
	if recovered.Code != http.StatusOK {
		t.Fatalf("writer permit was not released after panic: status=%d body=%s", recovered.Code, recovered.Body.String())
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

type panicOnceStore struct {
	Store
	panicked atomic.Bool
}

func (s *panicOnceStore) IngestBatch(ctx context.Context, envelopes []TelemetryEnvelope) ([]IngestRecordResult, error) {
	if s.panicked.CompareAndSwap(false, true) {
		panic("test store panic")
	}
	return s.Store.IngestBatch(ctx, envelopes)
}
