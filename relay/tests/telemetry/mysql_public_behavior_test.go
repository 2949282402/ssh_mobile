package telemetry_test

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestMySQLStoreMultiRowRoundTripPreservesNullJSONAndRowShape(t *testing.T) {
	store, dsn := openTelemetryMySQLOrSkip(t)
	unique := strconv.FormatInt(time.Now().UnixNano(), 10)
	deviceID := "dev-mysql-row-shape-" + unique
	ids := []string{"evt-mysql-null-" + unique, "evt-mysql-json-" + unique}
	defer func() {
		_ = store.Close()
		cleanupTelemetryMySQL(t, dsn, ids, []string{deviceID})
	}()

	withoutJSON := testEnvelope(ids[0], deviceID)
	withoutJSON.Properties = nil
	withoutJSON.Error = nil
	withJSON := testEnvelope(ids[1], deviceID)
	withJSON.RecordType = RecordTypeDiagnostic
	withJSON.EventName = "ssh.session.failed"
	withJSON.Severity = SeverityError
	withJSON.Properties = map[string]any{
		"stage":       "handshake",
		"retry_count": int64(2),
	}
	withJSON.Error = &TelemetryError{
		ErrorCode:       "SSH_AUTH_FAILED",
		Category:        "ssh",
		TerminalFailure: true,
		Message:         "redacted test failure",
		StackTrace:      "redacted test stack",
	}

	results, err := store.IngestBatch(context.Background(), []TelemetryEnvelope{withoutJSON, withJSON})
	if err != nil {
		t.Fatalf("multi-row MySQL ingest: %v", err)
	}
	if len(results) != 2 || results[0].Status != StatusAccepted || results[1].Status != StatusAccepted {
		t.Fatalf("multi-row MySQL results = %#v, want two accepted rows", results)
	}

	rows, total, err := store.QueryEvents(context.Background(), QueryFilter{DeviceID: deviceID, Page: 1, PageSize: 10})
	if err != nil {
		t.Fatalf("query multi-row MySQL events: %v", err)
	}
	if total != 2 || len(rows) != 2 {
		t.Fatalf("multi-row MySQL query total=%d len=%d, want 2/2", total, len(rows))
	}
	byID := make(map[string]TelemetryEnvelope, len(rows))
	for _, row := range rows {
		byID[row.EventID] = row
	}
	nullRow, ok := byID[ids[0]]
	if !ok {
		t.Fatalf("multi-row query omitted NULL JSON row: %#v", rows)
	}
	if nullRow.Properties != nil || nullRow.Error != nil {
		t.Fatalf("NULL JSON columns decoded as non-nil: properties=%#v error=%#v", nullRow.Properties, nullRow.Error)
	}
	jsonRow, ok := byID[ids[1]]
	if !ok {
		t.Fatalf("multi-row query omitted JSON row: %#v", rows)
	}
	if jsonRow.RecordType != RecordTypeDiagnostic || jsonRow.EventName != withJSON.EventName ||
		jsonRow.Severity != SeverityError || jsonRow.Properties["stage"] != "handshake" ||
		jsonRow.Properties["retry_count"] != float64(2) {
		t.Fatalf("JSON row shape changed: %#v", jsonRow)
	}
	if jsonRow.Error == nil || jsonRow.Error.ErrorCode != "SSH_AUTH_FAILED" ||
		jsonRow.Error.Category != "ssh" || !jsonRow.Error.TerminalFailure ||
		jsonRow.Error.Message != "redacted test failure" || jsonRow.Error.StackTrace != "redacted test stack" {
		t.Fatalf("structured error row changed: %#v", jsonRow.Error)
	}
	if nullRow.ReceivedAt.IsZero() || jsonRow.ReceivedAt.IsZero() {
		t.Fatal("MySQL rows did not receive trusted receive timestamps")
	}

	diagnostics, diagnosticTotal, err := store.QueryDiagnostics(context.Background(), QueryFilter{DeviceID: deviceID, Page: 1, PageSize: 10})
	if err != nil {
		t.Fatalf("query multi-row diagnostics: %v", err)
	}
	if diagnosticTotal != 1 || len(diagnostics) != 1 || diagnostics[0].EventID != ids[1] {
		t.Fatalf("diagnostics row shape total=%d rows=%#v, want one structured row", diagnosticTotal, diagnostics)
	}
}

func TestMySQLIngestRetriesDeadlockAndLockWaitConflicts(t *testing.T) {
	for _, code := range []int{1213, 1205} {
		t.Run(strconv.Itoa(code), func(t *testing.T) {
			store, dsn := openTelemetryMySQLOrSkip(t)
			unique := strconv.FormatInt(time.Now().UnixNano(), 10)
			deviceID := "dev-mysql-retry-" + strconv.Itoa(code) + "-" + unique
			eventID := "evt-mysql-retry-" + strconv.Itoa(code) + "-" + unique
			defer func() {
				_ = store.Close()
				cleanupTelemetryMySQL(t, dsn, []string{eventID}, []string{deviceID})
			}()

			db := openTelemetryMySQLDB(t, dsn)
			trigger := "telemetry_retry_" + strconv.Itoa(code) + "_" + unique
			createTrigger := fmt.Sprintf(
				"CREATE TRIGGER `%s` BEFORE INSERT ON telemetry_events FOR EACH ROW SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO = %d, MESSAGE_TEXT = 'telemetry retry conflict'",
				trigger, code,
			)
			if _, err := db.ExecContext(context.Background(), createTrigger); err != nil {
				if strings.Contains(strings.ToLower(err.Error()), "super privilege") {
					t.Skipf("test MySQL user cannot create conflict trigger: %v", err)
				}
				t.Fatalf("create MySQL %d conflict trigger: %v", code, err)
			}
			defer func() {
				if _, err := db.ExecContext(context.Background(), "DROP TRIGGER IF EXISTS `"+trigger+"`"); err != nil {
					t.Errorf("drop MySQL conflict trigger %q: %v", trigger, err)
				}
			}()

			_, err := store.IngestBatch(context.Background(), []TelemetryEnvelope{testEnvelope(eventID, deviceID)})
			if err == nil {
				t.Fatalf("MySQL %d conflict unexpectedly accepted", code)
			}
			if !strings.Contains(strings.ToLower(err.Error()), "retry exhausted after 3 attempts") {
				t.Fatalf("MySQL %d conflict error = %v, want bounded retry exhaustion", code, err)
			}
		})
	}
}

func TestMySQLRetentionKeepsRecordAtAgeBoundary(t *testing.T) {
	store, dsn := openTelemetryMySQLOrSkip(t)
	unique := strconv.FormatInt(time.Now().UnixNano(), 10)
	deviceID := "dev-mysql-retention-boundary-" + unique
	ids := []string{"evt-mysql-retention-old-" + unique, "evt-mysql-retention-boundary-" + unique}
	defer func() {
		_ = store.Close()
		cleanupTelemetryMySQL(t, dsn, ids, []string{deviceID})
	}()

	records := []TelemetryEnvelope{testEnvelope(ids[0], deviceID), testEnvelope(ids[1], deviceID)}
	if results, err := store.IngestBatch(context.Background(), records); err != nil {
		t.Fatalf("seed MySQL retention records: %v", err)
	} else if len(results) != len(records) || results[0].Status != StatusAccepted || results[1].Status != StatusAccepted {
		t.Fatalf("seed MySQL retention results = %#v", results)
	}

	db := openTelemetryMySQLDB(t, dsn)
	cutoff := time.Now().UTC().Truncate(time.Millisecond).Add(2 * time.Second)
	oldAt := cutoff.Add(-time.Millisecond)
	if _, err := db.ExecContext(context.Background(), "UPDATE telemetry_events SET received_at = ? WHERE event_id = ?", oldAt, ids[0]); err != nil {
		t.Fatalf("set old MySQL retention timestamp: %v", err)
	}
	if _, err := db.ExecContext(context.Background(), "UPDATE telemetry_events SET received_at = ? WHERE event_id = ?", cutoff, ids[1]); err != nil {
		t.Fatalf("set boundary MySQL retention timestamp: %v", err)
	}

	deleted, err := store.PurgeRetention(context.Background(), cutoff, 0, 10)
	if err != nil {
		t.Fatalf("purge MySQL retention boundary: %v", err)
	}
	if deleted != 1 {
		t.Fatalf("purge deleted %d rows, want only record strictly older than cutoff", deleted)
	}
	rows, total, err := store.QueryEvents(context.Background(), QueryFilter{DeviceID: deviceID, Page: 1, PageSize: 10})
	if err != nil {
		t.Fatalf("query retained MySQL boundary row: %v", err)
	}
	if total != 1 || len(rows) != 1 || rows[0].EventID != ids[1] {
		t.Fatalf("retention boundary rows total=%d rows=%#v, want boundary row %q", total, rows, ids[1])
	}
	if rows[0].ReceivedAt.Before(cutoff) {
		t.Fatalf("retained boundary row timestamp %s is before cutoff %s", rows[0].ReceivedAt, cutoff)
	}
}
