package telemetry

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
)

const schemaProbeDriverName = "telemetry-schema-probe"

var registerSchemaProbeDriver sync.Once
var schemaProbe schemaProbeState

type schemaProbeState struct {
	mu            sync.Mutex
	execs         []string
	duplicateIDs  int64
	missingCalls  int
	legacyColumn  bool
	indexRows     [][]driver.Value
	indexQueryErr error
	receiptIDs    []string
}

func (s *schemaProbeState) reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.execs = nil
	s.duplicateIDs = 0
	s.missingCalls = 0
	s.legacyColumn = false
	s.indexRows = nil
	s.indexQueryErr = nil
	s.receiptIDs = nil
}

func (s *schemaProbeState) recordExec(query string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.execs = append(s.execs, query)
}

type schemaProbeDriver struct{}

func (schemaProbeDriver) Open(string) (driver.Conn, error) {
	return &schemaProbeConn{state: &schemaProbe}, nil
}

type schemaProbeConn struct {
	state *schemaProbeState
}

func (*schemaProbeConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("schema probe does not use prepared statements")
}

func (*schemaProbeConn) Close() error { return nil }

func (c *schemaProbeConn) Begin() (driver.Tx, error) {
	return &schemaProbeTx{conn: c}, nil
}

type schemaProbeTx struct {
	conn *schemaProbeConn
}

func (*schemaProbeTx) Commit() error   { return nil }
func (*schemaProbeTx) Rollback() error { return nil }

func (c *schemaProbeConn) ExecContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Result, error) {
	c.state.recordExec(query)
	return schemaProbeResult{}, nil
}

func (c *schemaProbeConn) QueryContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	lower := strings.ToLower(query)
	switch {
	case strings.Contains(lower, "select event_id from telemetry_ingest_receipts"):
		c.state.mu.Lock()
		receiptIDs := append([]string(nil), c.state.receiptIDs...)
		c.state.mu.Unlock()
		rows := make([][]driver.Value, 0, len(receiptIDs))
		for _, eventID := range receiptIDs {
			rows = append(rows, []driver.Value{eventID})
		}
		return &schemaProbeMultiRows{columns: []string{"event_id"}, rows: rows}, nil
	case strings.Contains(lower, "information_schema.statistics"):
		c.state.mu.Lock()
		indexRows := append([][]driver.Value(nil), c.state.indexRows...)
		indexErr := c.state.indexQueryErr
		c.state.mu.Unlock()
		if indexErr != nil {
			return nil, indexErr
		}
		return &schemaProbeMultiRows{
			columns: []string{"NON_UNIQUE", "SEQ_IN_INDEX", "COLUMN_NAME", "SUB_PART", "DATA_TYPE", "CHARACTER_OCTET_LENGTH", "COLLATION_NAME"},
			rows:    indexRows,
		}, nil
	case strings.Contains(lower, "information_schema.columns"):
		c.state.mu.Lock()
		dataType := "varbinary"
		if c.state.legacyColumn {
			dataType = "varchar"
		}
		c.state.mu.Unlock()
		return &schemaProbeRows{
			columns: []string{"DATA_TYPE", "CHARACTER_OCTET_LENGTH"},
			values:  []driver.Value{dataType, int64(64)},
		}, nil
	case strings.Contains(lower, "duplicate_event_ids"):
		c.state.mu.Lock()
		duplicate := c.state.duplicateIDs
		c.state.mu.Unlock()
		return &schemaProbeRows{columns: []string{"COUNT(*)"}, values: []driver.Value{duplicate}}, nil
	case strings.Contains(lower, "left join telemetry_ingest_receipts"):
		c.state.mu.Lock()
		c.state.missingCalls++
		call := c.state.missingCalls
		c.state.mu.Unlock()
		missing := int64(1)
		if call > 1 {
			missing = 0
		}
		return &schemaProbeRows{columns: []string{"COUNT(*)"}, values: []driver.Value{missing}}, nil
	default:
		return &schemaProbeRows{}, nil
	}
}

type schemaProbeRows struct {
	columns []string
	values  []driver.Value
	done    bool
}

type schemaProbeMultiRows struct {
	columns []string
	rows    [][]driver.Value
	index   int
}

func (r *schemaProbeMultiRows) Columns() []string { return r.columns }

func (*schemaProbeMultiRows) Close() error { return nil }

func (r *schemaProbeMultiRows) Next(dest []driver.Value) error {
	if r.index >= len(r.rows) {
		return io.EOF
	}
	copy(dest, r.rows[r.index])
	r.index++
	return nil
}

func (r *schemaProbeRows) Columns() []string { return r.columns }

func (*schemaProbeRows) Close() error { return nil }

func (r *schemaProbeRows) Next(dest []driver.Value) error {
	if r.done {
		return io.EOF
	}
	r.done = true
	copy(dest, r.values)
	return nil
}

type schemaProbeResult struct{}

func (schemaProbeResult) LastInsertId() (int64, error) { return 0, nil }
func (schemaProbeResult) RowsAffected() (int64, error) { return 0, nil }

func openSchemaProbe(t *testing.T) *sql.DB {
	t.Helper()
	registerSchemaProbeDriver.Do(func() {
		sql.Register(schemaProbeDriverName, schemaProbeDriver{})
	})
	schemaProbe.reset()
	db, err := sql.Open(schemaProbeDriverName, "")
	if err != nil {
		t.Fatalf("open schema probe: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

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
