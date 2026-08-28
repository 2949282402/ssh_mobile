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
	mu           sync.Mutex
	execs        []string
	duplicateIDs int64
	missingCalls int
	legacyColumn bool
}

func (s *schemaProbeState) reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.execs = nil
	s.duplicateIDs = 0
	s.missingCalls = 0
	s.legacyColumn = false
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

func (*schemaProbeConn) Begin() (driver.Tx, error) {
	return nil, errors.New("schema probe does not use transactions")
}

func (c *schemaProbeConn) ExecContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Result, error) {
	c.state.recordExec(query)
	return schemaProbeResult{}, nil
}

func (c *schemaProbeConn) QueryContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	lower := strings.ToLower(query)
	switch {
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
	case strings.Contains(lower, "information_schema.statistics"):
		return &schemaProbeRows{columns: []string{"COUNT(*)"}, values: []driver.Value{int64(0)}}, nil
	default:
		return &schemaProbeRows{}, nil
	}
}

type schemaProbeRows struct {
	columns []string
	values  []driver.Value
	done    bool
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
