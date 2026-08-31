package telemetry_test

import (
	"context"
	"os"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestMySQLOverviewAggregatesBusinessLatencyDeliveryAndHealth(t *testing.T) {
	store, dsn := openTelemetryMySQLOrSkip(t)
	unique := time.Now().UTC().Format("20060102150405.000000000")
	deviceID := "dev-mysql-overview-" + unique
	ids := []string{
		"evt-mysql-overview-terminated-" + unique,
		"evt-mysql-overview-chat-" + unique,
		"evt-mysql-overview-failed-" + unique,
	}
	defer func() {
		_ = store.Close()
		cleanupTelemetryMySQL(t, dsn, ids, nil)
	}()

	if redisURL := os.Getenv("TELEMETRY_TEST_REDIS_URL"); redisURL != "" {
		cache, err := NewRedisClientCacheFromURL(redisURL, "")
		if err != nil {
			t.Fatalf("create overview Redis cache: %v", err)
		}
		defer cache.Close()
		store.SetRedisCache(cache)
	}
	now := time.Now().UTC()
	terminated := overviewRecord(t, DefaultCatalog(), ids[0], "ssh.session.terminated", now.Add(-2*time.Second))
	terminated.DeviceID = deviceID
	terminated.SessionID = "overview-session-success"
	terminated.TraceID = "overview-trace-success"
	terminated.Properties["duration_ms"] = int64(120)
	chat := overviewRecord(t, DefaultCatalog(), ids[1], "ai.chat.response", now.Add(-time.Second))
	chat.DeviceID = deviceID
	chat.SessionID = "overview-session-success"
	chat.TraceID = "overview-trace-success"
	chat.Properties["latency_ms"] = float64(80)
	failed := overviewRecord(t, DefaultCatalog(), ids[2], "ssh.session.failed", now.Add(3*time.Second))
	failed.DeviceID = deviceID
	failed.SessionID = "overview-session-failed"
	failed.TraceID = "overview-trace-failed"
	failed.Properties["stage"] = "connect"
	failed.Error = &TelemetryError{ErrorCode: "SSH_AUTH_FAILED", Category: "ssh", TerminalFailure: true}

	acks, err := store.IngestBatch(context.Background(), []TelemetryEnvelope{terminated, chat, failed})
	if err != nil {
		t.Fatalf("seed MySQL overview records: %v", err)
	}
	for i, ack := range acks {
		if ack.Status != StatusAccepted || ack.EventID != ids[i] {
			t.Fatalf("overview seed ack[%d] = %#v, want accepted %q", i, ack, ids[i])
		}
	}

	metrics, err := store.QueryOverview(context.Background(), QueryFilter{
		TimeRange: "7d",
		StartTime: now.Add(-time.Minute),
		EndTime:   now.Add(time.Minute),
	})
	if err != nil {
		t.Fatalf("MySQL overview query: %v", err)
	}
	if metrics.TotalEvents != 2 || metrics.TotalDiagnostics != 1 || metrics.ErrorCount != 1 ||
		metrics.CriticalErrorCount != 0 || metrics.RecentActiveDevices != 1 || metrics.AffectedDevicesCount != 1 {
		t.Fatalf("overview counts = %+v, want analytics=2 diagnostics=1 error=1 device=1", metrics)
	}
	if metrics.BusinessOperationSuccesses != 2 || metrics.BusinessOperationFailures != 1 ||
		metrics.BusinessOperationDenominator != 3 || metrics.BusinessOperationSuccessRate != 2.0/3.0 {
		t.Fatalf("business metrics = successes=%d failures=%d denominator=%d rate=%v, want 2/1/3/2/3", metrics.BusinessOperationSuccesses, metrics.BusinessOperationFailures, metrics.BusinessOperationDenominator, metrics.BusinessOperationSuccessRate)
	}
	if metrics.Latency.Samples != 2 || metrics.Latency.P50Ms != 80 || metrics.Latency.P95Ms != 120 || metrics.Latency.P99Ms != 120 {
		t.Fatalf("latency metrics = %+v, want samples=2 p50=80 p95/p99=120", metrics.Latency)
	}
	if metrics.DeliveryDelay.Samples != 3 || metrics.DeliveryDelay.FutureTimestampCount != 1 {
		t.Fatalf("delivery metrics = %+v, want three samples and one future timestamp", metrics.DeliveryDelay)
	}
	if len(metrics.EventsTrend) == 0 || len(metrics.ErrorsTrend) == 0 {
		t.Fatalf("overview trends = events=%+v errors=%+v, want both populated", metrics.EventsTrend, metrics.ErrorsTrend)
	}
	if metrics.PipelineHealth.Status == "unhealthy" {
		t.Fatalf("pipeline health = %+v, want healthy or degraded", metrics.PipelineHealth)
	}
}
