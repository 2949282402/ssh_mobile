package telemetry_test

import (
	"context"
	"strconv"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestMySQLEnsureSchemaSupportsOnlyFullGroupBy(t *testing.T) {
	dsn := telemetryTestMySQLDSN(t)
	db := openTelemetryMySQLDB(t, dsn)
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	ctx := context.Background()
	if _, err := db.ExecContext(ctx, "SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY'"); err != nil {
		t.Fatalf("enable ONLY_FULL_GROUP_BY for schema regression: %v", err)
	}

	store := NewMySQLStore(db, DefaultCatalog())
	unique := strconv.FormatInt(time.Now().UnixNano(), 10)
	deviceID := "dev-schema-case-" + unique
	eventIDs := []string{"evt-schema-case-" + unique, "EVT-SCHEMA-CASE-" + unique}
	defer func() {
		_ = store.Close()
		cleanupTelemetryMySQL(t, dsn, eventIDs, []string{deviceID})
	}()
	if err := store.EnsureSchema(ctx); err != nil {
		t.Fatalf("EnsureSchema with ONLY_FULL_GROUP_BY: %v", err)
	}

	records := []TelemetryEnvelope{testEnvelope(eventIDs[0], deviceID), testEnvelope(eventIDs[1], deviceID)}
	accepted, err := store.IngestBatch(ctx, records)
	if err != nil {
		t.Fatalf("ingest case-sensitive event IDs: %v", err)
	}
	for i, ack := range accepted {
		if ack.EventID != eventIDs[i] || ack.Status != StatusAccepted {
			t.Fatalf("case-sensitive ingest ack[%d] = %#v, want accepted %q", i, ack, eventIDs[i])
		}
	}

	replayed, err := store.IngestBatch(ctx, records)
	if err != nil {
		t.Fatalf("replay case-sensitive event IDs: %v", err)
	}
	for i, ack := range replayed {
		if ack.EventID != eventIDs[i] || ack.Status != StatusAlreadySeen {
			t.Fatalf("case-sensitive replay ack[%d] = %#v, want already_seen %q", i, ack, eventIDs[i])
		}
	}
}
