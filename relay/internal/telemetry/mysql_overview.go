package telemetry

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

// latencyEventsSQL selects business-success telemetry events whose properties
// may carry a completion duration (duration_ms or latency_ms).
func latencyEventsSQL(catalog *Catalog) (string, []any) {
	names := make([]any, 0)
	for _, event := range catalogEventDefinitions(catalog) {
		if !event.BusinessOperation || event.OperationRole != "success" {
			continue
		}
		for _, property := range event.AllowedProperties {
			if property.Name == "duration_ms" || property.Name == "latency_ms" {
				names = append(names, event.Name)
				break
			}
		}
	}
	if len(names) == 0 {
		return "0 = 1", nil
	}

	placeholders := make([]string, len(names))
	for i := range placeholders {
		placeholders[i] = "?"
	}
	return fmt.Sprintf(
		"event_name IN (%s)",
		strings.Join(placeholders, ", "),
	), names
}

// overviewTimeWhere builds the shared received_at time filter for overview
// aggregation queries.
func overviewTimeWhere(filter QueryFilter) (string, []any) {
	filter = normalizeOverviewFilter(filter, time.Now().UTC())
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

func (s *MySQLStore) queryBusinessOperationMetrics(ctx context.Context, combineWhere combineWhereFunc) ([]BusinessOperationGroupMetrics, int64, int64, error) {
	definitions := catalogEventDefinitions(s.catalog)
	eligible := make(map[string]EventDefinition)
	names := make([]any, 0, len(definitions))
	for _, definition := range definitions {
		if !definition.BusinessOperation || (definition.OperationRole != "success" && definition.OperationRole != "failure") {
			continue
		}
		eligible[definition.Name] = definition
		names = append(names, definition.Name)
	}
	if len(names) == 0 {
		return []BusinessOperationGroupMetrics{}, 0, 0, nil
	}
	placeholders := make([]string, len(names))
	for i := range placeholders {
		placeholders[i] = "?"
	}
	condition := "event_name IN (" + strings.Join(placeholders, ", ") + ")"
	w, qArgs := combineWhere(condition)
	qArgs = append(append([]any(nil), qArgs...), names...)
	rows, err := s.db.QueryContext(ctx,
		"SELECT event_name, COUNT(*) FROM telemetry_events"+w+" GROUP BY event_name",
		qArgs...,
	)
	if err != nil {
		return nil, 0, 0, fmt.Errorf("overview business operation counts: %w", err)
	}
	counts := make(map[string]int64, len(eligible))
	for rows.Next() {
		var eventName string
		var count int64
		if err := rows.Scan(&eventName, &count); err != nil {
			_ = rows.Close()
			return nil, 0, 0, fmt.Errorf("scan business operation count: %w", err)
		}
		if _, ok := eligible[eventName]; ok {
			counts[eventName] = count
		}
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return nil, 0, 0, fmt.Errorf("iterate business operation counts: %w", err)
	}
	if err := rows.Close(); err != nil {
		return nil, 0, 0, fmt.Errorf("close business operation counts: %w", err)
	}

	groups := newBusinessOperationMetrics()
	var successes, failures int64
	for eventName, count := range counts {
		definition := eligible[eventName]
		successCount, failureCount := int64(0), int64(0)
		if definition.OperationRole == "success" {
			successCount = count
			successes += count
		} else {
			failureCount = count
			failures += count
		}
		if definition.OperationGroup == "" {
			continue
		}
		accumulator, ok := groups[definition.OperationGroup]
		if !ok {
			if len(groups) >= maxBusinessOperationGroups {
				continue
			}
			accumulator = &businessOperationAccumulator{group: definition.OperationGroup}
			groups[definition.OperationGroup] = accumulator
		}
		accumulator.successes += successCount
		accumulator.failures += failureCount
	}
	return buildBusinessOperationMetrics(groups), successes, failures, nil
}

func (s *MySQLStore) queryDeliveryDelayStats(ctx context.Context, combineWhere combineWhereFunc) (DeliveryDelayStats, error) {
	w, qArgs := combineWhere("")
	rows, err := s.db.QueryContext(ctx,
		"SELECT occurred_at, received_at FROM telemetry_events"+w,
		qArgs...,
	)
	if err != nil {
		return DeliveryDelayStats{}, fmt.Errorf("overview delivery delay: %w", err)
	}

	values := make([]float64, 0, 64)
	var sum float64
	var futureCount int64
	for rows.Next() {
		var occurredAt, receivedAt time.Time
		if err := rows.Scan(&occurredAt, &receivedAt); err != nil {
			_ = rows.Close()
			return DeliveryDelayStats{}, fmt.Errorf("scan delivery delay: %w", err)
		}
		if occurredAt.IsZero() || receivedAt.IsZero() {
			continue
		}
		delay := receivedAt.Sub(occurredAt)
		if delay < 0 {
			futureCount++
			delay = 0
		}
		ms := float64(delay) / float64(time.Millisecond)
		values = append(values, ms)
		sum += ms
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return DeliveryDelayStats{}, fmt.Errorf("iterate delivery delay: %w", err)
	}
	if err := rows.Close(); err != nil {
		return DeliveryDelayStats{}, fmt.Errorf("close delivery delay: %w", err)
	}
	if len(values) == 0 {
		return DeliveryDelayStats{FutureTimestampCount: futureCount}, nil
	}
	sort.Float64s(values)
	return DeliveryDelayStats{
		AverageMs:            sum / float64(len(values)),
		P50Ms:                percentile(values, 0.50),
		P95Ms:                percentile(values, 0.95),
		P99Ms:                percentile(values, 0.99),
		Samples:              int64(len(values)),
		FutureTimestampCount: futureCount,
	}, nil
}

// queryLatencyPercentiles aggregates real p50/p95/p99 latency from the
// duration_ms / latency_ms properties of catalog-declared successful business
// operations in the requested time range. With no latency data it returns a
// zeroed LatencyStats.
func (s *MySQLStore) queryLatencyPercentiles(ctx context.Context, combineWhere combineWhereFunc) (LatencyStats, error) {
	latencyCondition, latencyArgs := latencyEventsSQL(s.catalog)
	w, qArgs := combineWhere(latencyCondition)
	qArgs = append(qArgs, latencyArgs...)
	rows, err := s.db.QueryContext(ctx, "SELECT properties_json FROM telemetry_events"+w, qArgs...)
	if err != nil {
		return LatencyStats{}, fmt.Errorf("overview latency query: %w", err)
	}

	values := make([]float64, 0, 64)
	for rows.Next() {
		var propsRaw sql.NullString
		if err := rows.Scan(&propsRaw); err != nil {
			_ = rows.Close()
			return LatencyStats{}, fmt.Errorf("scan latency properties: %w", err)
		}
		if !propsRaw.Valid || propsRaw.String == "" {
			continue
		}
		var props map[string]any
		if err := json.Unmarshal([]byte(propsRaw.String), &props); err != nil {
			_ = rows.Close()
			return LatencyStats{}, fmt.Errorf("decode latency properties: %w", err)
		}
		if d, ok := extractLatencyFromProps(props); ok {
			values = append(values, d)
		}
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return LatencyStats{}, fmt.Errorf("iterate latency properties: %w", err)
	}
	if err := rows.Close(); err != nil {
		return LatencyStats{}, fmt.Errorf("close latency properties: %w", err)
	}
	return latencyStats(values), nil
}

// queryOverviewTrends aggregates analytics event volume and all-record error
// volume using the shared UTC range-to-bucket policy.
func (s *MySQLStore) queryOverviewTrends(ctx context.Context, combineWhere combineWhereFunc, timeRange string) ([]TelemetryMetricPoint, []TelemetryMetricPoint, error) {
	dateFormat := overviewTrendDateFormat(timeRange)

	trendWhere, trendArgs := combineWhere("record_type = 'analytics'")
	trendQuery := "SELECT DATE_FORMAT(received_at, '" + dateFormat + "') AS bucket, COUNT(*) " +
		"FROM telemetry_events" + trendWhere + " GROUP BY bucket ORDER BY bucket ASC"
	rows, err := s.db.QueryContext(ctx, trendQuery, trendArgs...)
	if err != nil {
		return nil, nil, fmt.Errorf("overview events trend: %w", err)
	}
	eventsTrend := []TelemetryMetricPoint{}
	for rows.Next() {
		var bucket string
		var val float64
		if err := rows.Scan(&bucket, &val); err != nil {
			_ = rows.Close()
			return nil, nil, fmt.Errorf("scan events trend: %w", err)
		}
		eventsTrend = append(eventsTrend, TelemetryMetricPoint{Timestamp: bucket, Value: val})
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return nil, nil, fmt.Errorf("iterate events trend: %w", err)
	}
	if err := rows.Close(); err != nil {
		return nil, nil, fmt.Errorf("close events trend: %w", err)
	}

	errWhere, errArgs := combineWhere("severity IN ('error', 'critical')")
	errQuery := "SELECT DATE_FORMAT(received_at, '" + dateFormat + "') AS bucket, COUNT(*) " +
		"FROM telemetry_events" + errWhere + " GROUP BY bucket ORDER BY bucket ASC"
	errRows, err := s.db.QueryContext(ctx, errQuery, errArgs...)
	if err != nil {
		return nil, nil, fmt.Errorf("overview errors trend: %w", err)
	}
	errorsTrend := []TelemetryMetricPoint{}
	for errRows.Next() {
		var bucket string
		var val float64
		if err := errRows.Scan(&bucket, &val); err != nil {
			_ = errRows.Close()
			return nil, nil, fmt.Errorf("scan errors trend: %w", err)
		}
		errorsTrend = append(errorsTrend, TelemetryMetricPoint{Timestamp: bucket, Value: val})
	}
	if err := errRows.Err(); err != nil {
		_ = errRows.Close()
		return nil, nil, fmt.Errorf("iterate errors trend: %w", err)
	}
	if err := errRows.Close(); err != nil {
		return nil, nil, fmt.Errorf("close errors trend: %w", err)
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

func (s *MySQLStore) queryOverviewCount(ctx context.Context, query string, args ...any) (int64, error) {
	var count int64
	if err := s.db.QueryRowContext(ctx, query, args...).Scan(&count); err != nil {
		return 0, fmt.Errorf("overview count query failed: %w", err)
	}
	return count, nil
}

func (s *MySQLStore) QueryOverview(ctx context.Context, filter QueryFilter) (*OverviewMetrics, error) {
	if s == nil || s.db == nil || s.catalog == nil {
		return nil, fmt.Errorf("%w: mysql telemetry store is unavailable", ErrServiceUnavailable)
	}
	whereSQL, args := overviewTimeWhere(filter)
	combineWhere := combineOverviewWhere(whereSQL, args)

	w, qArgs := combineWhere("record_type = 'analytics'")
	totalEvents, err := s.queryOverviewCount(ctx, "SELECT COUNT(*) FROM telemetry_events"+w, qArgs...)
	if err != nil {
		return nil, err
	}

	w, qArgs = combineWhere("record_type = 'diagnostic'")
	totalDiagnostics, err := s.queryOverviewCount(ctx, "SELECT COUNT(*) FROM telemetry_events"+w, qArgs...)
	if err != nil {
		return nil, err
	}

	w, qArgs = combineWhere("severity IN ('error', 'critical')")
	errorCount, err := s.queryOverviewCount(ctx, "SELECT COUNT(*) FROM telemetry_events"+w, qArgs...)
	if err != nil {
		return nil, err
	}

	w, qArgs = combineWhere("severity = 'critical'")
	criticalCount, err := s.queryOverviewCount(ctx, "SELECT COUNT(*) FROM telemetry_events"+w, qArgs...)
	if err != nil {
		return nil, err
	}

	w, qArgs = combineWhere("")
	recentActiveDevices, err := s.queryOverviewCount(ctx, "SELECT COUNT(DISTINCT device_id) FROM telemetry_events"+w, qArgs...)
	if err != nil {
		return nil, err
	}

	w, qArgs = combineWhere("severity IN ('error', 'critical')")
	affectedDevicesCount, err := s.queryOverviewCount(ctx, "SELECT COUNT(DISTINCT device_id) FROM telemetry_events"+w, qArgs...)
	if err != nil {
		return nil, err
	}

	w, qArgs = combineWhere("")
	totalSessions, err := s.queryOverviewCount(ctx, "SELECT COUNT(DISTINCT session_id) FROM telemetry_events"+w, qArgs...)
	if err != nil {
		return nil, err
	}

	w, qArgs = combineWhere("severity IN ('error', 'critical')")
	errorSessions, err := s.queryOverviewCount(ctx, "SELECT COUNT(DISTINCT session_id) FROM telemetry_events"+w, qArgs...)
	if err != nil {
		return nil, err
	}

	businessGroups, succeededCount, failedCount, err := s.queryBusinessOperationMetrics(ctx, combineWhere)
	if err != nil {
		return nil, err
	}
	businessDenominator := succeededCount + failedCount
	var successRate float64
	if businessDenominator > 0 {
		successRate = float64(succeededCount) / float64(businessDenominator)
	}

	var errorFreeSessionRate float64
	errorFreeSessionSuccesses := int64(0)
	if totalSessions > 0 {
		errorFreeSessionSuccesses = totalSessions - errorSessions
		if errorFreeSessionSuccesses < 0 {
			errorFreeSessionSuccesses = 0
		}
		errorFreeSessionRate = float64(errorFreeSessionSuccesses) / float64(totalSessions)
	}

	// Real latency percentiles from completed/succeeded operations.
	latency, err := s.queryLatencyPercentiles(ctx, combineWhere)
	if err != nil {
		return nil, err
	}

	// Delivery delay is a client/server clock comparison and is kept separate
	// from the service-boundary ingest duration exposed by Service.QueryOverview.
	deliveryDelay, err := s.queryDeliveryDelayStats(ctx, combineWhere)
	if err != nil {
		return nil, err
	}

	// Ingest/trend volume aggregation.
	eventsTrend, errorsTrend, err := s.queryOverviewTrends(ctx, combineWhere, filter.TimeRange)
	if err != nil {
		return nil, err
	}

	// Live service health: MySQL ping and Redis ping. A failed MySQL probe means
	// the overview is not trustworthy, so it is returned as an admin query error
	// instead of silently serving zero-valued metrics.
	redisStatus := redisHealthStatus(ctx, s.redisCache)
	if err := s.pingMySQL(ctx); err != nil {
		return nil, fmt.Errorf("overview mysql health probe: %w", err)
	}
	status := "healthy"
	if redisStatus != "active" {
		status = "degraded"
	}

	return &OverviewMetrics{
		TotalEvents:                  totalEvents,
		TotalDiagnostics:             totalDiagnostics,
		RecentActiveDevices:          recentActiveDevices,
		ErrorCount:                   errorCount,
		CriticalErrorCount:           criticalCount,
		AffectedDevicesCount:         affectedDevicesCount,
		CoreOperationSuccessRate:     successRate,
		BusinessOperationSuccessRate: successRate,
		BusinessOperationSuccesses:   succeededCount,
		BusinessOperationFailures:    failedCount,
		BusinessOperationDenominator: businessDenominator,
		BusinessOperationGroups:      businessGroups,
		ErrorFreeSessionRate:         errorFreeSessionRate,
		ErrorFreeSessionSuccesses:    errorFreeSessionSuccesses,
		ErrorFreeSessionDenominator:  totalSessions,
		EventsTrend:                  eventsTrend,
		ErrorsTrend:                  errorsTrend,
		Latency:                      latency,
		PipelineHealth: PipelineHealthStats{
			Status:           status,
			RedisCacheStatus: redisStatus,
		},
		DeliveryDelay: deliveryDelay,
	}, nil
}
