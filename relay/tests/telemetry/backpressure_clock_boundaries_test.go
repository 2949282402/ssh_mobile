package telemetry_test

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestPublicIngestRateLimiterClampsClockRollback(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	deviceID := "dev-rate-clock-rollback"
	token := mustAuth(t, service, store, deviceID)
	now := time.Unix(700, 0).UTC()
	handler := NewHandlerWithConfig(service, IngestConfig{
		RateLimitCapacity:        2,
		RateLimitRefillPerSecond: 1,
		RateLimitMaxDevices:      4,
		RateLimitDeviceTTL:       time.Minute,
		Clock:                    func() time.Time { return now },
	})
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	first := httptest.NewRecorder()
	mux.ServeHTTP(first, ingestRequest(t, token, deviceID, testEnvelope("clock-first", deviceID)))
	if first.Code != http.StatusOK {
		t.Fatalf("first request status = %d: %s", first.Code, first.Body.String())
	}
	now = now.Add(-time.Second)
	second := httptest.NewRecorder()
	mux.ServeHTTP(second, ingestRequest(t, token, deviceID, testEnvelope("clock-rollback", deviceID)))
	if second.Code != http.StatusOK {
		t.Fatalf("clock rollback request status = %d: %s", second.Code, second.Body.String())
	}
}
