package telemetry_test

import (
	"context"
	"database/sql"
	"os"
	"testing"
	"time"

	_ "github.com/go-sql-driver/mysql"
	. "github.com/ssh-mobile/relay/internal/telemetry"
)

// telemetryTestMySQLDSN follows the dedicated telemetry override first, then
// the shared Relay test DSN used by CI. The telemetry tables are independent
// of the Relay tables, so sharing the test database keeps the integration gate
// useful without requiring another service or a CI-only environment variable.
func telemetryTestMySQLDSN(t *testing.T) string {
	t.Helper()
	for _, name := range []string{
		"TELEMETRY_TEST_MYSQL_DSN",
		"TELEMETRY_MYSQL_DSN",
		"RELAY_TEST_MYSQL_DSN",
	} {
		if dsn := os.Getenv(name); dsn != "" {
			return dsn
		}
	}
	t.Skip("TELEMETRY_TEST_MYSQL_DSN, TELEMETRY_MYSQL_DSN, or RELAY_TEST_MYSQL_DSN not set; skipping MySQL integration test")
	return ""
}

func openTelemetryMySQLOrSkip(t *testing.T) (*MySQLStore, string) {
	t.Helper()
	dsn := telemetryTestMySQLDSN(t)
	store, err := NewMySQLStoreFromDSN(dsn, DefaultCatalog())
	if err != nil {
		t.Fatalf("open telemetry MySQL store: %v", err)
	}
	return store, dsn
}

func openTelemetryMySQLDB(t *testing.T, dsn string) *sql.DB {
	t.Helper()
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatalf("open telemetry MySQL cleanup connection: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// cleanupTelemetryMySQL removes every event, receipt, and credential created
// by one integration test. Cleanup uses a separate SQL handle after the public
// MySQLStore is closed because Store intentionally exposes no destructive
// production API for test housekeeping.
func cleanupTelemetryMySQL(t *testing.T, dsn string, eventIDs, deviceIDs []string) {
	t.Helper()
	db := openTelemetryMySQLDB(t, dsn)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Errorf("begin telemetry MySQL cleanup: %v", err)
		return
	}
	rollback := func() { _ = tx.Rollback() }
	for _, eventID := range eventIDs {
		if _, err := tx.ExecContext(ctx, "DELETE FROM telemetry_ingest_receipts WHERE event_id = ?", eventID); err != nil {
			rollback()
			t.Errorf("delete telemetry receipt %q: %v", eventID, err)
			return
		}
		if _, err := tx.ExecContext(ctx, "DELETE FROM telemetry_events WHERE event_id = ?", eventID); err != nil {
			rollback()
			t.Errorf("delete telemetry event %q: %v", eventID, err)
			return
		}
	}
	for _, deviceID := range deviceIDs {
		if _, err := tx.ExecContext(ctx, "DELETE FROM telemetry_device_credentials WHERE device_id = ?", deviceID); err != nil {
			rollback()
			t.Errorf("delete telemetry credential %q: %v", deviceID, err)
			return
		}
	}
	if err := tx.Commit(); err != nil {
		t.Errorf("commit telemetry MySQL cleanup: %v", err)
	}
}
