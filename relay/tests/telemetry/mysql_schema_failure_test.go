package telemetry_test

import (
	"context"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestEnsureSchemaHandlesPublicFailurePaths(t *testing.T) {
	tests := []struct {
		name       string
		configure  func()
		wantErr    string
		wantNoErr  bool
		nilContext bool
	}{
		{
			name:       "nil context defaults to background",
			configure:  func() {},
			wantNoErr:  true,
			nilContext: true,
		},
		{
			name:      "ddl failure",
			configure: func() { schemaProbe.execErrors = map[string]error{"create table": errors.New("ddl unavailable")} },
			wantErr:   "failed executing telemetry schema DDL",
		},
		{
			name: "event id column inspection failure",
			configure: func() {
				schemaProbe.queryErrors = map[string]error{"column_name = 'event_id'": errors.New("column metadata unavailable")}
			},
			wantErr: "inspect telemetry_events event id column",
		},
		{
			name: "legacy event id alteration failure",
			configure: func() {
				schemaProbe.legacyColumn = true
				schemaProbe.execErrors = map[string]error{"alter table telemetry_events modify column": errors.New("alter unavailable")}
			},
			wantErr: "migrate telemetry_events event id column to exact binary",
		},
		{
			name: "duplicate event id check failure",
			configure: func() {
				schemaProbe.queryErrors = map[string]error{"duplicate_event_ids": errors.New("duplicate check unavailable")}
			},
			wantErr: "check duplicate telemetry event ids",
		},
		{
			name:      "receipt coverage check failure",
			configure: func() { schemaProbe.receiptCoverageQueryErr = errors.New("receipt coverage unavailable") },
			wantErr:   "check telemetry receipt coverage",
		},
		{
			name: "receipt backfill failure",
			configure: func() {
				schemaProbe.execErrors = map[string]error{"insert into telemetry_ingest_receipts": errors.New("backfill unavailable")}
			},
			wantErr: "backfill 1 missing telemetry ingest receipts",
		},
		{
			name:      "receipt backfill verification failure",
			configure: func() { schemaProbe.receiptBackfillVerifyErr = errors.New("verification unavailable") },
			wantErr:   "verify telemetry receipt backfill",
		},
		{
			name: "index drop failure",
			configure: func() {
				schemaProbe.indexRows = [][]driver.Value{{int64(1), int64(1), "event_id", nil, "varbinary", int64(64), nil}}
				schemaProbe.execErrors = map[string]error{"drop index uq_telemetry_event_id": errors.New("drop unavailable")}
			},
			wantErr: "replace invalid telemetry event id index: drop existing index",
		},
		{
			name: "index add failure",
			configure: func() {
				schemaProbe.indexRows = [][]driver.Value{{int64(1), int64(1), "event_id", nil, "varbinary", int64(64), nil}}
				schemaProbe.execErrors = map[string]error{"add unique key uq_telemetry_event_id": errors.New("add unavailable")}
			},
			wantErr: "add telemetry event id index",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			db := openSchemaProbe(t)
			schemaProbe.mu.Lock()
			tc.configure()
			schemaProbe.mu.Unlock()
			store := NewMySQLStore(db, DefaultCatalog())
			if tc.nilContext {
				store = NewMySQLStore(db, nil)
			}
			ctx := context.Background()
			if tc.nilContext {
				ctx = nil
			}
			err := store.EnsureSchema(ctx)
			if tc.wantNoErr {
				if err != nil {
					t.Fatalf("EnsureSchema: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("EnsureSchema error = %v, want %q", err, tc.wantErr)
			}
		})
	}
}

func TestEnsureSchemaRejectsUnavailableStore(t *testing.T) {
	var store *MySQLStore
	if err := store.EnsureSchema(nil); err == nil || !strings.Contains(err.Error(), "store is unavailable") {
		t.Fatalf("nil store EnsureSchema error = %v, want unavailable error", err)
	}
}

func TestEnsureSchemaRejectsMalformedIndexMetadata(t *testing.T) {
	tests := []struct {
		name string
		row  []driver.Value
		want string
	}{
		{
			name: "negative required value",
			row:  []driver.Value{int64(-1), int64(1), "event_id", nil, "varbinary", int64(64), nil},
			want: "malformed required metadata",
		},
		{
			name: "zero prefix",
			row:  []driver.Value{int64(0), int64(1), "event_id", int64(0), "varbinary", int64(64), nil},
			want: "malformed prefix metadata",
		},
		{
			name: "empty collation",
			row:  []driver.Value{int64(0), int64(1), "event_id", nil, "varbinary", int64(64), ""},
			want: "malformed collation metadata",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			db := openSchemaProbe(t)
			schemaProbe.mu.Lock()
			schemaProbe.indexRows = [][]driver.Value{tc.row}
			schemaProbe.mu.Unlock()
			err := NewMySQLStore(db, DefaultCatalog()).EnsureSchema(context.Background())
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("EnsureSchema error = %v, want %q", err, tc.want)
			}
		})
	}
}

func TestEnsureSchemaReportsIndexIterationAndCloseFailures(t *testing.T) {
	tests := []struct {
		name     string
		iterErr  error
		closeErr error
		keepOpen bool
		want     string
	}{
		{name: "iteration", iterErr: errors.New("index rows failed"), want: "iterate metadata"},
		{name: "close", closeErr: errors.New("index rows close failed"), keepOpen: true, want: "close metadata"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			db := openSchemaProbe(t)
			schemaProbe.mu.Lock()
			schemaProbe.indexRows = [][]driver.Value{{int64(0), int64(1), "event_id", nil, "varbinary", int64(64), nil}}
			schemaProbe.indexRowsIterErr = tc.iterErr
			schemaProbe.indexRowsCloseErr = tc.closeErr
			schemaProbe.indexRowsKeepOpen = tc.keepOpen
			schemaProbe.mu.Unlock()
			err := NewMySQLStore(db, DefaultCatalog()).EnsureSchema(context.Background())
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("EnsureSchema error = %v, want %q", err, tc.want)
			}
		})
	}
}
