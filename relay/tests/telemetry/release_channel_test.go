package telemetry_test

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func releaseChannelEnvelope(eventID, releaseChannel string) TelemetryEnvelope {
	return TelemetryEnvelope{
		EventID:        eventID,
		RecordType:     RecordTypeAnalytics,
		EventName:      "ssh.session.started",
		EventVersion:   1,
		DeviceID:       "release-channel-device",
		SessionID:      "release-channel-session",
		TraceID:        "release-channel-trace-" + eventID,
		OccurredAt:     time.Now().UTC(),
		Feature:        "ssh",
		Severity:       SeverityInfo,
		AppVersion:     "1.0.0",
		BuildNumber:    "1",
		Platform:       "linux",
		ReleaseChannel: releaseChannel,
		Properties:     map[string]any{"session_type": "interactive"},
	}
}

func TestTelemetryReleaseChannelRoundTripsAndFiltersMemoryStore(t *testing.T) {
	original := releaseChannelEnvelope("release-beta", "beta")
	encoded, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	var decoded TelemetryEnvelope
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatalf("unmarshal envelope: %v", err)
	}
	if decoded.ReleaseChannel != "beta" {
		t.Fatalf("release channel = %q, want beta", decoded.ReleaseChannel)
	}

	legacyJSON := map[string]any{}
	if err := json.Unmarshal(encoded, &legacyJSON); err != nil {
		t.Fatalf("decode envelope map: %v", err)
	}
	delete(legacyJSON, "releaseChannel")
	legacyEncoded, err := json.Marshal(legacyJSON)
	if err != nil {
		t.Fatalf("marshal legacy envelope: %v", err)
	}
	var legacy TelemetryEnvelope
	if err := json.Unmarshal(legacyEncoded, &legacy); err != nil {
		t.Fatalf("unmarshal legacy envelope: %v", err)
	}
	if legacy.ReleaseChannel != "" {
		t.Fatalf("legacy release channel = %q, want empty compatibility value", legacy.ReleaseChannel)
	}

	store := NewMemoryStore(DefaultCatalog())
	if _, err := store.IngestBatch(context.Background(), []TelemetryEnvelope{
		releaseChannelEnvelope("release-prod", "prod"),
		original,
	}); err != nil {
		t.Fatalf("ingest release channel records: %v", err)
	}
	filtered, total, err := store.QueryEvents(context.Background(), QueryFilter{
		ReleaseChannel: "beta",
		Page:           1,
		PageSize:       50,
	})
	if err != nil {
		t.Fatalf("query release channel records: %v", err)
	}
	if total != 1 || len(filtered) != 1 || filtered[0].ReleaseChannel != "beta" {
		t.Fatalf("filtered records = %#v, total = %d; want one beta record", filtered, total)
	}

	overview, err := store.QueryOverview(context.Background(), QueryFilter{ReleaseChannel: "beta"})
	if err != nil {
		t.Fatalf("query release channel overview: %v", err)
	}
	if overview.TotalEvents != 1 {
		t.Fatalf("overview total events = %d, want 1", overview.TotalEvents)
	}
}

func TestTelemetryReleaseChannelPersistsAndFiltersMySQL(t *testing.T) {
	store, dsn := openTelemetryMySQLOrSkip(t)
	deviceID := "release-channel-mysql-device"
	ids := []string{
		"release-mysql-" + strconv.FormatInt(time.Now().UnixNano(), 10),
	}
	defer func() {
		_ = store.Close()
		cleanupTelemetryMySQL(t, dsn, ids, nil)
	}()

	if results, err := store.IngestBatch(context.Background(), []TelemetryEnvelope{
		releaseChannelEnvelope(ids[0], "beta"),
	}); err != nil {
		t.Fatalf("ingest MySQL release channel record: %v", err)
	} else if len(results) != 1 || results[0].Status != StatusAccepted {
		t.Fatalf("MySQL release channel ACK = %#v, want accepted", results)
	}

	rows, total, err := store.QueryEvents(context.Background(), QueryFilter{
		DeviceID:       deviceID,
		ReleaseChannel: "beta",
		Page:           1,
		PageSize:       10,
	})
	if err != nil {
		t.Fatalf("query MySQL release channel record: %v", err)
	}
	if total != 0 || len(rows) != 0 {
		t.Fatalf("query with mismatched device returned rows=%#v total=%d", rows, total)
	}

	rows, total, err = store.QueryEvents(context.Background(), QueryFilter{
		ReleaseChannel: "beta",
		Page:           1,
		PageSize:       10,
	})
	if err != nil {
		t.Fatalf("query MySQL release channel records: %v", err)
	}
	if total != 1 || len(rows) != 1 || rows[0].ReleaseChannel != "beta" {
		t.Fatalf("MySQL rows = %#v total=%d, want one beta record", rows, total)
	}
}
