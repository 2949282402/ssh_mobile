package telemetry_test

import (
	"math"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestPublicIngestNormalizesNonFiniteRefillAliases(t *testing.T) {
	cases := []struct {
		name   string
		refill float64
		alias  float64
	}{
		{name: "nan", refill: math.NaN()},
		{name: "positive infinity", refill: math.Inf(1)},
		{name: "negative infinity", refill: math.Inf(-1)},
		{name: "alias nan", alias: math.NaN()},
		{name: "alias infinity", alias: math.Inf(1)},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			service, store := newTestService(testAuthSecret)
			deviceID := "dev-nonfinite-refill-" + strconv.FormatInt(time.Now().UnixNano(), 10)
			token := mustAuth(t, service, store, deviceID)
			now := time.Unix(500, 0).UTC()
			handler := NewHandlerWithConfig(service, IngestConfig{
				RateLimitCapacity:        1,
				RateLimitRefillPerSecond: tc.refill,
				RateLimitRefillPerSec:    tc.alias,
				Clock:                    func() time.Time { return now },
			})
			mux := http.NewServeMux()
			handler.RegisterPublicRoutes(mux)

			first := httptest.NewRecorder()
			mux.ServeHTTP(first, ingestRequest(t, token, deviceID, testEnvelope("evt-nonfinite-first", deviceID)))
			if first.Code != http.StatusOK {
				t.Fatalf("first request status = %d: %s", first.Code, first.Body.String())
			}
			second := httptest.NewRecorder()
			mux.ServeHTTP(second, ingestRequest(t, token, deviceID, testEnvelope("evt-nonfinite-second", deviceID)))
			if second.Code != http.StatusTooManyRequests {
				t.Fatalf("second request status = %d, want 429: %s", second.Code, second.Body.String())
			}
			assertErrorCode(t, second, "INGEST_RATE_LIMITED")
			if got := second.Header().Get("Retry-After"); got != "1" {
				t.Fatalf("Retry-After = %q, want default one-second fallback", got)
			}
		})
	}
}

func TestPublicIngestRetryAfterCeilsCapsAndHandlesOverflow(t *testing.T) {
	cases := []struct {
		name           string
		refill         float64
		retryAfter     int
		wantRetryAfter string
	}{
		{name: "fractional wait is ceiled", refill: 0.8, retryAfter: 60, wantRetryAfter: "2"},
		{name: "wait is capped", refill: 0.25, retryAfter: 2, wantRetryAfter: "2"},
		{name: "overflow is capped", refill: math.SmallestNonzeroFloat64, retryAfter: 3, wantRetryAfter: "3"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			service, store := newTestService(testAuthSecret)
			deviceID := "dev-retry-after-" + strconv.FormatInt(time.Now().UnixNano(), 10)
			token := mustAuth(t, service, store, deviceID)
			now := time.Unix(600, 0).UTC()
			handler := NewHandlerWithConfig(service, IngestConfig{
				RateLimitCapacity:        1,
				RateLimitRefillPerSecond: tc.refill,
				RetryAfterSeconds:        tc.retryAfter,
				Clock:                    func() time.Time { return now },
			})
			mux := http.NewServeMux()
			handler.RegisterPublicRoutes(mux)

			first := httptest.NewRecorder()
			mux.ServeHTTP(first, ingestRequest(t, token, deviceID, testEnvelope("evt-retry-first", deviceID)))
			if first.Code != http.StatusOK {
				t.Fatalf("first request status = %d: %s", first.Code, first.Body.String())
			}
			limited := httptest.NewRecorder()
			mux.ServeHTTP(limited, ingestRequest(t, token, deviceID, testEnvelope("evt-retry-second", deviceID)))
			if limited.Code != http.StatusTooManyRequests {
				t.Fatalf("limited request status = %d, want 429: %s", limited.Code, limited.Body.String())
			}
			assertErrorCode(t, limited, "INGEST_RATE_LIMITED")
			if got := limited.Header().Get("Retry-After"); got != tc.wantRetryAfter {
				t.Fatalf("Retry-After = %q, want %q", got, tc.wantRetryAfter)
			}
		})
	}
}

func TestIngestConfigFromEnvironmentClampsHardBounds(t *testing.T) {
	t.Setenv("TELEMETRY_MAX_BODY_BYTES", "2097152")
	t.Setenv("TELEMETRY_MAX_BATCH_SIZE", "101")
	t.Setenv("TELEMETRY_MAX_CONCURRENT_WRITERS", "100")
	t.Setenv("TELEMETRY_RATE_LIMIT_CAPACITY", "1001")
	t.Setenv("TELEMETRY_RATE_LIMIT_REFILL_PER_SECOND", "1001")
	t.Setenv("TELEMETRY_RATE_LIMIT_MAX_DEVICES", "65537")
	t.Setenv("TELEMETRY_RATE_LIMIT_DEVICE_TTL", "24h1m")
	t.Setenv("TELEMETRY_RETRY_AFTER_SECONDS", "61")

	config, err := IngestConfigFromEnvironment()
	if err != nil {
		t.Fatalf("read bounded ingest config: %v", err)
	}
	wantBodyBytes := int64(MaxRequestBodyBytes)
	if config.MaxBodyBytes != wantBodyBytes || config.MaxBatchSize != MaxIngestBatchSize ||
		config.MaxConcurrentWriters != 8 || config.RateLimitCapacity != 1000 ||
		config.RateLimitRefillPerSecond != 1000 || config.RateLimitRefillPerSec != 1000 ||
		config.RateLimitMaxDevices != 65536 || config.RateLimitDeviceTTL != 24*time.Hour ||
		config.RetryAfterSeconds != 60 || config.Clock == nil {
		t.Fatalf("hard-bound normalization = %+v", config)
	}
}
