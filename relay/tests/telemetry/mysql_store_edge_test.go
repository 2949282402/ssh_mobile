package telemetry_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	_ "github.com/go-sql-driver/mysql"
	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestMySQLStoreIngestRejectsBoundedAndInvalidPublicInputs(t *testing.T) {
	store, dsn := openTelemetryMySQLOrSkip(t)
	defer store.Close()
	defer cleanupTelemetryMySQL(t, dsn, []string{"evt-mysql-edge-duplicate"}, nil)

	tooLarge := make([]TelemetryEnvelope, MaxIngestBatchSize+1)
	if _, err := store.IngestBatch(context.Background(), tooLarge); !errors.Is(err, ErrIngestBatchTooLarge) {
		t.Fatalf("oversized MySQL ingest error = %v, want ErrIngestBatchTooLarge", err)
	}
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := store.IngestBatch(canceled, []TelemetryEnvelope{testEnvelope("evt-mysql-edge-canceled", "dev-mysql-edge")}); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled MySQL ingest error = %v, want context.Canceled", err)
	}
	if results, err := store.IngestBatch(nil, nil); err != nil || len(results) != 0 {
		t.Fatalf("nil-context empty ingest = %#v, err=%v, want empty success", results, err)
	}
	invalid := testEnvelope("evt-mysql-edge-invalid", "dev-mysql-edge")
	invalid.EventName = "unregistered.mysql.edge"
	results, err := store.IngestBatch(context.Background(), []TelemetryEnvelope{invalid})
	if err != nil || len(results) != 1 || results[0].Status != StatusRejected {
		t.Fatalf("invalid MySQL ingest = %#v, err=%v, want per-record rejection", results, err)
	}

	duplicate := testEnvelope("evt-mysql-edge-duplicate", "dev-mysql-edge")
	results, err = store.IngestBatch(context.Background(), []TelemetryEnvelope{duplicate, duplicate})
	if err != nil || len(results) != 2 || results[0].Status != StatusAccepted || results[1].Status != StatusAlreadySeen {
		t.Fatalf("duplicate MySQL ingest = %#v, err=%v, want accepted/already_seen", results, err)
	}

	marshalFailure := testEnvelope("evt-mysql-edge-marshal", "dev-mysql-edge")
	marshalFailure.Properties["session_type"] = func() {}
	results, err = store.IngestBatch(context.Background(), []TelemetryEnvelope{marshalFailure})
	if err != nil || len(results) != 1 || results[0].Status != StatusRejected || !strings.Contains(results[0].Reason, "invalid type") {
		t.Fatalf("unmarshalable MySQL properties = %#v, err=%v, want validation rejection", results, err)
	}
}

func TestMySQLStoreClosedConnectionFailsClosed(t *testing.T) {
	dsn := telemetryTestMySQLDSN(t)
	db := openTelemetryMySQLDB(t, dsn)
	store := NewMySQLStore(db, nil)
	if err := db.Close(); err != nil {
		t.Fatalf("close MySQL test connection: %v", err)
	}
	ctx := context.Background()
	if _, err := store.IngestBatch(ctx, []TelemetryEnvelope{testEnvelope("evt-mysql-closed", "dev-mysql-closed")}); err == nil || !strings.Contains(err.Error(), "begin ingest tx") {
		t.Fatalf("closed MySQL ingest error = %v, want begin transaction error", err)
	}
	if _, _, err := store.QueryEvents(ctx, QueryFilter{}); err == nil || !strings.Contains(err.Error(), "count events query") {
		t.Fatalf("closed MySQL events error = %v, want count query error", err)
	}
	if _, err := store.GetSettings(ctx); err == nil || !strings.Contains(err.Error(), "get telemetry settings") {
		t.Fatalf("closed MySQL settings error = %v, want settings query error", err)
	}
	if err := store.SaveSettings(ctx, DefaultSettings()); err == nil {
		t.Fatal("closed MySQL settings save unexpectedly succeeded")
	}
	if deleted, err := store.PurgeRetention(ctx, time.Time{}, 0, 0); err != nil || deleted != 0 {
		t.Fatalf("closed MySQL no-op retention = %d, err=%v, want zero success", deleted, err)
	}
	if _, err := store.PurgeRetention(ctx, time.Now(), 0, 1); err == nil || !strings.Contains(err.Error(), "purge by time error") {
		t.Fatalf("closed MySQL time purge error = %v, want time purge error", err)
	}
	if _, err := store.PurgeRetention(ctx, time.Time{}, 1, 1); err == nil || !strings.Contains(err.Error(), "count for maxRows purge") {
		t.Fatalf("closed MySQL max-row purge error = %v, want count error", err)
	}
	if err := store.RegisterDeviceCredential(ctx, "dev-mysql-closed", "hash"); err == nil {
		t.Fatal("closed MySQL credential registration unexpectedly succeeded")
	}
	if _, err := store.GetDeviceCredential(ctx, "dev-mysql-closed"); err == nil {
		t.Fatal("closed MySQL credential lookup unexpectedly succeeded")
	}
	if _, err := NewMySQLStoreFromDSN("not-a-valid-mysql-dsn", nil); err == nil || !strings.Contains(err.Error(), "open mysql error") {
		t.Fatalf("invalid MySQL DSN error = %v, want open error", err)
	}
	if _, err := NewMySQLStoreFromDSN("telemetry:telemetry@tcp(127.0.0.1:1)/telemetry?parseTime=true", nil); err == nil || !strings.Contains(err.Error(), "ping mysql error") {
		t.Fatalf("unreachable MySQL DSN error = %v, want ping error", err)
	}
}
