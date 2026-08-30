package telemetry_test

import (
	"context"
	"database/sql"
	"errors"
	"strconv"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestMySQLStoreSettingsAndCredentialsRoundTrip(t *testing.T) {
	store, dsn := openTelemetryMySQLOrSkip(t)
	unique := strconv.FormatInt(time.Now().UnixNano(), 10)
	deviceID := "dev-mysql-store-" + unique
	defer func() {
		_ = store.Close()
		cleanupTelemetryMySQL(t, dsn, nil, []string{deviceID})
	}()

	ctx := context.Background()
	settingsDB := openTelemetryMySQLDB(t, dsn)
	var originalJSON string
	var originalUpdatedAt time.Time
	err := settingsDB.QueryRowContext(ctx, "SELECT settings_json, updated_at FROM telemetry_settings WHERE id = 1").Scan(&originalJSON, &originalUpdatedAt)
	hadSettings := true
	if errors.Is(err, sql.ErrNoRows) {
		hadSettings = false
	} else if err != nil {
		t.Fatalf("read original telemetry settings: %v", err)
	}
	defer func() {
		if hadSettings {
			if _, err := settingsDB.ExecContext(ctx, "UPDATE telemetry_settings SET settings_json = ?, updated_at = ? WHERE id = 1", originalJSON, originalUpdatedAt); err != nil {
				t.Errorf("restore telemetry settings: %v", err)
			}
			return
		}
		if _, err := settingsDB.ExecContext(ctx, "DELETE FROM telemetry_settings WHERE id = 1"); err != nil {
			t.Errorf("remove test telemetry settings: %v", err)
		}
	}()

	initial, err := store.GetSettings(ctx)
	if err != nil {
		t.Fatalf("get initial telemetry settings: %v", err)
	}
	updated := *initial
	updated.Policy.BatchSizeThreshold++
	updated.RetentionDays++
	updated.RedisMaxRecords++
	if err := store.SaveSettings(ctx, updated); err != nil {
		t.Fatalf("save telemetry settings: %v", err)
	}
	persisted, err := store.GetSettings(ctx)
	if err != nil {
		t.Fatalf("get persisted telemetry settings: %v", err)
	}
	if persisted.Policy.BatchSizeThreshold != updated.Policy.BatchSizeThreshold ||
		persisted.RetentionDays != updated.RetentionDays || persisted.RedisMaxRecords != updated.RedisMaxRecords ||
		persisted.UpdatedAt.IsZero() {
		t.Fatalf("persisted telemetry settings = %#v, want updated values %#v", persisted, updated)
	}
	invalid := TelemetrySettings{
		Policy: TelemetryUploadPolicy{
			BatchSizeThreshold:    0,
			TimeIntervalSeconds:   0,
			MaxBatchSize:          0,
			ClientMaxLocalRecords: 0,
		},
		RetentionDays:    0,
		RetentionMaxRows: 0,
		RedisMaxRecords:  0,
	}
	if err := store.SaveSettings(ctx, invalid); err != nil {
		t.Fatalf("save invalid telemetry settings: %v", err)
	}
	sanitized, err := store.GetSettings(ctx)
	if err != nil {
		t.Fatalf("get sanitized telemetry settings: %v", err)
	}
	if sanitized.Policy.BatchSizeThreshold != 50 || sanitized.Policy.TimeIntervalSeconds != 60 ||
		sanitized.Policy.MaxBatchSize != 100 || sanitized.Policy.ClientMaxLocalRecords != 10000 ||
		sanitized.RetentionDays != 30 || sanitized.RetentionMaxRows != 500000 || sanitized.RedisMaxRecords != 1000 ||
		sanitized.UpdatedAt.IsZero() {
		t.Fatalf("sanitized telemetry settings = %#v, want safe defaults", sanitized)
	}

	if _, err := store.GetDeviceCredential(ctx, deviceID); !errors.Is(err, ErrDeviceCredentialNotFound) {
		t.Fatalf("missing telemetry credential error = %v, want ErrDeviceCredentialNotFound", err)
	}
	if err := store.RegisterDeviceCredential(ctx, deviceID, "hash-one"); err != nil {
		t.Fatalf("register telemetry credential: %v", err)
	}
	if got, err := store.GetDeviceCredential(ctx, deviceID); err != nil || got != "hash-one" {
		t.Fatalf("registered telemetry credential = %q, err=%v, want hash-one", got, err)
	}
	if err := store.RegisterDeviceCredential(ctx, deviceID, "hash-two"); err != nil {
		t.Fatalf("update telemetry credential: %v", err)
	}
	if got, err := store.GetDeviceCredential(ctx, deviceID); err != nil || got != "hash-two" {
		t.Fatalf("updated telemetry credential = %q, err=%v, want hash-two", got, err)
	}
}

func TestMySQLRetentionPurgesRawEventsKeepsReceipts(t *testing.T) {
	store, dsn := openTelemetryMySQLOrSkip(t)
	unique := strconv.FormatInt(time.Now().UnixNano(), 10)
	deviceID := "dev-mysql-retention-receipts-" + unique
	ids := []string{
		"evt-mysql-retention-" + unique,
		"EVT-MYSQL-RETENTION-" + unique,
		"evt-mysql-retention-third-" + unique,
		"evt-mysql-retention-fourth-" + unique,
		"evt-mysql-retention-fifth-" + unique,
	}
	defer func() {
		_ = store.Close()
		cleanupTelemetryMySQL(t, dsn, ids, []string{deviceID})
	}()

	ctx := context.Background()
	records := make([]TelemetryEnvelope, 0, len(ids))
	for _, eventID := range ids {
		records = append(records, testEnvelope(eventID, deviceID))
	}
	accepted, err := store.IngestBatch(ctx, records)
	if err != nil {
		t.Fatalf("seed retention records: %v", err)
	}
	for i, ack := range accepted {
		if ack.EventID != ids[i] || ack.Status != StatusAccepted {
			t.Fatalf("seed retention ack[%d] = %#v, want accepted %q", i, ack, ids[i])
		}
	}

	deleted, err := store.PurgeRetention(ctx, time.Time{}, 2, 2)
	if err != nil {
		t.Fatalf("purge retention by max rows: %v", err)
	}
	if deleted != len(ids)-2 {
		t.Fatalf("max-row retention deleted %d rows, want %d", deleted, len(ids)-2)
	}
	rows, total, err := store.QueryEvents(ctx, QueryFilter{DeviceID: deviceID, Page: 1, PageSize: 10})
	if err != nil {
		t.Fatalf("query retained rows: %v", err)
	}
	if total != 2 || len(rows) != 2 {
		t.Fatalf("retained rows total=%d len=%d, want 2/2", total, len(rows))
	}

	replayed, err := store.IngestBatch(ctx, records)
	if err != nil {
		t.Fatalf("replay after max-row retention: %v", err)
	}
	for i, ack := range replayed {
		if ack.EventID != ids[i] || ack.Status != StatusAlreadySeen {
			t.Fatalf("post-retention replay ack[%d] = %#v, want already_seen %q", i, ack, ids[i])
		}
	}

	db := openTelemetryMySQLDB(t, dsn)
	var receiptCount int
	if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM telemetry_ingest_receipts WHERE device_id = ?", deviceID).Scan(&receiptCount); err != nil {
		t.Fatalf("count retained receipts: %v", err)
	}
	if receiptCount != len(ids) {
		t.Fatalf("retention removed receipts: got %d, want %d", receiptCount, len(ids))
	}

	timeCutoff := time.Now().UTC().Add(time.Hour)
	deleted, err = store.PurgeRetention(ctx, timeCutoff, 0, 2)
	if err != nil {
		t.Fatalf("purge remaining rows by time: %v", err)
	}
	if deleted != 2 {
		t.Fatalf("time retention deleted %d rows, want 2", deleted)
	}
}

func TestMySQLQueryEventsSupportsAllFilters(t *testing.T) {
	store, dsn := openTelemetryMySQLOrSkip(t)
	unique := strconv.FormatInt(time.Now().UnixNano(), 10)
	deviceID := "dev-mysql-query-filters-" + unique
	eventID := "evt-mysql-query-filters-" + unique
	defer func() {
		_ = store.Close()
		cleanupTelemetryMySQL(t, dsn, []string{eventID}, []string{deviceID})
	}()

	record := testEnvelope(eventID, deviceID)
	record.RecordType = RecordTypeDiagnostic
	record.EventName = "ssh.session.failed"
	record.Severity = SeverityError
	record.Properties = map[string]any{"stage": "query"}
	record.Error = &TelemetryError{ErrorCode: "SSH_AUTH_FAILED", Category: "ssh", TerminalFailure: true}
	// Direct Store callers use the zero-value compatibility path; the Service
	// stamps an authoritative server receive time before calling the Store.
	record.ReceivedAt = time.Time{}
	start := time.Now().UTC().Add(-time.Second)
	if acks, err := store.IngestBatch(context.Background(), []TelemetryEnvelope{record}); err != nil {
		t.Fatalf("seed filter record: %v", err)
	} else if len(acks) != 1 || acks[0].Status != StatusAccepted {
		t.Fatalf("filter record ack = %#v, want accepted", acks)
	}
	end := time.Now().UTC().Add(time.Second)

	rows, total, err := store.QueryEvents(context.Background(), QueryFilter{
		RecordType: RecordTypeDiagnostic,
		DeviceID:   deviceID,
		TraceID:    record.TraceID,
		EventName:  record.EventName,
		Feature:    record.Feature,
		Severity:   record.Severity,
		ErrorCode:  record.Error.ErrorCode,
		AppVersion: record.AppVersion,
		Platform:   record.Platform,
		StartTime:  start,
		EndTime:    end,
		Page:       1,
		PageSize:   1,
	})
	if err != nil {
		t.Fatalf("query all telemetry filters: %v", err)
	}
	if total != 1 || len(rows) != 1 || rows[0].EventID != eventID {
		t.Fatalf("all-filter query total=%d rows=%#v, want one event %q", total, rows, eventID)
	}
}
