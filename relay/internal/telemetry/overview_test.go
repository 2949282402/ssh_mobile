package telemetry

import (
	"context"
	"math"
	"testing"
	"time"
)

// overviewDiagnosticEvents are the registered telemetry events whose canonical
// recordType is 'diagnostic' (mirrored from contracts/telemetry/events.json).
var overviewDiagnosticEvents = map[string]bool{
	"network.quic.failed":    true,
	"network.relay.fallback": true,
	"ssh.session.failed":     true,
	"sftp.transfer.failed":   true,
	"ai.chat.failed":         true,
	"app.diagnostic.log":     true,
	"telemetry.batch.failed": true,
}

// overviewTestRecord builds a valid telemetry envelope with the given event
// name, occurred/received times, and latency sample. Required contract
// properties are injected so the fixtures pass catalog validation.
func overviewTestRecord(id, name string, sev Severity, err *TelemetryError, received time.Time, durationMs *float64) TelemetryEnvelope {
	props := map[string]any{}
	if durationMs != nil {
		props["duration_ms"] = *durationMs
	}
	feature := "ssh"
	switch name {
	case "sftp.transfer.completed":
		if _, ok := props["direction"]; !ok {
			props["direction"] = "upload"
		}
		if _, ok := props["bytes_transferred"]; !ok {
			props["bytes_transferred"] = 1024
		}
		feature = "sftp"
	case "sftp.transfer.started", "sftp.transfer.failed":
		if _, ok := props["direction"]; !ok {
			props["direction"] = "upload"
		}
		feature = "sftp"
	case "ai.chat.request", "ai.chat.response":
		feature = "ai"
	case "network.quic.connected", "network.relay.connected", "network.relay.fallback":
		feature = "network"
	}

	recordType := RecordTypeAnalytics
	if overviewDiagnosticEvents[name] {
		recordType = RecordTypeDiagnostic
	}

	return TelemetryEnvelope{
		EventID:      id,
		RecordType:   recordType,
		EventName:    name,
		EventVersion: 1,
		DeviceID:     "dev-overview",
		SessionID:    "sess-overview",
		TraceID:      "trace-overview",
		OccurredAt:   received.Add(-500 * time.Millisecond),
		ReceivedAt:   received,
		Feature:      feature,
		Severity:     sev,
		AppVersion:   "1.0.0",
		BuildNumber:  "100",
		Platform:     "android",
		Properties:   props,
		Error:        err,
	}
}

func floatPtr(v float64) *float64 { return &v }

func ingestOverviewRecords(t *testing.T, records ...TelemetryEnvelope) *MemoryStore {
	t.Helper()
	catalog := DefaultCatalog()
	store := NewMemoryStore(catalog)
	// Seed this query-focused fixture directly so its historical receipt times
	// remain deterministic without weakening the production ingest contract.
	store.mu.Lock()
	defer store.mu.Unlock()
	for _, record := range records {
		if err := store.catalog.ValidateEnvelope(&record); err != nil {
			t.Fatalf("invalid overview fixture %s: %v", record.EventID, err)
		}
		store.rawEvents = append(store.rawEvents, record)
		store.receipts[record.EventID] = record.ReceivedAt
	}
	return store
}

func approxEqual(t *testing.T, got, want, epsilon float64, msg string) {
	t.Helper()
	if math.Abs(got-want) > epsilon {
		t.Errorf("%s: got %v, want %v", msg, got, want)
	}
}

func TestOverviewSuccessRateAndLatency(t *testing.T) {
	now := time.Now().UTC()

	// Terminal outcomes:
	//   succeeded: 3 (sftp.transfer.completed x3)
	//   failed:    1 (ssh.session.failed)
	//   in-progress (must NOT count): 5 (*.started)
	records := []TelemetryEnvelope{
		// 3 completed with distinct durations for p50/p95/p99
		overviewTestRecord("ok-1", "sftp.transfer.completed", SeverityInfo, nil, now.Add(-3*time.Minute), floatPtr(100)),
		overviewTestRecord("ok-2", "sftp.transfer.completed", SeverityInfo, nil, now.Add(-2*time.Minute), floatPtr(200)),
		overviewTestRecord("ok-3", "sftp.transfer.completed", SeverityInfo, nil, now.Add(-1*time.Minute), floatPtr(300)),

		overviewTestRecord("fail-1", "ssh.session.failed", SeverityError, &TelemetryError{
			ErrorCode:       "SSH_AUTH_FAILED",
			Category:        "ssh",
			TerminalFailure: true,
		}, now.Add(-90*time.Second), nil),

		// 5 in-progress started events: 2 ssh, 2 sftp, 1 ai request
		overviewTestRecord("start-1", "ssh.session.started", SeverityInfo, nil, now.Add(-5*time.Minute), nil),
		overviewTestRecord("start-2", "ssh.session.started", SeverityInfo, nil, now.Add(-5*time.Minute), nil),
		overviewTestRecord("start-3", "sftp.transfer.started", SeverityInfo, nil, now.Add(-5*time.Minute), nil),
		overviewTestRecord("start-4", "sftp.transfer.started", SeverityInfo, nil, now.Add(-5*time.Minute), nil),
		overviewTestRecord("start-5", "ai.chat.request", SeverityInfo, nil, now.Add(-5*time.Minute), nil),
	}

	store := ingestOverviewRecords(t, records...)
	metrics, err := store.QueryOverview(context.Background(), QueryFilter{})
	if err != nil {
		t.Fatalf("QueryOverview failed: %v", err)
	}

	// successRate = 3 / (3 + 1) = 0.75
	approxEqual(t, metrics.CoreOperationSuccessRate, 0.75, 1e-9, "success rate")

	// Verified: started events did NOT count toward the denominator.
	if metrics.TotalEvents != 8 {
		t.Errorf("expected 8 analytics events (3 ok + 1 fail + 5 started), got %d", metrics.TotalEvents)
	}
	if metrics.RecentActiveDevices != 1 {
		t.Errorf("expected 1 active device, got %d", metrics.RecentActiveDevices)
	}
	if metrics.ErrorCount != 1 {
		t.Errorf("expected 1 error, got %d", metrics.ErrorCount)
	}

	// p50 = 200, p95 = 300, p99 = 300 over [100, 200, 300]
	approxEqual(t, metrics.Latency.P50Ms, 200, 1e-9, "p50")
	approxEqual(t, metrics.Latency.P95Ms, 300, 1e-9, "p95")
	approxEqual(t, metrics.Latency.P99Ms, 300, 1e-9, "p99")
	if metrics.Latency.Samples != 3 {
		t.Errorf("expected 3 latency samples, got %d", metrics.Latency.Samples)
	}

	// Error-free sessions: 1 session with a failure out of 1 total -> 0.0
	approxEqual(t, metrics.ErrorFreeSessionRate, 0.0, 1e-9, "error free session rate")
}

func TestOverviewStartedEventsDoNotLowerSuccessRate(t *testing.T) {
	now := time.Now().UTC()

	// Only in-progress events present: no terminal data -> success rate 1.0
	startedOnly := []TelemetryEnvelope{
		overviewTestRecord("s-1", "ssh.session.started", SeverityInfo, nil, now.Add(-time.Minute), nil),
		overviewTestRecord("s-2", "sftp.transfer.started", SeverityInfo, nil, now.Add(-time.Minute), nil),
		overviewTestRecord("s-3", "ai.chat.request", SeverityInfo, nil, now.Add(-time.Minute), nil),
	}
	store := ingestOverviewRecords(t, startedOnly...)
	metrics, err := store.QueryOverview(context.Background(), QueryFilter{})
	if err != nil {
		t.Fatalf("QueryOverview failed: %v", err)
	}
	if metrics.CoreOperationSuccessRate != 1.0 {
		t.Errorf("expected 1.0 success rate with only started events (no terminal data), got %v", metrics.CoreOperationSuccessRate)
	}
	if metrics.Latency.Samples != 0 {
		t.Errorf("expected zero latency samples with only started events, got %d", metrics.Latency.Samples)
	}

	// Mixed: 1 succeeded + 1 failed + 5 started -> rate must be 0.5, not 0.142857.
	mixed := append([]TelemetryEnvelope{
		overviewTestRecord("ok-1", "sftp.transfer.completed", SeverityInfo, nil, now, floatPtr(60)),
		overviewTestRecord("fail-1", "ssh.session.failed", SeverityError, &TelemetryError{
			ErrorCode:       "SSH_TIMEOUT",
			Category:        "ssh",
			TerminalFailure: true,
		}, now, nil),
	}, startedOnly...)
	store = ingestOverviewRecords(t, mixed...)
	metrics, err = store.QueryOverview(context.Background(), QueryFilter{})
	if err != nil {
		t.Fatalf("QueryOverview failed: %v", err)
	}
	approxEqual(t, metrics.CoreOperationSuccessRate, 0.5, 1e-9, "success rate with started events present")
}

func TestOverviewEmptyDatasetZeroMetrics(t *testing.T) {
	store := NewMemoryStore(DefaultCatalog())
	metrics, err := store.QueryOverview(context.Background(), QueryFilter{})
	if err != nil {
		t.Fatalf("QueryOverview failed on empty dataset: %v", err)
	}

	if metrics.TotalEvents != 0 || metrics.TotalDiagnostics != 0 {
		t.Errorf("expected zero totals on empty dataset, got events=%d diagnostics=%d", metrics.TotalEvents, metrics.TotalDiagnostics)
	}
	if metrics.RecentActiveDevices != 0 || metrics.AffectedDevicesCount != 0 {
		t.Errorf("expected zero devices on empty dataset, got active=%d affected=%d", metrics.RecentActiveDevices, metrics.AffectedDevicesCount)
	}
	if metrics.CoreOperationSuccessRate != 1.0 {
		t.Errorf("expected default success rate 1.0 on empty dataset, got %v", metrics.CoreOperationSuccessRate)
	}
	if metrics.ErrorFreeSessionRate != 1.0 {
		t.Errorf("expected default session rate 1.0 on empty dataset, got %v", metrics.ErrorFreeSessionRate)
	}
	if metrics.Latency.Samples != 0 || metrics.Latency.P50Ms != 0 || metrics.Latency.P95Ms != 0 || metrics.Latency.P99Ms != 0 {
		t.Errorf("expected zero latency stats on empty dataset, got %+v", metrics.Latency)
	}
	if len(metrics.EventsTrend) != 0 || len(metrics.ErrorsTrend) != 0 {
		t.Errorf("expected empty trends on empty dataset, got events=%d errors=%d", len(metrics.EventsTrend), len(metrics.ErrorsTrend))
	}
}

func TestOverviewTimeRangeFiltering(t *testing.T) {
	now := time.Now().UTC()
	base := overviewTestRecord("base", "sftp.transfer.completed", SeverityInfo, nil, now, floatPtr(50))

	// Records spread across the ranges.
	records := []TelemetryEnvelope{
		base,
		// ~2 hours ago (inside 24h/7d/30d, outside 1h)
		overviewTestRecord("r-2h", "ssh.session.terminated", SeverityInfo, nil, now.Add(-2*time.Hour), floatPtr(150)),
		// ~3 days ago (inside 7d/30d, outside 1h/24h)
		overviewTestRecord("r-3d", "ssh.session.terminated", SeverityInfo, nil, now.Add(-3*24*time.Hour), floatPtr(250)),
		// ~15 days ago (inside 30d, outside 1h/24h/7d)
		overviewTestRecord("r-15d", "ssh.session.terminated", SeverityInfo, nil, now.Add(-15*24*time.Hour), floatPtr(350)),
	}
	store := ingestOverviewRecords(t, records...)
	ctx := context.Background()

	// 1h: only the base record
	m, err := store.QueryOverview(ctx, QueryFilter{TimeRange: "1h", StartTime: now.Add(-time.Hour), EndTime: now})
	if err != nil {
		t.Fatalf("1h query failed: %v", err)
	}
	if m.TotalEvents != 1 {
		t.Errorf("1h: expected 1 event, got %d", m.TotalEvents)
	}
	approxEqual(t, m.Latency.P50Ms, 50, 1e-9, "1h p50")

	// 24h: 2 records -> nearest-rank p50 over [50,150] is index 0 = 50
	m, err = store.QueryOverview(ctx, QueryFilter{TimeRange: "24h", StartTime: now.Add(-24 * time.Hour), EndTime: now})
	if err != nil {
		t.Fatalf("24h query failed: %v", err)
	}
	if m.TotalEvents != 2 {
		t.Errorf("24h: expected 2 events, got %d", m.TotalEvents)
	}
	approxEqual(t, m.Latency.P50Ms, 50, 1e-9, "24h p50")

	// 7d: 3 records -> nearest-rank p50 over [50,150,250] is index 1 = 150
	m, err = store.QueryOverview(ctx, QueryFilter{TimeRange: "7d", StartTime: now.Add(-7 * 24 * time.Hour), EndTime: now})
	if err != nil {
		t.Fatalf("7d query failed: %v", err)
	}
	if m.TotalEvents != 3 {
		t.Errorf("7d: expected 3 events, got %d", m.TotalEvents)
	}
	approxEqual(t, m.Latency.P50Ms, 150, 1e-9, "7d p50")

	// 30d: all 4 records -> nearest-rank p50 over [50,150,250,350] is index 1 = 150
	m, err = store.QueryOverview(ctx, QueryFilter{TimeRange: "30d", StartTime: now.Add(-30 * 24 * time.Hour), EndTime: now})
	if err != nil {
		t.Fatalf("30d query failed: %v", err)
	}
	if m.TotalEvents != 4 {
		t.Errorf("30d: expected 4 events, got %d", m.TotalEvents)
	}
	approxEqual(t, m.Latency.P50Ms, 150, 1e-9, "30d p50")

	// Trends bucketing: 30d uses daily buckets.
	if len(m.EventsTrend) < 1 {
		t.Errorf("30d: expected daily trend points, got %d", len(m.EventsTrend))
	}
	for _, pt := range m.EventsTrend {
		if len(pt.Timestamp) != len("2026-08-27T00:00:00Z") {
			t.Errorf("30d trend timestamp not daily ISO-8601 UTC: %q", pt.Timestamp)
		}
	}
}

func TestOverviewLatencyAliasLatencyMs(t *testing.T) {
	now := time.Now().UTC()
	// sftp.transfer.completed records with latency_ms present via ai.chat.response.
	records := []TelemetryEnvelope{
		overviewTestRecord("ok-1", "sftp.transfer.completed", SeverityInfo, nil, now, floatPtr(500)),
		{
			EventID:      "ai-1",
			RecordType:   RecordTypeAnalytics,
			EventName:    "ai.chat.response",
			EventVersion: 1,
			DeviceID:     "dev-overview",
			SessionID:    "sess-overview",
			TraceID:      "trace-overview",
			OccurredAt:   now.Add(-500 * time.Millisecond),
			ReceivedAt:   now,
			Feature:      "ai",
			Severity:     SeverityInfo,
			AppVersion:   "1.0.0",
			BuildNumber:  "100",
			Platform:     "android",
			Properties:   map[string]any{"latency_ms": float64(1500)},
		},
	}
	store := ingestOverviewRecords(t, records...)
	metrics, err := store.QueryOverview(context.Background(), QueryFilter{})
	if err != nil {
		t.Fatalf("QueryOverview failed: %v", err)
	}
	// Samples [500, 1500]
	approxEqual(t, metrics.Latency.P50Ms, 500, 1e-9, "p50 latency_ms alias")
	approxEqual(t, metrics.Latency.P95Ms, 1500, 1e-9, "p95 latency_ms alias")
	if metrics.Latency.Samples != 2 {
		t.Errorf("expected 2 latency samples, got %d", metrics.Latency.Samples)
	}
	if metrics.CoreOperationSuccessRate != 1.0 {
		t.Errorf("expected 1.0 success rate, got %v", metrics.CoreOperationSuccessRate)
	}
}
