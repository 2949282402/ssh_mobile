// Analytics MySQL store implementation for Telemetry.

package telemetry

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
	contractgen "github.com/ssh-mobile/relay/internal/telemetry/generated"
)

type MySQLStore struct {
	db         *sql.DB
	catalog    *Catalog
	redisCache RedisCache
}

// SetRedisCache wires a live Redis cache used for pipeline health probing. It
// is best-effort: a nil cache simply reports Redis as disabled.
func (s *MySQLStore) SetRedisCache(cache RedisCache) {
	s.redisCache = cache
}

func NewMySQLStore(db *sql.DB, catalog *Catalog) *MySQLStore {
	if catalog == nil {
		catalog = DefaultCatalog()
	}
	return &MySQLStore{
		db:      db,
		catalog: catalog,
	}
}

// NewMySQLStoreFromDSN opens a MySQL database connection, verifies ping, and ensures schemas exist.
func NewMySQLStoreFromDSN(dsn string, catalog *Catalog) (*MySQLStore, error) {
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, fmt.Errorf("open mysql error: %w", err)
	}
	db.SetMaxOpenConns(6)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping mysql error: %w", err)
	}

	store := NewMySQLStore(db, catalog)
	if err := store.EnsureSchema(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ensure schema error: %w", err)
	}
	return store, nil
}

func (s *MySQLStore) EnsureSchema(ctx context.Context) error {
	queries := []string{
		`CREATE TABLE IF NOT EXISTS telemetry_events (
			id BIGINT AUTO_INCREMENT PRIMARY KEY,
			event_id VARCHAR(64) NOT NULL,
			record_type VARCHAR(32) NOT NULL,
			event_name VARCHAR(128) NOT NULL,
			event_version INT NOT NULL,
			device_id VARCHAR(128) NOT NULL,
			session_id VARCHAR(128) NOT NULL,
			trace_id VARCHAR(128) NOT NULL,
			occurred_at DATETIME(3) NOT NULL,
			received_at DATETIME(3) NOT NULL,
			feature VARCHAR(64) NOT NULL,
			severity VARCHAR(32) NOT NULL,
			error_code VARCHAR(64) DEFAULT NULL,
			app_version VARCHAR(32) NOT NULL,
			build_number VARCHAR(32) NOT NULL,
			platform VARCHAR(32) NOT NULL,
			properties_json JSON DEFAULT NULL,
			error_json JSON DEFAULT NULL,
			created_at DATETIME(3) NOT NULL,
			INDEX idx_telemetry_device (device_id),
			INDEX idx_telemetry_trace (trace_id),
			INDEX idx_telemetry_name_received (event_name, received_at),
			INDEX idx_telemetry_severity_received (severity, received_at),
			INDEX idx_telemetry_error_received (error_code, received_at),
			INDEX idx_telemetry_received (received_at)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;`,

		`CREATE TABLE IF NOT EXISTS telemetry_ingest_receipts (
			event_id VARCHAR(64) PRIMARY KEY,
			device_id VARCHAR(128) NOT NULL,
			received_at DATETIME(3) NOT NULL,
			INDEX idx_receipt_received (received_at)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;`,

		`CREATE TABLE IF NOT EXISTS telemetry_settings (
			id INT PRIMARY KEY,
			settings_json JSON NOT NULL,
			updated_at DATETIME(3) NOT NULL
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;`,

		`CREATE TABLE IF NOT EXISTS telemetry_device_credentials (
			device_id VARCHAR(128) PRIMARY KEY,
			secret_hash VARCHAR(128) NOT NULL,
			created_at DATETIME(3) NOT NULL,
			updated_at DATETIME(3) NOT NULL
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;`,
	}

	for _, q := range queries {
		if _, err := s.db.ExecContext(ctx, q); err != nil {
			return fmt.Errorf("failed executing telemetry schema DDL: %w", err)
		}
	}
	return nil
}

func isDuplicateKeyError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "1062") || strings.Contains(msg, "duplicate entry") || strings.Contains(msg, "unique constraint")
}

func (s *MySQLStore) IngestBatch(ctx context.Context, envelopes []TelemetryEnvelope) ([]IngestRecordResult, error) {
	now := time.Now().UTC()
	results := make([]IngestRecordResult, len(envelopes))

	for i, env := range envelopes {
		if err := s.catalog.ValidateEnvelope(&env); err != nil {
			results[i] = IngestRecordResult{
				EventID: env.EventID,
				Status:  StatusRejected,
				Reason:  err.Error(),
			}
			continue
		}

		// Server receive time is authoritative; client-supplied receivedAt is ignored.
		env.ReceivedAt = now

		// Check receipt idempotency
		var existingID string
		err := s.db.QueryRowContext(ctx, "SELECT event_id FROM telemetry_ingest_receipts WHERE event_id = ?", env.EventID).Scan(&existingID)
		if err == nil && existingID != "" {
			results[i] = IngestRecordResult{
				EventID: env.EventID,
				Status:  StatusAlreadySeen,
			}
			continue
		} else if err != nil && err != sql.ErrNoRows {
			return nil, fmt.Errorf("query receipt error: %w", err)
		}

		var propsJSON []byte
		if env.Properties != nil {
			propsJSON, _ = json.Marshal(env.Properties)
		}

		var errJSON []byte
		var errCode sql.NullString
		if env.Error != nil {
			errJSON, _ = json.Marshal(env.Error)
			errCode = sql.NullString{String: env.Error.ErrorCode, Valid: true}
		}

		// Atomic insert into telemetry_events and telemetry_ingest_receipts
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return nil, fmt.Errorf("begin ingest tx: %w", err)
		}

		_, err = tx.ExecContext(ctx, `
			INSERT INTO telemetry_events (
				event_id, record_type, event_name, event_version, device_id, session_id,
				trace_id, occurred_at, received_at, feature, severity, error_code,
				app_version, build_number, platform, properties_json, error_json, created_at
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		`,
			env.EventID, string(env.RecordType), env.EventName, env.EventVersion, env.DeviceID, env.SessionID,
			env.TraceID, env.OccurredAt, env.ReceivedAt, env.Feature, string(env.Severity), errCode,
			env.AppVersion, env.BuildNumber, env.Platform, string(propsJSON), string(errJSON), now,
		)
		if err != nil {
			_ = tx.Rollback()
			if isDuplicateKeyError(err) {
				results[i] = IngestRecordResult{
					EventID: env.EventID,
					Status:  StatusAlreadySeen,
				}
				continue
			}
			return nil, fmt.Errorf("insert raw event: %w", err)
		}

		_, err = tx.ExecContext(ctx, `
			INSERT INTO telemetry_ingest_receipts (event_id, device_id, received_at)
			VALUES (?, ?, ?)
		`, env.EventID, env.DeviceID, env.ReceivedAt)
		if err != nil {
			_ = tx.Rollback()
			if isDuplicateKeyError(err) {
				results[i] = IngestRecordResult{
					EventID: env.EventID,
					Status:  StatusAlreadySeen,
				}
				continue
			}
			return nil, fmt.Errorf("insert receipt: %w", err)
		}

		if err := tx.Commit(); err != nil {
			if isDuplicateKeyError(err) {
				results[i] = IngestRecordResult{
					EventID: env.EventID,
					Status:  StatusAlreadySeen,
				}
				continue
			}
			return nil, fmt.Errorf("commit ingest tx: %w", err)
		}

		results[i] = IngestRecordResult{
			EventID: env.EventID,
			Status:  StatusAccepted,
		}
	}

	return results, nil
}

func (s *MySQLStore) QueryEvents(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, error) {
	var whereClauses []string
	var args []any

	if filter.RecordType != "" {
		whereClauses = append(whereClauses, "record_type = ?")
		args = append(args, string(filter.RecordType))
	}
	if filter.DeviceID != "" {
		whereClauses = append(whereClauses, "device_id = ?")
		args = append(args, filter.DeviceID)
	}
	if filter.TraceID != "" {
		whereClauses = append(whereClauses, "trace_id = ?")
		args = append(args, filter.TraceID)
	}
	if filter.EventName != "" {
		whereClauses = append(whereClauses, "event_name = ?")
		args = append(args, filter.EventName)
	}
	if filter.Feature != "" {
		whereClauses = append(whereClauses, "feature = ?")
		args = append(args, filter.Feature)
	}
	if filter.Severity != "" {
		whereClauses = append(whereClauses, "severity = ?")
		args = append(args, string(filter.Severity))
	}
	if filter.ErrorCode != "" {
		whereClauses = append(whereClauses, "error_code = ?")
		args = append(args, filter.ErrorCode)
	}
	if filter.AppVersion != "" {
		whereClauses = append(whereClauses, "app_version = ?")
		args = append(args, filter.AppVersion)
	}
	if filter.Platform != "" {
		whereClauses = append(whereClauses, "platform = ?")
		args = append(args, filter.Platform)
	}
	if !filter.StartTime.IsZero() {
		whereClauses = append(whereClauses, "received_at >= ?")
		args = append(args, filter.StartTime)
	}
	if !filter.EndTime.IsZero() {
		whereClauses = append(whereClauses, "received_at <= ?")
		args = append(args, filter.EndTime)
	}

	whereSQL := ""
	if len(whereClauses) > 0 {
		whereSQL = " WHERE " + strings.Join(whereClauses, " AND ")
	}

	// Count total
	var total int
	countQuery := "SELECT COUNT(*) FROM telemetry_events" + whereSQL
	if err := s.db.QueryRowContext(ctx, countQuery, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("count events query: %w", err)
	}

	page := filter.Page
	if page < 1 {
		page = 1
	}
	pageSize := filter.PageSize
	if pageSize < 1 {
		pageSize = 50
	}
	offset := (page - 1) * pageSize

	query := `
		SELECT event_id, record_type, event_name, event_version, device_id, session_id,
		       trace_id, occurred_at, received_at, feature, severity, app_version,
		       build_number, platform, properties_json, error_json
		FROM telemetry_events
	` + whereSQL + " ORDER BY received_at DESC LIMIT ? OFFSET ?"

	selectArgs := append(args, pageSize, offset)
	rows, err := s.db.QueryContext(ctx, query, selectArgs...)
	if err != nil {
		return nil, 0, fmt.Errorf("select events: %w", err)
	}
	defer rows.Close()

	var records []TelemetryEnvelope
	for rows.Next() {
		var env TelemetryEnvelope
		var recType, sev string
		var propsRaw, errRaw sql.NullString

		err := rows.Scan(
			&env.EventID, &recType, &env.EventName, &env.EventVersion, &env.DeviceID, &env.SessionID,
			&env.TraceID, &env.OccurredAt, &env.ReceivedAt, &env.Feature, &sev, &env.AppVersion,
			&env.BuildNumber, &env.Platform, &propsRaw, &errRaw,
		)
		if err != nil {
			return nil, 0, fmt.Errorf("scan event row: %w", err)
		}

		env.RecordType = RecordType(recType)
		env.Severity = Severity(sev)

		if propsRaw.Valid && len(propsRaw.String) > 0 {
			var p map[string]any
			if err := json.Unmarshal([]byte(propsRaw.String), &p); err == nil {
				env.Properties = p
			}
		}

		if errRaw.Valid && len(errRaw.String) > 0 {
			var e TelemetryError
			if err := json.Unmarshal([]byte(errRaw.String), &e); err == nil {
				env.Error = &e
			}
		}

		records = append(records, env)
	}

	return records, total, nil
}

func (s *MySQLStore) QueryDiagnostics(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, error) {
	filter.RecordType = RecordTypeDiagnostic
	return s.QueryEvents(ctx, filter)
}

// overviewSuccessSQL matches events that represent a terminal successful
// operation. In-progress events (e.g. *.started, *.request) MUST NOT match so
// they never inflate the success denominator.
const overviewSuccessSQL = `(
	event_name LIKE '%.connected'
	OR event_name LIKE '%.completed'
	OR event_name LIKE '%.succeeded'
	OR event_name LIKE '%.established'
	OR (severity NOT IN ('error', 'critical')
	    AND error_code IS NULL
	    AND event_name NOT LIKE '%.started'
	    AND event_name NOT LIKE '%.request')
)`

// overviewFailureSQL matches events that represent a terminal failure:
// *.failed, *.disconnected carrying an error, app.crash.reported, or any event
// with severity error/critical or a non-null error payload.
const overviewFailureSQL = `(
	event_name LIKE '%.failed'
	OR (event_name LIKE '%.disconnected' AND (severity IN ('error', 'critical') OR error_code IS NOT NULL))
	OR severity IN ('error', 'critical')
	OR error_code IS NOT NULL
)`

// latencyEventsSQL selects the telemetry events whose properties may carry a
// completion duration (duration_ms or latency_ms) for a terminal success.
func latencyEventsSQL() (string, []any) {
	names := make([]any, 0, len(contractgen.TelemetryEvents))
	for _, event := range contractgen.TelemetryEvents {
		if event.OperationRole != "success" {
			continue
		}
		for _, property := range event.AllowedProperties {
			if property.Name == "duration_ms" || property.Name == "latency_ms" {
				names = append(names, event.Name)
				break
			}
		}
	}

	placeholders := make([]string, len(names))
	for i := range placeholders {
		placeholders[i] = "?"
	}
	return fmt.Sprintf(
		"event_name IN (%s) AND severity NOT IN ('error', 'critical') AND error_code IS NULL",
		strings.Join(placeholders, ", "),
	), names
}

// isTerminalFailureEvent reports whether an envelope represents a terminal
// failure per the overview success-rate contract.
func isTerminalFailureEvent(env *TelemetryEnvelope) bool {
	if strings.HasSuffix(env.EventName, ".failed") {
		return true
	}
	if strings.HasSuffix(env.EventName, ".disconnected") &&
		(env.Error != nil || env.Severity == SeverityError || env.Severity == SeverityCritical) {
		return true
	}
	if env.Severity == SeverityError || env.Severity == SeverityCritical {
		return true
	}
	return env.Error != nil
}

// isTerminalSuccessEvent reports whether an envelope represents a terminal
// success. In-progress events (*.started / *.request) are explicitly excluded so
// they count toward neither the success nor the failure denominator.
func isTerminalSuccessEvent(env *TelemetryEnvelope) bool {
	if isTerminalFailureEvent(env) {
		return false
	}
	if strings.HasSuffix(env.EventName, ".connected") ||
		strings.HasSuffix(env.EventName, ".completed") ||
		strings.HasSuffix(env.EventName, ".succeeded") ||
		strings.HasSuffix(env.EventName, ".established") {
		return true
	}
	if (env.Severity != SeverityError && env.Severity != SeverityCritical) &&
		env.Error == nil &&
		!strings.HasSuffix(env.EventName, ".started") &&
		!strings.HasSuffix(env.EventName, ".request") {
		return true
	}
	return false
}

// overviewTimeWhere builds the shared received_at time filter for overview
// aggregation queries.
func overviewTimeWhere(filter QueryFilter) (string, []any) {
	var whereClauses []string
	var args []any

	if !filter.StartTime.IsZero() {
		whereClauses = append(whereClauses, "received_at >= ?")
		args = append(args, filter.StartTime)
	}
	if !filter.EndTime.IsZero() {
		whereClauses = append(whereClauses, "received_at <= ?")
		args = append(args, filter.EndTime)
	}
	if len(whereClauses) == 0 {
		return "", nil
	}
	return " WHERE " + strings.Join(whereClauses, " AND "), args
}

// combineOverviewWhere attaches a condition to the base time filter producing a
// reusable WHERE clause. condition == "" keeps only the time filter.
type combineWhereFunc func(condition string) (string, []any)

func combineOverviewWhere(whereSQL string, args []any) combineWhereFunc {
	return func(condition string) (string, []any) {
		if condition == "" {
			return whereSQL, args
		}
		if whereSQL == "" {
			return " WHERE " + condition, nil
		}
		combinedArgs := make([]any, len(args))
		copy(combinedArgs, args)
		return whereSQL + " AND (" + condition + ")", combinedArgs
	}
}

func toFloat(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case float32:
		return float64(n), true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	case int32:
		return float64(n), true
	case uint64:
		return float64(n), true
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	default:
		return 0, false
	}
}

// extractLatencyFromProps pulls a completion duration from telemetry properties
// payloads. duration_ms is preferred, latency_ms is accepted as an alias.
func extractLatencyFromProps(props map[string]any) (float64, bool) {
	for _, key := range []string{"duration_ms", "latency_ms"} {
		v, ok := props[key]
		if !ok {
			continue
		}
		if f, ok := toFloat(v); ok && f > 0 {
			return f, true
		}
	}
	return 0, false
}

// percentile returns the nearest-rank percentile for sorted ascending values.
// A no-data slice returns 0 and out-of-range p is clamped.
func percentile(sorted []float64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	if p <= 0 {
		return sorted[0]
	}
	if p >= 1 {
		return sorted[len(sorted)-1]
	}
	idx := int(math.Ceil(p*float64(len(sorted)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

// latencyStats computes p50/p95/p99 percentiles from raw latency samples.
func latencyStats(values []float64) LatencyStats {
	if len(values) == 0 {
		return LatencyStats{}
	}
	sort.Float64s(values)
	return LatencyStats{
		P50Ms:   percentile(values, 0.50),
		P95Ms:   percentile(values, 0.95),
		P99Ms:   percentile(values, 0.99),
		Samples: int64(len(values)),
	}
}

// queryLatencyPercentiles aggregates real p50/p95/p99 latency from the
// duration_ms / latency_ms properties of completed/succeeded operations in the
// requested time range. With no latency data it returns a zeroed LatencyStats.
func (s *MySQLStore) queryLatencyPercentiles(ctx context.Context, combineWhere combineWhereFunc) LatencyStats {
	latencyCondition, latencyArgs := latencyEventsSQL()
	w, qArgs := combineWhere(latencyCondition)
	qArgs = append(qArgs, latencyArgs...)
	rows, err := s.db.QueryContext(ctx, "SELECT properties_json FROM telemetry_events"+w, qArgs...)
	if err != nil {
		return LatencyStats{}
	}
	defer rows.Close()

	values := make([]float64, 0, 64)
	for rows.Next() {
		var propsRaw sql.NullString
		if err := rows.Scan(&propsRaw); err != nil {
			continue
		}
		if !propsRaw.Valid || propsRaw.String == "" {
			continue
		}
		var props map[string]any
		if err := json.Unmarshal([]byte(propsRaw.String), &props); err != nil {
			continue
		}
		if d, ok := extractLatencyFromProps(props); ok {
			values = append(values, d)
		}
	}
	_ = rows.Err()
	return latencyStats(values)
}

// queryIngestLatencyMs returns a real pipeline ingest-latency proxy: the median
// client-observed-to-server-received delta (received_at - occurred_at) of events
// in range, in milliseconds. Zero when there is no sampled data.
func (s *MySQLStore) queryIngestLatencyMs(ctx context.Context, combineWhere combineWhereFunc) float64 {
	w, qArgs := combineWhere("")
	rows, err := s.db.QueryContext(ctx,
		"SELECT TIMESTAMPDIFF(MICROSECOND, occurred_at, received_at) / 1000.0 FROM telemetry_events"+w, qArgs...)
	if err != nil {
		return 0
	}
	defer rows.Close()

	var diffs []float64
	for rows.Next() {
		var d float64
		if err := rows.Scan(&d); err != nil {
			continue
		}
		if d >= 0 {
			diffs = append(diffs, d)
		}
	}
	_ = rows.Err()
	if len(diffs) == 0 {
		return 0
	}
	sort.Float64s(diffs)
	return percentile(diffs, 0.50)
}

// queryOverviewTrends aggregates event volume and error volume in time buckets.
// Hourly buckets are used for short windows (1h/24h) and daily buckets for
// longer windows (7d/30d).
func (s *MySQLStore) queryOverviewTrends(ctx context.Context, combineWhere combineWhereFunc, timeRange string) ([]TelemetryMetricPoint, []TelemetryMetricPoint, error) {
	dateFormat := "%Y-%m-%dT%H:00:00Z"
	if timeRange == "7d" || timeRange == "30d" {
		dateFormat = "%Y-%m-%dT00:00:00Z"
	}

	trendWhere, trendArgs := combineWhere("")
	trendQuery := "SELECT DATE_FORMAT(received_at, '" + dateFormat + "') AS bucket, COUNT(*) " +
		"FROM telemetry_events" + trendWhere + " GROUP BY bucket ORDER BY bucket ASC"
	rows, err := s.db.QueryContext(ctx, trendQuery, trendArgs...)
	if err != nil {
		return nil, nil, fmt.Errorf("overview events trend: %w", err)
	}
	defer rows.Close()

	eventsTrend := []TelemetryMetricPoint{}
	for rows.Next() {
		var bucket string
		var val float64
		if err := rows.Scan(&bucket, &val); err != nil {
			return nil, nil, fmt.Errorf("scan events trend: %w", err)
		}
		eventsTrend = append(eventsTrend, TelemetryMetricPoint{Timestamp: bucket, Value: val})
	}
	if err := rows.Err(); err != nil {
		return nil, nil, fmt.Errorf("iterate events trend: %w", err)
	}

	errWhere, errArgs := combineWhere("severity IN ('error', 'critical')")
	errQuery := "SELECT DATE_FORMAT(received_at, '" + dateFormat + "') AS bucket, COUNT(*) " +
		"FROM telemetry_events" + errWhere + " GROUP BY bucket ORDER BY bucket ASC"
	errRows, err := s.db.QueryContext(ctx, errQuery, errArgs...)
	if err != nil {
		return nil, nil, fmt.Errorf("overview errors trend: %w", err)
	}
	defer errRows.Close()

	errorsTrend := []TelemetryMetricPoint{}
	for errRows.Next() {
		var bucket string
		var val float64
		if err := errRows.Scan(&bucket, &val); err != nil {
			return nil, nil, fmt.Errorf("scan errors trend: %w", err)
		}
		errorsTrend = append(errorsTrend, TelemetryMetricPoint{Timestamp: bucket, Value: val})
	}
	if err := errRows.Err(); err != nil {
		return nil, nil, fmt.Errorf("iterate errors trend: %w", err)
	}

	return eventsTrend, errorsTrend, nil
}

// pingMySQL performs a live database reachability probe with a short timeout.
func (s *MySQLStore) pingMySQL(ctx context.Context) error {
	pingCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	return s.db.PingContext(pingCtx)
}

// redisHealthStatus probes the wired Redis cache (when present) and reports an
// active/disabled/fallback_mysql status.
func redisHealthStatus(ctx context.Context, cache RedisCache) string {
	rc, ok := cache.(*RedisClientCache)
	if !ok || rc == nil || rc.client == nil {
		return "disabled"
	}
	pingCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if err := rc.client.Ping(pingCtx).Err(); err != nil {
		return "fallback_mysql"
	}
	return "active"
}

func (s *MySQLStore) QueryOverview(ctx context.Context, filter QueryFilter) (*OverviewMetrics, error) {
	whereSQL, args := overviewTimeWhere(filter)
	combineWhere := combineOverviewWhere(whereSQL, args)

	var totalEvents int64
	var totalDiagnostics int64
	var errorCount int64
	var criticalCount int64
	var recentActiveDevices int64
	var affectedDevicesCount int64
	var totalSessions int64
	var errorSessions int64

	w, qArgs := combineWhere("record_type = 'analytics'")
	_ = s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM telemetry_events"+w, qArgs...).Scan(&totalEvents)

	w, qArgs = combineWhere("record_type = 'diagnostic'")
	_ = s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM telemetry_events"+w, qArgs...).Scan(&totalDiagnostics)

	w, qArgs = combineWhere("severity IN ('error', 'critical')")
	_ = s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM telemetry_events"+w, qArgs...).Scan(&errorCount)

	w, qArgs = combineWhere("severity = 'critical'")
	_ = s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM telemetry_events"+w, qArgs...).Scan(&criticalCount)

	w, qArgs = combineWhere("")
	_ = s.db.QueryRowContext(ctx, "SELECT COUNT(DISTINCT device_id) FROM telemetry_events"+w, qArgs...).Scan(&recentActiveDevices)

	w, qArgs = combineWhere("severity IN ('error', 'critical')")
	_ = s.db.QueryRowContext(ctx, "SELECT COUNT(DISTINCT device_id) FROM telemetry_events"+w, qArgs...).Scan(&affectedDevicesCount)

	w, qArgs = combineWhere("")
	_ = s.db.QueryRowContext(ctx, "SELECT COUNT(DISTINCT session_id) FROM telemetry_events"+w, qArgs...).Scan(&totalSessions)

	w, qArgs = combineWhere("severity IN ('error', 'critical')")
	_ = s.db.QueryRowContext(ctx, "SELECT COUNT(DISTINCT session_id) FROM telemetry_events"+w, qArgs...).Scan(&errorSessions)

	// Explicit terminal denominators: successRate = succeeded / (succeeded + failed).
	// In-progress events (started/request) are counted by neither side. When both
	// terminal counts are zero the rate is reported as 1.0 (no failures observed).
	var succeededCount int64
	var failedCount int64
	w, qArgs = combineWhere("")
	countSQL := "SELECT " +
		"COALESCE(SUM(CASE WHEN " + overviewFailureSQL + " THEN 1 ELSE 0 END), 0) AS failed_count, " +
		"COALESCE(SUM(CASE WHEN NOT (" + overviewFailureSQL + ") AND " + overviewSuccessSQL + " THEN 1 ELSE 0 END), 0) AS succeeded_count " +
		"FROM telemetry_events" + w
	if err := s.db.QueryRowContext(ctx, countSQL, qArgs...).Scan(&failedCount, &succeededCount); err != nil {
		return nil, fmt.Errorf("overview terminal counts: %w", err)
	}

	var successRate float64 = 1.0
	terminalTotal := succeededCount + failedCount
	if terminalTotal > 0 {
		successRate = float64(succeededCount) / float64(terminalTotal)
	}

	var errorFreeSessionRate float64 = 1.0
	if totalSessions > 0 {
		errorFree := totalSessions - errorSessions
		if errorFree < 0 {
			errorFree = 0
		}
		errorFreeSessionRate = float64(errorFree) / float64(totalSessions)
	}

	// Real latency percentiles from completed/succeeded operations.
	latency := s.queryLatencyPercentiles(ctx, combineWhere)

	// Real ingest-latency proxy: median received_at - occurred_at delta in range.
	ingestLatency := s.queryIngestLatencyMs(ctx, combineWhere)

	// Ingest/trend volume aggregation.
	eventsTrend, errorsTrend, err := s.queryOverviewTrends(ctx, combineWhere, filter.TimeRange)
	if err != nil {
		return nil, err
	}

	// Live service health: MySQL ping, Redis ping, and aggregate error rate.
	status := "healthy"
	redisStatus := redisHealthStatus(ctx, s.redisCache)
	if err := s.pingMySQL(ctx); err != nil {
		status = "unhealthy"
	} else if redisStatus != "active" {
		status = "degraded"
	}

	var ingestErrorRate float64
	if terminalTotal > 0 {
		ingestErrorRate = float64(failedCount) / float64(terminalTotal)
	}

	return &OverviewMetrics{
		TotalEvents:              totalEvents,
		TotalDiagnostics:         totalDiagnostics,
		RecentActiveDevices:      recentActiveDevices,
		ErrorCount:               errorCount,
		CriticalErrorCount:       criticalCount,
		AffectedDevicesCount:     affectedDevicesCount,
		CoreOperationSuccessRate: successRate,
		ErrorFreeSessionRate:     errorFreeSessionRate,
		EventsTrend:              eventsTrend,
		ErrorsTrend:              errorsTrend,
		Latency:                  latency,
		PipelineHealth: PipelineHealthStats{
			Status:                status,
			ServerIngestLatencyMs: ingestLatency,
			ServerIngestErrorRate: ingestErrorRate,
			RedisCacheStatus:      redisStatus,
		},
	}, nil
}

func (s *MySQLStore) GetSettings(ctx context.Context) (*TelemetrySettings, error) {
	var rawJSON string
	var updatedAt time.Time
	err := s.db.QueryRowContext(ctx, "SELECT settings_json, updated_at FROM telemetry_settings WHERE id = 1").Scan(&rawJSON, &updatedAt)
	if err == sql.ErrNoRows {
		def := DefaultSettings()
		return &def, nil
	} else if err != nil {
		return nil, fmt.Errorf("get telemetry settings: %w", err)
	}

	var settings TelemetrySettings
	if err := json.Unmarshal([]byte(rawJSON), &settings); err != nil {
		return nil, fmt.Errorf("unmarshal settings: %w", err)
	}
	settings.UpdatedAt = updatedAt
	return &settings, nil
}

func (s *MySQLStore) SaveSettings(ctx context.Context, settings TelemetrySettings) error {
	SanitizeSettings(&settings)
	now := time.Now().UTC()
	settings.UpdatedAt = now
	data, err := json.Marshal(settings)
	if err != nil {
		return fmt.Errorf("marshal settings: %w", err)
	}

	_, err = s.db.ExecContext(ctx, `
		INSERT INTO telemetry_settings (id, settings_json, updated_at)
		VALUES (1, ?, ?)
		ON DUPLICATE KEY UPDATE settings_json = VALUES(settings_json), updated_at = VALUES(updated_at)
	`, string(data), now)
	return err
}

func (s *MySQLStore) PurgeRetention(ctx context.Context, cutoff time.Time, maxRows int, batchSize int) (int, error) {
	if batchSize <= 0 {
		batchSize = 500
	}
	totalDeleted := 0

	// 1. Time based purge
	if !cutoff.IsZero() {
		for {
			res, err := s.db.ExecContext(ctx, `
				DELETE FROM telemetry_events
				WHERE received_at < ?
				ORDER BY received_at ASC
				LIMIT ?
			`, cutoff, batchSize)
			if err != nil {
				return totalDeleted, fmt.Errorf("purge by time error: %w", err)
			}
			rowsAffected, _ := res.RowsAffected()
			totalDeleted += int(rowsAffected)
			if rowsAffected < int64(batchSize) {
				break
			}
		}
	}

	// 2. Max rows purge
	if maxRows > 0 {
		var currentCount int
		if err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM telemetry_events").Scan(&currentCount); err != nil {
			return totalDeleted, fmt.Errorf("count for maxRows purge: %w", err)
		}

		for currentCount > maxRows {
			excess := currentCount - maxRows
			toDelete := batchSize
			if excess < toDelete {
				toDelete = excess
			}

			res, err := s.db.ExecContext(ctx, `
				DELETE FROM telemetry_events
				ORDER BY received_at ASC
				LIMIT ?
			`, toDelete)
			if err != nil {
				return totalDeleted, fmt.Errorf("purge by maxRows error: %w", err)
			}
			rowsAffected, _ := res.RowsAffected()
			totalDeleted += int(rowsAffected)
			currentCount -= int(rowsAffected)
			if rowsAffected == 0 {
				break
			}
		}
	}

	return totalDeleted, nil
}

func (s *MySQLStore) RegisterDeviceCredential(ctx context.Context, deviceID, secretHash string) error {
	now := time.Now().UTC()
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO telemetry_device_credentials (device_id, secret_hash, created_at, updated_at)
		VALUES (?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE secret_hash = VALUES(secret_hash), updated_at = VALUES(updated_at)
	`, deviceID, secretHash, now, now)
	return err
}

// CreateDeviceCredential atomically creates a telemetry credential and refuses
// to overwrite an existing one. The public enrollment endpoint uses this
// create-only operation so a replay cannot rotate a secret implicitly.
func (s *MySQLStore) CreateDeviceCredential(ctx context.Context, deviceID, secretHash string) error {
	if strings.TrimSpace(deviceID) == "" || strings.TrimSpace(secretHash) == "" {
		return fmt.Errorf("invalid deviceId or secretHash")
	}
	now := time.Now().UTC()
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO telemetry_device_credentials (device_id, secret_hash, created_at, updated_at)
		VALUES (?, ?, ?, ?)
	`, deviceID, secretHash, now, now)
	if isDuplicateKeyError(err) {
		return ErrDeviceCredentialAlreadyExists
	}
	return err
}

func (s *MySQLStore) GetDeviceCredential(ctx context.Context, deviceID string) (string, error) {
	var secretHash string
	err := s.db.QueryRowContext(ctx, "SELECT secret_hash FROM telemetry_device_credentials WHERE device_id = ?", deviceID).Scan(&secretHash)
	if err == sql.ErrNoRows {
		return "", fmt.Errorf("%w: %s", ErrDeviceCredentialNotFound, deviceID)
	}
	return secretHash, err
}

func (s *MySQLStore) Close() error {
	return s.db.Close()
}
