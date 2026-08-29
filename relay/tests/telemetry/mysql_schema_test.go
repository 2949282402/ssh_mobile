package telemetry_test

import (
	"context"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestEnsureSchemaBackfillsMissingReceiptsBeforeUniqueIndex(t *testing.T) {
	db := openSchemaProbe(t)
	store := NewMySQLStore(db, DefaultCatalog())
	if err := store.EnsureSchema(context.Background()); err != nil {
		t.Fatalf("EnsureSchema: %v", err)
	}

	schemaProbe.mu.Lock()
	defer schemaProbe.mu.Unlock()
	var backfilled, uniqueIndex, binarySchema bool
	for _, query := range schemaProbe.execs {
		lower := strings.ToLower(query)
		backfilled = backfilled || strings.Contains(lower, "insert into telemetry_ingest_receipts") && strings.Contains(lower, "select e.event_id")
		uniqueIndex = uniqueIndex || strings.Contains(lower, "add unique key uq_telemetry_event_id")
		binarySchema = binarySchema || strings.Contains(lower, "event_id varbinary(64) not null")
	}
	if !backfilled {
		t.Fatal("schema migration did not backfill raw events missing receipts")
	}
	if !uniqueIndex {
		t.Fatal("schema migration did not restore the event-id unique index")
	}
	if !binarySchema {
		t.Fatal("telemetry schema DDL does not use exact binary event IDs")
	}
}

func TestEnsureSchemaAddsReleaseChannelOnlyForLegacyTables(t *testing.T) {
	db := openSchemaProbe(t)
	schemaProbe.mu.Lock()
	schemaProbe.releaseChannelColumn = false
	schemaProbe.mu.Unlock()
	store := NewMySQLStore(db, DefaultCatalog())
	if err := store.EnsureSchema(context.Background()); err != nil {
		t.Fatalf("EnsureSchema legacy release-channel column: %v", err)
	}

	schemaProbe.mu.Lock()
	var addCount int
	for _, query := range schemaProbe.execs {
		lower := strings.ToLower(query)
		if strings.Contains(lower, "add column release_channel") {
			addCount++
		}
		if strings.Contains(lower, "add column if not exists") && strings.Contains(lower, "release_channel") {
			schemaProbe.mu.Unlock()
			t.Fatalf("release-channel migration still relies on unsupported ADD COLUMN IF NOT EXISTS: %s", query)
		}
	}
	schemaProbe.mu.Unlock()
	if addCount != 1 {
		t.Fatalf("legacy release-channel column migration count = %d, want 1", addCount)
	}

	db = openSchemaProbe(t)
	store = NewMySQLStore(db, DefaultCatalog())
	if err := store.EnsureSchema(context.Background()); err != nil {
		t.Fatalf("EnsureSchema existing release-channel column: %v", err)
	}
	schemaProbe.mu.Lock()
	defer schemaProbe.mu.Unlock()
	for _, query := range schemaProbe.execs {
		if strings.Contains(strings.ToLower(query), "add column release_channel") {
			t.Fatalf("existing release-channel column was altered: %s", query)
		}
	}
}

func TestEnsureSchemaFailsExplicitlyOnDuplicateLegacyEventIDs(t *testing.T) {
	db := openSchemaProbe(t)
	schemaProbe.mu.Lock()
	schemaProbe.duplicateIDs = 1
	schemaProbe.mu.Unlock()
	store := NewMySQLStore(db, DefaultCatalog())
	if err := store.EnsureSchema(context.Background()); err == nil || !strings.Contains(err.Error(), "duplicate event ids") {
		t.Fatalf("EnsureSchema duplicate migration error = %v, want explicit duplicate event ids failure", err)
	}
	schemaProbe.mu.Lock()
	defer schemaProbe.mu.Unlock()
	for _, query := range schemaProbe.execs {
		if strings.Contains(strings.ToLower(query), "insert into telemetry_ingest_receipts") && strings.Contains(strings.ToLower(query), "select e.event_id") {
			t.Fatal("duplicate migration attempted receipt backfill before failing")
		}
	}
}

func TestEnsureSchemaMigratesLegacyTextEventIDColumnsToBinary(t *testing.T) {
	db := openSchemaProbe(t)
	schemaProbe.mu.Lock()
	schemaProbe.legacyColumn = true
	schemaProbe.mu.Unlock()
	store := NewMySQLStore(db, DefaultCatalog())
	if err := store.EnsureSchema(context.Background()); err != nil {
		t.Fatalf("EnsureSchema legacy column migration: %v", err)
	}
	schemaProbe.mu.Lock()
	defer schemaProbe.mu.Unlock()
	for _, table := range []string{"telemetry_events", "telemetry_ingest_receipts"} {
		want := "ALTER TABLE " + table + " MODIFY COLUMN event_id VARBINARY(64) NOT NULL"
		found := false
		for _, query := range schemaProbe.execs {
			if strings.EqualFold(strings.TrimSpace(query), want) {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("legacy schema did not migrate %s event_id with %q; execs=%#v", table, want, schemaProbe.execs)
		}
	}
}

func TestEnsureSchemaRepairsInvalidEventIDIndexShapes(t *testing.T) {
	valid := []driver.Value{int64(0), int64(1), "event_id", nil, "varbinary", int64(64), nil}
	cases := []struct {
		name string
		rows [][]driver.Value
	}{
		{
			name: "nonunique",
			rows: [][]driver.Value{{int64(1), int64(1), "event_id", nil, "varbinary", int64(64), nil}},
		},
		{
			name: "composite",
			rows: [][]driver.Value{valid, []driver.Value{int64(0), int64(2), "device_id", nil, "varchar", int64(512), "utf8mb4_unicode_ci"}},
		},
		{
			name: "prefix",
			rows: [][]driver.Value{{int64(0), int64(1), "event_id", int64(32), "varbinary", int64(64), nil}},
		},
		{
			name: "text collation",
			rows: [][]driver.Value{{int64(0), int64(1), "event_id", nil, "varchar", int64(256), "utf8mb4_bin"}},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			db := openSchemaProbe(t)
			schemaProbe.mu.Lock()
			schemaProbe.indexRows = tc.rows
			schemaProbe.mu.Unlock()
			store := NewMySQLStore(db, DefaultCatalog())
			if err := store.EnsureSchema(context.Background()); err != nil {
				t.Fatalf("EnsureSchema invalid %s index: %v", tc.name, err)
			}
			schemaProbe.mu.Lock()
			defer schemaProbe.mu.Unlock()
			var dropped, recreated bool
			for _, query := range schemaProbe.execs {
				lower := strings.ToLower(query)
				dropped = dropped || strings.Contains(lower, "drop index uq_telemetry_event_id")
				recreated = recreated || strings.Contains(lower, "add unique key uq_telemetry_event_id")
			}
			if !dropped || !recreated {
				t.Fatalf("invalid %s index was not safely replaced: dropped=%v recreated=%v execs=%#v", tc.name, dropped, recreated, schemaProbe.execs)
			}
		})
	}
}

func TestEnsureSchemaKeepsValidEventIDIndex(t *testing.T) {
	db := openSchemaProbe(t)
	schemaProbe.mu.Lock()
	schemaProbe.indexRows = [][]driver.Value{{int64(0), int64(1), "event_id", nil, "varbinary", int64(64), nil}}
	schemaProbe.mu.Unlock()
	store := NewMySQLStore(db, DefaultCatalog())
	if err := store.EnsureSchema(context.Background()); err != nil {
		t.Fatalf("EnsureSchema valid event-id index: %v", err)
	}
	schemaProbe.mu.Lock()
	defer schemaProbe.mu.Unlock()
	for _, query := range schemaProbe.execs {
		lower := strings.ToLower(query)
		if strings.Contains(lower, "drop index uq_telemetry_event_id") || strings.Contains(lower, "add unique key uq_telemetry_event_id") {
			t.Fatalf("valid event-id index was replaced: execs=%#v", schemaProbe.execs)
		}
	}
}

func TestEnsureSchemaRejectsMalformedEventIDIndexMetadata(t *testing.T) {
	db := openSchemaProbe(t)
	schemaProbe.mu.Lock()
	schemaProbe.indexRows = [][]driver.Value{{"not-a-number", int64(1), "event_id", nil, "varbinary", int64(64), nil}}
	schemaProbe.mu.Unlock()
	store := NewMySQLStore(db, DefaultCatalog())
	if err := store.EnsureSchema(context.Background()); err == nil || !strings.Contains(err.Error(), "inspect telemetry event id index") {
		t.Fatalf("malformed index metadata error = %v, want explicit inspection failure", err)
	}
	schemaProbe.mu.Lock()
	defer schemaProbe.mu.Unlock()
	for _, query := range schemaProbe.execs {
		if strings.Contains(strings.ToLower(query), "drop index uq_telemetry_event_id") {
			t.Fatal("malformed index metadata was dropped instead of failing explicitly")
		}
	}
}

func TestEnsureSchemaRejectsIncompleteEventIDIndexMetadata(t *testing.T) {
	db := openSchemaProbe(t)
	schemaProbe.mu.Lock()
	schemaProbe.indexRows = [][]driver.Value{{int64(0), int64(1), nil, nil, "varbinary", int64(64), nil}}
	schemaProbe.mu.Unlock()
	store := NewMySQLStore(db, DefaultCatalog())
	if err := store.EnsureSchema(context.Background()); err == nil || !strings.Contains(err.Error(), "required metadata is NULL") {
		t.Fatalf("incomplete index metadata error = %v, want explicit required-field failure", err)
	}
	schemaProbe.mu.Lock()
	defer schemaProbe.mu.Unlock()
	for _, query := range schemaProbe.execs {
		if strings.Contains(strings.ToLower(query), "drop index uq_telemetry_event_id") {
			t.Fatal("incomplete index metadata was dropped instead of failing explicitly")
		}
	}
}

func TestEnsureSchemaRejectsIndexMetadataQueryFailure(t *testing.T) {
	db := openSchemaProbe(t)
	schemaProbe.mu.Lock()
	schemaProbe.indexQueryErr = errors.New("index metadata unavailable")
	schemaProbe.mu.Unlock()
	store := NewMySQLStore(db, DefaultCatalog())
	if err := store.EnsureSchema(context.Background()); err == nil || !strings.Contains(err.Error(), "inspect telemetry event id index") {
		t.Fatalf("index metadata query error = %v, want explicit inspection failure", err)
	}
}

func TestEnsureSchemaAllowsReceiptOnlyRowsAndBackfillsMissingReceipts(t *testing.T) {
	db := openSchemaProbe(t)
	schemaProbe.mu.Lock()
	schemaProbe.receiptIDs = []string{"evt-retained-receipt"}
	schemaProbe.mu.Unlock()
	store := NewMySQLStore(db, DefaultCatalog())
	ctx := context.Background()
	if err := store.EnsureSchema(ctx); err != nil {
		t.Fatalf("EnsureSchema with receipt-only rows: %v", err)
	}
	acks, err := store.IngestBatch(ctx, []TelemetryEnvelope{testEnvelope("evt-retained-receipt", "device-1")})
	if err != nil {
		t.Fatalf("receipt-only replay after schema migration: %v", err)
	}
	if len(acks) != 1 || acks[0].EventID != "evt-retained-receipt" || acks[0].Status != StatusAlreadySeen {
		t.Fatalf("receipt-only replay ack = %#v, want exact already_seen result", acks)
	}
	schemaProbe.mu.Lock()
	defer schemaProbe.mu.Unlock()
	var backfilled bool
	for _, query := range schemaProbe.execs {
		lower := strings.ToLower(query)
		if strings.Contains(lower, "insert into telemetry_ingest_receipts") && strings.Contains(lower, "select e.event_id") {
			backfilled = true
		}
	}
	if !backfilled {
		t.Fatal("schema migration did not backfill raw events missing receipts while preserving receipt-only rows")
	}
	for _, query := range schemaProbe.execs {
		if strings.Contains(strings.ToLower(query), "insert into telemetry_events") {
			t.Fatalf("receipt-only replay attempted raw event insert: %s", query)
		}
	}
}
