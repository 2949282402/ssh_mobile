package telemetry_test

import (
	"context"
	"strconv"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestRetentionPurgeAndReceiptPreservation(t *testing.T) {
	ctx := context.Background()
	store := NewMemoryStore(DefaultCatalog())
	records := make([]TelemetryEnvelope, 0, 5)
	for i := 0; i < 5; i++ {
		records = append(records, testEnvelope("evt-retention-"+strconv.Itoa(i), "dev-retention"))
	}
	if results, err := store.IngestBatch(ctx, records); err != nil {
		t.Fatalf("seed retention records: %v", err)
	} else if len(results) != len(records) {
		t.Fatalf("seed retention result count=%d, want %d", len(results), len(records))
	}

	// A future cutoff drives the public retention boundary while the store
	// remains responsible for stamping trusted receipt times.
	cutoff := time.Now().UTC().Add(time.Hour)
	deleted, err := store.PurgeRetention(ctx, cutoff, 0, 100)
	if err != nil {
		t.Fatalf("PurgeRetention failed: %v", err)
	}
	if deleted != len(records) {
		t.Errorf("expected all %d records purged, got %d", len(records), deleted)
	}

	events, total, err := store.QueryEvents(ctx, QueryFilter{Page: 1, PageSize: 50})
	if err != nil || total != 0 || len(events) != 0 {
		t.Fatalf("expected no remaining events, got total=%d len=%d err=%v", total, len(events), err)
	}

	// Receipts survive raw-event deletion, so replay is acknowledged without
	// resurrecting a deleted event.
	replayedResults, err := store.IngestBatch(ctx, []TelemetryEnvelope{records[0]})
	if err != nil {
		t.Fatalf("replay of purged event failed: %v", err)
	}
	if len(replayedResults) != 1 || replayedResults[0].Status != StatusAlreadySeen {
		t.Errorf("expected replayed purged event to be already_seen, got %v", replayedResults)
	}
	_, newTotal, _ := store.QueryEvents(ctx, QueryFilter{Page: 1, PageSize: 50})
	if newTotal != 0 {
		t.Errorf("expected raw event count to remain 0 after replay, got %d", newTotal)
	}

	newRecords := []TelemetryEnvelope{
		testEnvelope("evt-retention-new-1", "dev-retention"),
		testEnvelope("evt-retention-new-2", "dev-retention"),
		testEnvelope("evt-retention-new-3", "dev-retention"),
	}
	if _, err := store.IngestBatch(ctx, newRecords); err != nil {
		t.Fatalf("seed max-row retention records: %v", err)
	}
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
