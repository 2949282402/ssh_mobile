package telemetry_test

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
	mu                       sync.Mutex
	execs                    []string
	duplicateIDs             int64
	missingCalls             int
	legacyColumn             bool
	indexRows                [][]driver.Value
	indexQueryErr            error
	indexRowsIterErr         error
	indexRowsCloseErr        error
	indexRowsKeepOpen        bool
	receiptIDs               []string
	queryErrors              map[string]error
	execErrors               map[string]error
	receiptCoverageQueryErr  error
	receiptBackfillVerifyErr error
	releaseChannelColumn     bool
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
	s.indexRowsIterErr = nil
	s.indexRowsCloseErr = nil
	s.indexRowsKeepOpen = false
	s.receiptIDs = nil
	s.queryErrors = nil
	s.execErrors = nil
	s.receiptCoverageQueryErr = nil
	s.receiptBackfillVerifyErr = nil
	s.releaseChannelColumn = true
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
	c.state.mu.Lock()
	c.state.execs = append(c.state.execs, query)
	err := schemaProbeError(query, c.state.execErrors)
	c.state.mu.Unlock()
	return schemaProbeResult{}, err
}

func (c *schemaProbeConn) QueryContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	lower := strings.ToLower(query)
	c.state.mu.Lock()
	queryErr := schemaProbeError(lower, c.state.queryErrors)
	c.state.mu.Unlock()
	if queryErr != nil {
		return nil, queryErr
	}
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
		indexIterErr := c.state.indexRowsIterErr
		indexCloseErr := c.state.indexRowsCloseErr
		indexKeepOpen := c.state.indexRowsKeepOpen
		c.state.mu.Unlock()
		if indexErr != nil {
			return nil, indexErr
		}
		return &schemaProbeMultiRows{
			columns:  []string{"NON_UNIQUE", "SEQ_IN_INDEX", "COLUMN_NAME", "SUB_PART", "DATA_TYPE", "CHARACTER_OCTET_LENGTH", "COLLATION_NAME"},
			rows:     indexRows,
			err:      indexIterErr,
			closeErr: indexCloseErr,
			keepOpen: indexKeepOpen,
		}, nil
	case strings.Contains(lower, "information_schema.columns"):
		if strings.Contains(lower, "column_name = 'release_channel'") {
			c.state.mu.Lock()
			releaseChannel := c.state.releaseChannelColumn
			c.state.mu.Unlock()
			count := int64(0)
			if releaseChannel {
				count = 1
			}
			return &schemaProbeRows{columns: []string{"COUNT(*)"}, values: []driver.Value{count}}, nil
		}
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
		coverageErr := c.state.receiptCoverageQueryErr
		if call > 1 {
			coverageErr = c.state.receiptBackfillVerifyErr
		}
		c.state.mu.Unlock()
		if coverageErr != nil {
			return nil, coverageErr
		}
		missing := int64(1)
		if call > 1 {
			missing = 0
		}
		return &schemaProbeRows{columns: []string{"COUNT(*)"}, values: []driver.Value{missing}}, nil
	default:
		return &schemaProbeRows{}, nil
	}
}

func schemaProbeError(query string, configured map[string]error) error {
	query = strings.ToLower(query)
	for fragment, err := range configured {
		if strings.Contains(query, fragment) {
			return err
		}
	}
	return nil
}

type schemaProbeRows struct {
	columns []string
	values  []driver.Value
	done    bool
}

type schemaProbeMultiRows struct {
	columns  []string
	rows     [][]driver.Value
	index    int
	err      error
	closeErr error
	keepOpen bool
}

func (r *schemaProbeMultiRows) Columns() []string { return r.columns }

func (r *schemaProbeMultiRows) Close() error { return r.closeErr }

func (r *schemaProbeMultiRows) HasNextResultSet() bool { return r.keepOpen }

func (*schemaProbeMultiRows) NextResultSet() error { return io.EOF }

func (r *schemaProbeMultiRows) Next(dest []driver.Value) error {
	if r.index >= len(r.rows) {
		if r.err != nil {
			err := r.err
			r.err = nil
			return err
		}
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
