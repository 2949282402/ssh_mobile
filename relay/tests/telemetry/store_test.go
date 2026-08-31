package telemetry_test

import (
	"context"
	"errors"
	"strconv"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestTelemetryCredentialStoresAreCreateOnly(t *testing.T) {
	store := NewMemoryStore(DefaultCatalog())
	if err := store.CreateDeviceCredential(context.Background(), "device-create-only", "hash-one"); err != nil {
		t.Fatalf("first create failed: %v", err)
	}
	if err := store.CreateDeviceCredential(context.Background(), "device-create-only", "hash-two"); !errors.Is(err, ErrDeviceCredentialAlreadyExists) {
		t.Fatalf("second create error = %v, want ErrDeviceCredentialAlreadyExists", err)
	}
	stored, err := store.GetDeviceCredential(context.Background(), "device-create-only")
	if err != nil || stored != "hash-one" {
		t.Fatalf("create-only store changed existing hash: value=%q err=%v", stored, err)
	}
}

func TestMySQLTelemetryCredentialStoreCreateOnlyWhenDSNAvailable(t *testing.T) {
	store, dsn := openTelemetryMySQLOrSkip(t)
	deviceID := "test-create-only-mysql-" + strconv.FormatInt(time.Now().UnixNano(), 10)
	defer func() {
		_ = store.Close()
		cleanupTelemetryMySQL(t, dsn, nil, []string{deviceID})
	}()
	if err := store.CreateDeviceCredential(context.Background(), deviceID, "hash-one"); err != nil {
		t.Fatalf("first MySQL create failed: %v", err)
	}
	if err := store.CreateDeviceCredential(context.Background(), deviceID, "hash-two"); !errors.Is(err, ErrDeviceCredentialAlreadyExists) {
		t.Fatalf("second MySQL create error = %v, want ErrDeviceCredentialAlreadyExists", err)
	}
	stored, err := store.GetDeviceCredential(context.Background(), deviceID)
	if err != nil || stored != "hash-one" {
		t.Fatalf("MySQL create-only store changed existing hash: value=%q err=%v", stored, err)
	}
}

func TestTelemetryStoreIngestAndIdempotency(t *testing.T) {
	ctx := context.Background()
	catalog := DefaultCatalog()
	store := NewMemoryStore(catalog)

	now := time.Now().UTC()

	records := []TelemetryEnvelope{
		{
			EventID:      "evt-001",
			RecordType:   RecordTypeAnalytics,
			EventName:    "ssh.session.started",
			EventVersion: 1,
			DeviceID:     "dev-1",
			SessionID:    "sess-1",
			TraceID:      "trace-1",
			OccurredAt:   now.Add(-10 * time.Second),
			Feature:      "ssh",
			Severity:     SeverityInfo,
			AppVersion:   "1.0.0",
			BuildNumber:  "100",
			Platform:     "android",
			Properties:   map[string]any{"session_type": "interactive"},
		},
		{
			EventID:      "evt-002",
			RecordType:   RecordTypeDiagnostic,
			EventName:    "ssh.session.failed",
			EventVersion: 1,
			DeviceID:     "dev-1",
			SessionID:    "sess-1",
			TraceID:      "trace-1",
			OccurredAt:   now.Add(-5 * time.Second),
			Feature:      "ssh",
			Severity:     SeverityError,
			AppVersion:   "1.0.0",
			BuildNumber:  "100",
			Platform:     "android",
			Error: &TelemetryError{
				ErrorCode:       "SSH_AUTH_FAILED",
				Category:        "ssh",
				TerminalFailure: true,
			},
		},
		{
			EventID:      "evt-003-invalid",
			RecordType:   RecordTypeAnalytics,
			EventName:    "unregistered.event.name",
			EventVersion: 1,
			DeviceID:     "dev-1",
			SessionID:    "sess-1",
			TraceID:      "trace-1",
			OccurredAt:   now,
			Feature:      "unknown",
			Severity:     SeverityInfo,
			AppVersion:   "1.0.0",
			BuildNumber:  "100",
			Platform:     "android",
		},
	}

	// 1. Ingest batch
	results, err := store.IngestBatch(ctx, records)
	if err != nil {
		t.Fatalf("IngestBatch failed: %v", err)
	}

	if len(results) != 3 {
		t.Fatalf("expected 3 results, got %d", len(results))
	}

	if results[0].Status != StatusAccepted {
		t.Errorf("expected evt-001 to be accepted, got %s (reason: %s)", results[0].Status, results[0].Reason)
	}
	if results[1].Status != StatusAccepted {
		t.Errorf("expected evt-002 to be accepted, got %s (reason: %s)", results[1].Status, results[1].Reason)
	}
	if results[2].Status != StatusRejected {
		t.Errorf("expected evt-003-invalid to be rejected, got %s", results[2].Status)
	}

	// 2. Replay batch with same eventIds -> MUST return already_seen for accepted records
	replayResults, err := store.IngestBatch(ctx, records[:2])
	if err != nil {
		t.Fatalf("Replay IngestBatch failed: %v", err)
	}

	for _, res := range replayResults {
		if res.Status != StatusAlreadySeen {
			t.Errorf("expected replayed event %s to be already_seen, got %s", res.EventID, res.Status)
		}
	}

	// 3. Verify total raw records count in store (should be exactly 2, rejected not stored, replay didn't duplicate)
	events, total, err := store.QueryEvents(ctx, QueryFilter{Page: 1, PageSize: 50})
	if err != nil {
		t.Fatalf("QueryEvents failed: %v", err)
	}
	if total != 2 || len(events) != 2 {
		t.Errorf("expected total 2 events in store, got total=%d len=%d", total, len(events))
	}
}

func TestTelemetryStoreUnifiedFilters(t *testing.T) {
	ctx := context.Background()
	catalog := DefaultCatalog()
	store := NewMemoryStore(catalog)

	now := time.Now().UTC()

	records := []TelemetryEnvelope{
		{
			EventID:      "evt-android-ssh",
			RecordType:   RecordTypeAnalytics,
			EventName:    "ssh.session.started",
			EventVersion: 1,
			DeviceID:     "dev-android",
			SessionID:    "sess-1",
			TraceID:      "trace-1",
			OccurredAt:   now.Add(-1 * time.Hour),
			Feature:      "ssh",
			Severity:     SeverityInfo,
			AppVersion:   "1.0.0",
			BuildNumber:  "100",
			Platform:     "android",
			Properties:   map[string]any{"session_type": "interactive"},
		},
		{
			EventID:      "evt-ios-sftp",
			RecordType:   RecordTypeAnalytics,
			EventName:    "sftp.transfer.completed",
			EventVersion: 1,
			DeviceID:     "dev-ios",
			SessionID:    "sess-2",
			TraceID:      "trace-2",
			OccurredAt:   now.Add(-30 * time.Minute),
			Feature:      "sftp",
			Severity:     SeverityInfo,
			AppVersion:   "2.0.0",
			BuildNumber:  "200",
			Platform:     "ios",
			Properties:   map[string]any{"direction": "upload", "bytes_transferred": 2048},
		},
	}

	_, _ = store.IngestBatch(ctx, records)

	// Filter by DeviceID
	res1, total1, err := store.QueryEvents(ctx, QueryFilter{DeviceID: "dev-android", Page: 1, PageSize: 50})
	if err != nil || total1 != 1 || res1[0].EventID != "evt-android-ssh" {
		t.Errorf("filter by device failed: total=%d err=%v", total1, err)
	}

	// Filter by Platform
	res2, total2, err := store.QueryEvents(ctx, QueryFilter{Platform: "ios", Page: 1, PageSize: 50})
	if err != nil || total2 != 1 || res2[0].EventID != "evt-ios-sftp" {
		t.Errorf("filter by platform failed: total=%d err=%v", total2, err)
	}

	// Filter by Feature
	res3, total3, err := store.QueryEvents(ctx, QueryFilter{Feature: "sftp", Page: 1, PageSize: 50})
	if err != nil || total3 != 1 || res3[0].EventID != "evt-ios-sftp" {
		t.Errorf("filter by feature failed: total=%d err=%v", total3, err)
	}
}
