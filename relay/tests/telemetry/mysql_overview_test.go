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

	"github.com/ssh-mobile/relay/internal/telemetry"
)

const overviewProbeDriverName = "telemetry-overview-probe"

var (
	overviewProbeRegister sync.Once
	overviewProbeNextID   atomic.Uint64
	overviewProbeStates   sync.Map
)

type overviewProbeState struct {
	mode     string
	mu       sync.Mutex
	trendSQL []string
	pingErr  error
}

type overviewProbeDriver struct{}

func (overviewProbeDriver) Open(name string) (driver.Conn, error) {
	value, ok := overviewProbeStates.Load(name)
	if !ok {
		return nil, fmt.Errorf("unknown overview probe DSN %q", name)
	}
	return &overviewProbeConn{state: value.(*overviewProbeState)}, nil
}

type overviewProbeConn struct {
	state *overviewProbeState
}

func (*overviewProbeConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("overview probe does not use prepared statements")
}

func (*overviewProbeConn) Close() error { return nil }

func (*overviewProbeConn) Begin() (driver.Tx, error) {
	return nil, errors.New("overview probe does not use transactions")
}

func (c *overviewProbeConn) Ping(context.Context) error {
	return c.state.pingErr
}

func (c *overviewProbeConn) QueryContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	return c.state.query(query)
}

func (c *overviewProbeConn) ExecContext(context.Context, string, []driver.NamedValue) (driver.Result, error) {
	return nil, errors.New("overview probe does not execute statements")
}

func newOverviewProbeStore(t *testing.T, mode string) (*telemetry.MySQLStore, *overviewProbeState, func()) {
	return newOverviewProbeStoreWithCatalog(t, mode, telemetry.DefaultCatalog())
}

func newOverviewProbeStoreWithCatalog(t *testing.T, mode string, catalog *telemetry.Catalog) (*telemetry.MySQLStore, *overviewProbeState, func()) {
	t.Helper()
	overviewProbeRegister.Do(func() {
		sql.Register(overviewProbeDriverName, overviewProbeDriver{})
	})
	dsn := fmt.Sprintf("overview-probe-%d", overviewProbeNextID.Add(1))
	state := &overviewProbeState{mode: mode}
	if mode == "ping-error" {
		state.pingErr = errors.New("ping failed")
	}
	overviewProbeStates.Store(dsn, state)
	db, err := sql.Open(overviewProbeDriverName, dsn)
	if err != nil {
		t.Fatalf("open overview probe: %v", err)
	}
	store := telemetry.NewMySQLStore(db, catalog)
	return store, state, func() {
		_ = store.Close()
		overviewProbeStates.Delete(dsn)
	}
}

func (s *overviewProbeState) query(query string) (driver.Rows, error) {
	lower := strings.ToLower(query)
	switch {
	case s.mode == "count-values" && !strings.Contains(lower, "date_format") && strings.Contains(lower, "count(distinct session_id") && strings.Contains(lower, "severity"):
		return &overviewProbeRows{columns: []string{"COUNT(*)"}, data: [][]driver.Value{{int64(1)}}}, nil
	case s.mode == "count-values" && !strings.Contains(lower, "date_format") && strings.Contains(lower, "count(distinct session_id"):
		return &overviewProbeRows{columns: []string{"COUNT(*)"}, data: [][]driver.Value{{int64(3)}}}, nil
	case s.mode == "count-values" && !strings.Contains(lower, "date_format") && strings.Contains(lower, "count(distinct device_id") && strings.Contains(lower, "severity"):
		return &overviewProbeRows{columns: []string{"COUNT(*)"}, data: [][]driver.Value{{int64(2)}}}, nil
	case s.mode == "count-values" && !strings.Contains(lower, "date_format") && strings.Contains(lower, "count(distinct device_id"):
		return &overviewProbeRows{columns: []string{"COUNT(*)"}, data: [][]driver.Value{{int64(4)}}}, nil
	case s.mode == "count-values" && !strings.Contains(lower, "date_format") && strings.Contains(lower, "severity = 'critical'"):
		return &overviewProbeRows{columns: []string{"COUNT(*)"}, data: [][]driver.Value{{int64(1)}}}, nil
	case s.mode == "count-values" && !strings.Contains(lower, "date_format") && strings.Contains(lower, "severity in"):
		return &overviewProbeRows{columns: []string{"COUNT(*)"}, data: [][]driver.Value{{int64(3)}}}, nil
	case s.mode == "count-values" && !strings.Contains(lower, "date_format") && strings.Contains(lower, "record_type = 'analytics'"):
		return &overviewProbeRows{columns: []string{"COUNT(*)"}, data: [][]driver.Value{{int64(5)}}}, nil
	case s.mode == "count-values" && !strings.Contains(lower, "date_format") && strings.Contains(lower, "record_type = 'diagnostic'"):
		return &overviewProbeRows{columns: []string{"COUNT(*)"}, data: [][]driver.Value{{int64(2)}}}, nil
	case strings.Contains(lower, "count(*)") && s.mode == "count-error":
		return nil, errors.New("count query failed")
	case strings.Contains(lower, "count(*)") && s.mode == "count-rows-error":
		return &overviewProbeRows{columns: []string{"COUNT(*)"}, nextErr: errors.New("count rows failed")}, nil
	case strings.Contains(lower, "select event_name, count(*)") && s.mode == "business-query-error":
		return nil, errors.New("business operation query failed")
	case strings.Contains(lower, "select event_name, count(*)") && s.mode == "business-rows-error":
		return &overviewProbeRows{columns: []string{"event_name", "COUNT(*)"}, nextErr: errors.New("business operation rows failed")}, nil
	case strings.Contains(lower, "select event_name, count(*)") && s.mode == "business-scan-error":
		return &overviewProbeRows{columns: []string{"event_name", "COUNT(*)"}, data: [][]driver.Value{{struct{}{}, int64(1)}}}, nil
	case strings.Contains(lower, "select event_name, count(*)") && s.mode == "business-close-error":
		return &overviewProbeRows{columns: []string{"event_name", "COUNT(*)"}, closeErr: errors.New("business operation close failed")}, nil
	case strings.Contains(lower, "select event_name, count(*)") && s.mode == "business-data":
		return &overviewProbeRows{
			columns: []string{"event_name", "COUNT(*)"},
			data: [][]driver.Value{
				{"network.quic.connected", int64(3)},
				{"network.quic.failed", int64(2)},
				{"not-in-catalog", int64(99)},
			},
		}, nil
	case strings.Contains(lower, "select properties_json") && s.mode == "latency-query-error":
		return nil, errors.New("latency query failed")
	case strings.Contains(lower, "select properties_json") && s.mode == "latency-rows-error":
		return &overviewProbeRows{columns: []string{"properties_json"}, nextErr: errors.New("latency rows failed")}, nil
	case strings.Contains(lower, "select properties_json") && s.mode == "latency-scan-error":
		return &overviewProbeRows{columns: []string{"properties_json"}, data: [][]driver.Value{{struct{}{}}}}, nil
	case strings.Contains(lower, "select properties_json") && s.mode == "latency-close-error":
		return &overviewProbeRows{columns: []string{"properties_json"}, closeErr: errors.New("latency close failed")}, nil
	case strings.Contains(lower, "select properties_json") && s.mode == "latency-data":
		return &overviewProbeRows{
			columns: []string{"properties_json"},
			data:    [][]driver.Value{{`{"duration_ms":10}`}, {`{"latency_ms":20}`}, {nil}, {""}},
		}, nil
	case strings.Contains(lower, "select occurred_at, received_at") && s.mode == "delivery-query-error":
		return nil, errors.New("delivery query failed")
	case strings.Contains(lower, "select occurred_at, received_at") && s.mode == "delivery-rows-error":
		return &overviewProbeRows{columns: []string{"occurred_at", "received_at"}, nextErr: errors.New("delivery rows failed")}, nil
	case strings.Contains(lower, "select occurred_at, received_at") && s.mode == "delivery-scan-error":
		return &overviewProbeRows{columns: []string{"occurred_at", "received_at"}, data: [][]driver.Value{{struct{}{}, time.Now()}}}, nil
	case strings.Contains(lower, "select occurred_at, received_at") && s.mode == "delivery-close-error":
		return &overviewProbeRows{columns: []string{"occurred_at", "received_at"}, closeErr: errors.New("delivery close failed")}, nil
	case strings.Contains(lower, "select occurred_at, received_at") && s.mode == "delivery-data":
		return &overviewProbeRows{
			columns: []string{"occurred_at", "received_at"},
			data: [][]driver.Value{
				{time.Date(2026, time.August, 28, 4, 0, 0, 0, time.UTC), time.Date(2026, time.August, 28, 4, 0, 0, 10000000, time.UTC)},
				{time.Date(2026, time.August, 28, 4, 0, 1, 0, time.UTC), time.Date(2026, time.August, 28, 4, 0, 0, 0, time.UTC)},
				{time.Time{}, time.Time{}},
			},
		}, nil
	case strings.Contains(lower, "date_format") && s.mode == "trend-query-error":
		return nil, errors.New("trend query failed")
	case strings.Contains(lower, "date_format") && s.mode == "trend-rows-error":
		return &overviewProbeRows{columns: []string{"bucket", "COUNT(*)"}, nextErr: errors.New("trend rows failed")}, nil
	case strings.Contains(lower, "date_format") && s.mode == "trend-scan-error":
		return &overviewProbeRows{columns: []string{"bucket", "COUNT(*)"}, data: [][]driver.Value{{struct{}{}, int64(1)}}}, nil
	case strings.Contains(lower, "date_format") && s.mode == "trend-close-error":
		return &overviewProbeRows{columns: []string{"bucket", "COUNT(*)"}, closeErr: errors.New("trend close failed")}, nil
	}

	if strings.Contains(lower, "date_format") {
		s.mu.Lock()
		s.trendSQL = append(s.trendSQL, query)
		s.mu.Unlock()
		return &overviewProbeRows{
			columns: []string{"bucket", "COUNT(*)"},
			data:    [][]driver.Value{{"2026-08-28T04:00:00Z", int64(1)}},
		}, nil
	}
	if strings.Contains(lower, "select event_name, count(*)") {
		return &overviewProbeRows{columns: []string{"event_name", "COUNT(*)"}}, nil
	}
	if strings.Contains(lower, "select properties_json") {
		return &overviewProbeRows{columns: []string{"properties_json"}}, nil
	}
	if strings.Contains(lower, "select occurred_at, received_at") {
		return &overviewProbeRows{
			columns: []string{"occurred_at", "received_at"},
			data: [][]driver.Value{{
				time.Date(2026, time.August, 28, 4, 0, 0, 0, time.UTC),
				time.Date(2026, time.August, 28, 4, 0, 0, 0, time.UTC),
			}},
		}, nil
	}
	if strings.Contains(lower, "count(distinct") {
		return &overviewProbeRows{columns: []string{"COUNT(*)"}, data: [][]driver.Value{{int64(0)}}}, nil
	}
	if strings.Contains(lower, "count(*)") {
		if s.mode == "count-close-error" {
			return &overviewProbeRows{columns: []string{"COUNT(*)"}, data: [][]driver.Value{{int64(0)}}, closeErr: errors.New("count close failed")}, nil
		}
		return &overviewProbeRows{columns: []string{"COUNT(*)"}, data: [][]driver.Value{{int64(0)}}}, nil
	}
	return nil, fmt.Errorf("unexpected overview query: %s", query)
}

type overviewProbeRows struct {
	columns       []string
	data          [][]driver.Value
	index         int
	nextErr       error
	closeErr      error
	nextErrRaised bool
}

func (r *overviewProbeRows) Columns() []string { return r.columns }

func (r *overviewProbeRows) Close() error { return r.closeErr }

func (r *overviewProbeRows) Next(dest []driver.Value) error {
	if r.index < len(r.data) {
		copy(dest, r.data[r.index])
		r.index++
		return nil
	}
	if r.nextErr != nil && !r.nextErrRaised {
		r.nextErrRaised = true
		return r.nextErr
	}
	return io.EOF
}

func TestMySQLOverviewUsesSharedTrendBuckets(t *testing.T) {
	for _, test := range []struct {
		name       string
		timeRange  string
		wantFormat string
	}{
		{name: "one day", timeRange: "1d", wantFormat: "%Y-%m-%dT%H:00:00Z"},
		{name: "seven days", timeRange: "7d", wantFormat: "%Y-%m-%dT00:00:00Z"},
		{name: "thirty days", timeRange: "30d", wantFormat: "%Y-%m-%dT00:00:00Z"},
	} {
		t.Run(test.name, func(t *testing.T) {
			store, state, closeStore := newOverviewProbeStore(t, "ok")
			defer closeStore()
			metrics, err := store.QueryOverview(context.Background(), telemetry.QueryFilter{TimeRange: test.timeRange})
			if err != nil {
				t.Fatalf("overview query: %v", err)
			}
			if len(metrics.EventsTrend) != 1 || metrics.EventsTrend[0].Value != 1 {
				t.Fatalf("events trend = %+v, want one analytics bucket", metrics.EventsTrend)
			}
			state.mu.Lock()
			defer state.mu.Unlock()
			if len(state.trendSQL) < 1 || !strings.Contains(state.trendSQL[0], test.wantFormat) {
				t.Fatalf("trend SQL = %v, want date format %s", state.trendSQL, test.wantFormat)
			}
		})
	}
}

func TestMySQLOverviewPropagatesEveryAggregationFailure(t *testing.T) {
	for _, mode := range []string{
		"count-error",
		"count-rows-error",
		"count-close-error",
		"business-query-error",
		"business-rows-error",
		"business-scan-error",
		"business-close-error",
		"latency-query-error",
		"latency-rows-error",
		"latency-scan-error",
		"latency-close-error",
		"delivery-query-error",
		"delivery-rows-error",
		"delivery-scan-error",
		"delivery-close-error",
		"trend-query-error",
		"trend-rows-error",
		"trend-scan-error",
		"trend-close-error",
		"ping-error",
	} {
		t.Run(mode, func(t *testing.T) {
			store, _, closeStore := newOverviewProbeStore(t, mode)
			defer closeStore()
			if _, err := store.QueryOverview(context.Background(), telemetry.QueryFilter{}); err == nil {
				t.Fatalf("QueryOverview(%s) returned nil error", mode)
			}
		})
	}
}

func TestMySQLOverviewUnavailableStoreReturnsError(t *testing.T) {
	var store telemetry.MySQLStore
	if _, err := store.QueryOverview(context.Background(), telemetry.QueryFilter{}); err == nil {
		t.Fatal("QueryOverview on an unavailable MySQL store returned nil error")
	}
}
