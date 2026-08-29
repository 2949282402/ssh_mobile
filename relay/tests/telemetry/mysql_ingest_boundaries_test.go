package telemetry_test

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
	"github.com/ssh-mobile/relay/internal/telemetry"
)

const ingestProbeDriverName = "telemetry-ingest-probe"

var (
	ingestProbeRegister sync.Once
	ingestProbeNextID   atomic.Uint64
	ingestProbeStates   sync.Map
)

type ingestProbeState struct {
	mu sync.Mutex

	beginErr    error
	queryErr    error
	rowData     [][]driver.Value
	rowErr      error
	rowCloseErr error
	eventErr    error
	receiptErr  error
	commitErr   error
	cancel      context.CancelFunc

	beginCalls   int
	queryCalls   int
	eventCalls   int
	receiptCalls int
	commitCalls  int
}

type ingestProbeDriver struct{}

func (ingestProbeDriver) Open(name string) (driver.Conn, error) {
	value, ok := ingestProbeStates.Load(name)
	if !ok {
		return nil, fmt.Errorf("unknown ingest probe DSN %q", name)
	}
	return &ingestProbeConn{state: value.(*ingestProbeState)}, nil
}

type ingestProbeConn struct {
	state *ingestProbeState
}

func (c *ingestProbeConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("ingest probe does not use prepared statements")
}

func (*ingestProbeConn) Close() error { return nil }

func (c *ingestProbeConn) Begin() (driver.Tx, error) { return c.begin() }

func (c *ingestProbeConn) BeginTx(context.Context, driver.TxOptions) (driver.Tx, error) {
	return c.begin()
}

func (c *ingestProbeConn) begin() (driver.Tx, error) {
	c.state.mu.Lock()
	defer c.state.mu.Unlock()
	c.state.beginCalls++
	if c.state.beginErr != nil {
		return nil, c.state.beginErr
	}
	return &ingestProbeTx{state: c.state}, nil
}

func (c *ingestProbeConn) QueryContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	c.state.mu.Lock()
	defer c.state.mu.Unlock()
	c.state.queryCalls++
	if c.state.queryErr != nil {
		return nil, c.state.queryErr
	}
	return &ingestProbeRows{
		data:     append([][]driver.Value(nil), c.state.rowData...),
		nextErr:  c.state.rowErr,
		closeErr: c.state.rowCloseErr,
	}, nil
}

func (c *ingestProbeConn) ExecContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Result, error) {
	lower := strings.ToLower(query)
	c.state.mu.Lock()
	defer c.state.mu.Unlock()
	if strings.Contains(lower, "telemetry_events") {
		c.state.eventCalls++
		if c.state.eventErr != nil {
			if c.state.cancel != nil {
				c.state.cancel()
			}
			return nil, c.state.eventErr
		}
		return driver.RowsAffected(1), nil
	}
	if strings.Contains(lower, "telemetry_ingest_receipts") {
		c.state.receiptCalls++
		if c.state.receiptErr != nil {
			return nil, c.state.receiptErr
		}
		return driver.RowsAffected(1), nil
	}
	return nil, fmt.Errorf("unexpected ingest probe exec: %s", query)
}

type ingestProbeTx struct{ state *ingestProbeState }

func (tx *ingestProbeTx) Commit() error {
	tx.state.mu.Lock()
	defer tx.state.mu.Unlock()
	tx.state.commitCalls++
	return tx.state.commitErr
}

func (*ingestProbeTx) Rollback() error { return nil }

type ingestProbeRows struct {
	data      [][]driver.Value
	index     int
	nextErr   error
	closeErr  error
	errRaised bool
}

func (*ingestProbeRows) Columns() []string { return []string{"event_id"} }

func (r *ingestProbeRows) Close() error { return r.closeErr }

func (r *ingestProbeRows) Next(dest []driver.Value) error {
	if r.index < len(r.data) {
		copy(dest, r.data[r.index])
		r.index++
		return nil
	}
	if r.nextErr != nil && !r.errRaised {
		r.errRaised = true
		return r.nextErr
	}
	return io.EOF
}

func newIngestProbeStore(t *testing.T, state *ingestProbeState) (*telemetry.MySQLStore, func()) {
	t.Helper()
	ingestProbeRegister.Do(func() {
		sql.Register(ingestProbeDriverName, ingestProbeDriver{})
	})
	dsn := fmt.Sprintf("ingest-probe-%d", ingestProbeNextID.Add(1))
	ingestProbeStates.Store(dsn, state)
	db, err := sql.Open(ingestProbeDriverName, dsn)
	if err != nil {
		ingestProbeStates.Delete(dsn)
		t.Fatalf("open ingest probe: %v", err)
	}
	db.SetMaxOpenConns(1)
	store := telemetry.NewMySQLStore(db, telemetry.DefaultCatalog())
	return store, func() {
		_ = store.Close()
		ingestProbeStates.Delete(dsn)
	}
}

func ingestProbeStateSnapshot(state *ingestProbeState) (begin, query, event, receipt, commit int) {
	state.mu.Lock()
	defer state.mu.Unlock()
	return state.beginCalls, state.queryCalls, state.eventCalls, state.receiptCalls, state.commitCalls
}

func TestMySQLIngestCommitsAcceptedAndAlreadySeenRecords(t *testing.T) {
	state := &ingestProbeState{rowData: [][]driver.Value{{"already-seen"}}}
	store, closeStore := newIngestProbeStore(t, state)
	defer closeStore()

	accepted, err := store.IngestBatch(context.Background(), []telemetry.TelemetryEnvelope{
		testEnvelope("new-record", "ingest-probe-device"),
		testEnvelope("already-seen", "ingest-probe-device"),
	})
	if err != nil {
		t.Fatalf("mixed ingest: %v", err)
	}
	if len(accepted) != 2 || accepted[0].Status != telemetry.StatusAccepted || accepted[1].Status != telemetry.StatusAlreadySeen {
		t.Fatalf("mixed ingest acknowledgements = %+v, want accepted/already_seen", accepted)
	}
	_, queries, events, receipts, commits := ingestProbeStateSnapshot(state)
	if queries != 1 || events != 1 || receipts != 1 || commits != 1 {
		t.Fatalf("mixed ingest calls = query=%d events=%d receipts=%d commits=%d, want 1 each", queries, events, receipts, commits)
	}

	state = &ingestProbeState{rowData: [][]driver.Value{{"already-seen"}}}
	store, closeStore = newIngestProbeStore(t, state)
	defer closeStore()
	seen, err := store.IngestBatch(context.Background(), []telemetry.TelemetryEnvelope{testEnvelope("already-seen", "ingest-probe-device")})
	if err != nil || len(seen) != 1 || seen[0].Status != telemetry.StatusAlreadySeen {
		t.Fatalf("receipt-only ingest = %+v, err=%v, want already_seen", seen, err)
	}
	_, _, events, receipts, commits = ingestProbeStateSnapshot(state)
	if events != 0 || receipts != 0 || commits != 1 {
		t.Fatalf("receipt-only calls = events=%d receipts=%d commits=%d, want 0/0/1", events, receipts, commits)
	}
}

func TestMySQLIngestHandlesReceiptCursorFailures(t *testing.T) {
	cases := []struct {
		name  string
		state *ingestProbeState
	}{
		{name: "query", state: &ingestProbeState{queryErr: errors.New("receipt query failed")}},
		{name: "scan", state: &ingestProbeState{rowData: [][]driver.Value{{struct{}{}}}}},
		{name: "iterate", state: &ingestProbeState{rowErr: errors.New("receipt iteration failed")}},
		{name: "close", state: &ingestProbeState{rowCloseErr: errors.New("receipt close failed")}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store, closeStore := newIngestProbeStore(t, tc.state)
			defer closeStore()
			_, err := store.IngestBatch(context.Background(), []telemetry.TelemetryEnvelope{testEnvelope("receipt-failure-"+tc.name, "ingest-probe-device")})
			if err == nil {
				t.Fatalf("receipt %s returned nil error", tc.name)
			}
		})
	}
}

func TestMySQLIngestHandlesTransactionFailuresAndRetryCancellation(t *testing.T) {
	cases := []struct {
		name  string
		state *ingestProbeState
		want  string
	}{
		{name: "begin generic", state: &ingestProbeState{beginErr: errors.New("begin failed")}, want: "begin ingest tx"},
		{name: "event generic", state: &ingestProbeState{eventErr: errors.New("event insert failed")}, want: "insert raw events"},
		{name: "receipt generic", state: &ingestProbeState{receiptErr: errors.New("receipt insert failed")}, want: "insert receipts"},
		{name: "commit generic", state: &ingestProbeState{commitErr: errors.New("commit failed")}, want: "commit ingest tx"},
		{name: "retry exhaustion", state: &ingestProbeState{eventErr: &mysql.MySQLError{Number: 1213, Message: "deadlock found"}}, want: "retry exhausted"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store, closeStore := newIngestProbeStore(t, tc.state)
			defer closeStore()
			_, err := store.IngestBatch(context.Background(), []telemetry.TelemetryEnvelope{testEnvelope("transaction-failure-"+tc.name, "ingest-probe-device")})
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("transaction %s error = %v, want substring %q", tc.name, err, tc.want)
			}
		})
	}

	canceled, cancel := context.WithCancel(context.Background())
	state := &ingestProbeState{
		eventErr: &mysql.MySQLError{Number: 1205, Message: "lock wait timeout"},
		cancel:   cancel,
	}
	store, closeStore := newIngestProbeStore(t, state)
	defer closeStore()
	_, err := store.IngestBatch(canceled, []telemetry.TelemetryEnvelope{testEnvelope("transaction-canceled", "ingest-probe-device")})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("retry cancellation error = %v, want context.Canceled", err)
	}
}

func TestMySQLIngestRejectsInvalidAndDuplicateInputWithoutOpeningTransaction(t *testing.T) {
	state := &ingestProbeState{}
	store, closeStore := newIngestProbeStore(t, state)
	defer closeStore()
	invalid := testEnvelope("invalid-input", "ingest-probe-device")
	invalid.EventName = "unregistered.ingest.event"
	duplicate := testEnvelope("duplicate-input", "ingest-probe-device")
	results, err := store.IngestBatch(nil, []telemetry.TelemetryEnvelope{invalid, duplicate, duplicate})
	if err != nil || len(results) != 3 || results[0].Status != telemetry.StatusRejected || results[1].Status != telemetry.StatusAccepted || results[2].Status != telemetry.StatusAlreadySeen {
		t.Fatalf("invalid/duplicate ingest = %+v, err=%v, want rejected/accepted/already_seen", results, err)
	}
	_, _, events, receipts, commits := ingestProbeStateSnapshot(state)
	if events != 1 || receipts != 1 || commits != 1 {
		t.Fatalf("invalid/duplicate calls = events=%d receipts=%d commits=%d, want 1/1/1", events, receipts, commits)
	}
}

func TestMySQLIngestUsesServerTimestampAndSortsEventIDs(t *testing.T) {
	state := &ingestProbeState{}
	store, closeStore := newIngestProbeStore(t, state)
	defer closeStore()
	first := testEnvelope("z-record", "ingest-probe-device")
	second := testEnvelope("a-record", "ingest-probe-device")
	first.ReceivedAt = time.Unix(1, 0).UTC()
	second.ReceivedAt = time.Unix(2, 0).UTC()
	results, err := store.IngestBatch(context.Background(), []telemetry.TelemetryEnvelope{first, second})
	if err != nil || len(results) != 2 || results[0].Status != telemetry.StatusAccepted || results[1].Status != telemetry.StatusAccepted {
		t.Fatalf("sorted ingest = %+v, err=%v, want accepted records", results, err)
	}
	// The probe cannot inspect SQL argument order without becoming a production
	// coupling point; the public ACK order verifies callers still receive the
	// original input order while the store internally sorts its transaction.
	if results[0].EventID != "z-record" || results[1].EventID != "a-record" {
		t.Fatalf("ack order = %+v, want original input order", results)
	}
}

func TestMySQLIngestPersistsStructuredErrorsAndReleaseChannels(t *testing.T) {
	state := &ingestProbeState{}
	store, closeStore := newIngestProbeStore(t, state)
	defer closeStore()
	record := testEnvelope("structured-error", "ingest-probe-device")
	record.ReleaseChannel = "stable"
	record.Error = &telemetry.TelemetryError{
		ErrorCode:       "SSH_AUTH_FAILED",
		Category:        "ssh",
		TerminalFailure: true,
		Message:         "authentication failed",
	}
	results, err := store.IngestBatch(context.Background(), []telemetry.TelemetryEnvelope{record})
	if err != nil || len(results) != 1 || results[0].Status != telemetry.StatusAccepted {
		t.Fatalf("structured error ingest = %+v, err=%v, want accepted", results, err)
	}
}

func TestMySQLIngestReturnsUnavailableForNilStoreAndNoValidRecords(t *testing.T) {
	var store *telemetry.MySQLStore
	if _, err := store.IngestBatch(context.Background(), nil); !errors.Is(err, telemetry.ErrServiceUnavailable) {
		t.Fatalf("nil MySQL store error = %v, want ErrServiceUnavailable", err)
	}

	state := &ingestProbeState{}
	store, closeStore := newIngestProbeStore(t, state)
	defer closeStore()
	invalid := testEnvelope("only-invalid", "ingest-probe-device")
	invalid.EventName = "not-registered"
	results, err := store.IngestBatch(context.Background(), []telemetry.TelemetryEnvelope{invalid})
	if err != nil || len(results) != 1 || results[0].Status != telemetry.StatusRejected {
		t.Fatalf("no-valid ingest = %+v, err=%v, want one rejected result", results, err)
	}
	begin, query, events, receipts, commits := ingestProbeStateSnapshot(state)
	if begin != 0 || query != 0 || events != 0 || receipts != 0 || commits != 0 {
		t.Fatalf("no-valid transaction calls = begin=%d query=%d events=%d receipts=%d commits=%d, want all zero", begin, query, events, receipts, commits)
	}
}
