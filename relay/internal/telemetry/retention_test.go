package telemetry

import (
	"context"
	"testing"
	"time"
)

func TestRetentionPurgeAndReceiptPreservation(t *testing.T) {
	ctx := context.Background()
	catalog := DefaultCatalog()
	store := NewMemoryStore(catalog)

	now := time.Now().UTC()

	// Ingest 5 records at different times
	records := []TelemetryEnvelope{
		{
			EventID:      "evt-old-1",
			RecordType:   RecordTypeAnalytics,
			EventName:    "ssh.session.started",
			EventVersion: 1,
			DeviceID:     "dev-1",
			SessionID:    "sess-1",
			TraceID:      "trace-1",
			OccurredAt:   now.Add(-40 * 24 * time.Hour),
			ReceivedAt:   now.Add(-40 * 24 * time.Hour), // 40 days old
			Feature:      "ssh",
			Severity:     SeverityInfo,
			AppVersion:   "1.0.0",
			BuildNumber:  "100",
			Platform:     "android",
		},
		{
			EventID:      "evt-old-2",
			RecordType:   RecordTypeAnalytics,
			EventName:    "ssh.session.started",
			EventVersion: 1,
			DeviceID:     "dev-1",
			SessionID:    "sess-1",
			TraceID:      "trace-1",
			OccurredAt:   now.Add(-35 * 24 * time.Hour),
			ReceivedAt:   now.Add(-35 * 24 * time.Hour), // 35 days old
			Feature:      "ssh",
			Severity:     SeverityInfo,
			AppVersion:   "1.0.0",
			BuildNumber:  "100",
			Platform:     "android",
		},
		{
			EventID:      "evt-recent-1",
			RecordType:   RecordTypeAnalytics,
			EventName:    "ssh.session.started",
			EventVersion: 1,
			DeviceID:     "dev-1",
			SessionID:    "sess-1",
			TraceID:      "trace-1",
			OccurredAt:   now.Add(-2 * time.Hour),
			ReceivedAt:   now.Add(-2 * time.Hour),
			Feature:      "ssh",
			Severity:     SeverityInfo,
			AppVersion:   "1.0.0",
			BuildNumber:  "100",
			Platform:     "android",
		},
		{
			EventID:      "evt-recent-2",
			RecordType:   RecordTypeAnalytics,
			EventName:    "ssh.session.started",
			EventVersion: 1,
			DeviceID:     "dev-2",
			SessionID:    "sess-2",
			TraceID:      "trace-2",
			OccurredAt:   now.Add(-1 * time.Hour),
			ReceivedAt:   now.Add(-1 * time.Hour),
			Feature:      "ssh",
			Severity:     SeverityInfo,
			AppVersion:   "1.0.0",
			BuildNumber:  "100",
			Platform:     "android",
		},
		{
			EventID:      "evt-recent-3",
			RecordType:   RecordTypeAnalytics,
			EventName:    "ssh.session.started",
			EventVersion: 1,
			DeviceID:     "dev-3",
			SessionID:    "sess-3",
			TraceID:      "trace-3",
			OccurredAt:   now,
			ReceivedAt:   now,
			Feature:      "ssh",
			Severity:     SeverityInfo,
			AppVersion:   "1.0.0",
			BuildNumber:  "100",
			Platform:     "android",
		},
	}

	store.mu.Lock()
	for _, record := range records {
		if err := store.catalog.ValidateEnvelope(&record); err != nil {
			store.mu.Unlock()
			t.Fatalf("invalid retention fixture %s: %v", record.EventID, err)
		}
		store.rawEvents = append(store.rawEvents, record)
		store.receipts[record.EventID] = record.ReceivedAt
	}
	store.mu.Unlock()

	// 1. Time retention purge: cutoff 30 days ago
	cutoff := now.Add(-30 * 24 * time.Hour)
	deleted, err := store.PurgeRetention(ctx, cutoff, 0, 100)
	if err != nil {
		t.Fatalf("PurgeRetention failed: %v", err)
	}
	if deleted != 2 {
		t.Errorf("expected 2 old records purged, got %d", deleted)
	}

	// Verify remaining raw records in store
	events, total, err := store.QueryEvents(ctx, QueryFilter{Page: 1, PageSize: 50})
	if err != nil || total != 3 || len(events) != 3 {
		t.Fatalf("expected 3 remaining events, got total=%d len=%d", total, len(events))
	}

	// 2. CRITICAL INVARIANT: Replaying an event that was purged from raw table
	// MUST return already_seen because its receipt was preserved!
	replayedResults, err := store.IngestBatch(ctx, []TelemetryEnvelope{records[0]})
	if err != nil {
		t.Fatalf("Replay of purged event failed: %v", err)
	}
	if len(replayedResults) != 1 || replayedResults[0].Status != StatusAlreadySeen {
		t.Errorf("expected replayed purged event to be already_seen, got %v", replayedResults)
	}

	// Verify raw table was NOT resurrected
	_, newTotal, _ := store.QueryEvents(ctx, QueryFilter{Page: 1, PageSize: 50})
	if newTotal != 3 {
		t.Errorf("expected total raw events to remain 3 after already_seen replay, got %d", newTotal)
	}

	// 3. Max rows retention purge: limit to 2 rows
	deletedRows, err := store.PurgeRetention(ctx, time.Time{}, 2, 100)
	if err != nil {
		t.Fatalf("PurgeRetention maxRows failed: %v", err)
	}
	if deletedRows != 1 {
		t.Errorf("expected 1 record purged to satisfy maxRows=2, got %d", deletedRows)
	}

	_, finalTotal, _ := store.QueryEvents(ctx, QueryFilter{Page: 1, PageSize: 50})
	if finalTotal != 2 {
		t.Errorf("expected final raw events count 2, got %d", finalTotal)
	}
}
