package telemetry

import (
	"context"
	"sort"
	"time"
)

func (m *MemoryStore) QueryOverview(ctx context.Context, filter QueryFilter) (*OverviewMetrics, error) {
	filter = normalizeOverviewFilter(filter, time.Now().UTC())
	m.mu.RLock()
	defer m.mu.RUnlock()

	var totalEvents int64
	var totalDiagnostics int64
	var errorCount int64
	var criticalCount int64

	devicesSet := make(map[string]struct{})
	errorDevicesSet := make(map[string]struct{})
	sessionTotal := make(map[string]struct{})
	sessionErrors := make(map[string]struct{})

	var latencyValues []float64
	var deliveryRecords []TelemetryEnvelope
	businessGroups := newBusinessOperationMetrics()
	var businessSuccesses int64
	var businessFailures int64

	trendRange := filter.TimeRange
	trendEvents := make(map[string]float64)
	trendErrors := make(map[string]float64)

	for _, env := range m.rawEvents {
		if filter.ReleaseChannel != "" && env.ReleaseChannel != filter.ReleaseChannel {
			continue
		}
		if !filter.StartTime.IsZero() && env.ReceivedAt.Before(filter.StartTime) {
			continue
		}
		if !filter.EndTime.IsZero() && env.ReceivedAt.After(filter.EndTime) {
			continue
		}

		devicesSet[env.DeviceID] = struct{}{}

		if env.RecordType == RecordTypeAnalytics {
			totalEvents++
		} else if env.RecordType == RecordTypeDiagnostic {
			totalDiagnostics++
		}

		if env.Severity == SeverityError || env.Severity == SeverityCritical {
			errorCount++
			errorDevicesSet[env.DeviceID] = struct{}{}
			sessionErrors[env.SessionID] = struct{}{}
		}
		if env.Severity == SeverityCritical {
			criticalCount++
		}

		sessionTotal[env.SessionID] = struct{}{}

		if group, role, ok := businessOutcome(m.catalog, &env); ok {
			successes, failures := recordBusinessOutcome(businessGroups, group, role)
			businessSuccesses += successes
			businessFailures += failures
		}

		// Completion latency samples are restricted to catalog-declared
		// successful business operations carrying a duration property.
		if _, role, ok := businessOutcome(m.catalog, &env); ok && role == "success" {
			if d, ok := extractLatencyFromProps(env.Properties); ok {
				latencyValues = append(latencyValues, d)
			}
		}

		if !env.ReceivedAt.IsZero() && !env.OccurredAt.IsZero() {
			deliveryRecords = append(deliveryRecords, env)
		}

		// EventsTrend is the analytics-only series and therefore has the same
		// denominator as TotalEvents. Diagnostic rows remain in ErrorCount and
		// ErrorsTrend, whose denominator is the all-record error count.
		bucket := overviewTrendTimestamp(env.ReceivedAt, trendRange)
		if env.RecordType == RecordTypeAnalytics {
			trendEvents[bucket]++
		}
		if env.Severity == SeverityError || env.Severity == SeverityCritical {
			trendErrors[bucket]++
		}
	}

	businessMetrics := buildBusinessOperationMetrics(businessGroups)
	businessDenominator := businessSuccesses + businessFailures
	var businessSuccessRate float64
	if businessDenominator > 0 {
		businessSuccessRate = float64(businessSuccesses) / float64(businessDenominator)
	}

	latency := latencyStats(latencyValues)

	var errorFreeSessionRate float64
	errorFreeSessionSuccesses := 0
	if len(sessionTotal) > 0 {
		errorFreeSessionSuccesses = len(sessionTotal) - len(sessionErrors)
		if errorFreeSessionSuccesses < 0 {
			errorFreeSessionSuccesses = 0
		}
		errorFreeSessionRate = float64(errorFreeSessionSuccesses) / float64(len(sessionTotal))
	}

	var eventsTrend []TelemetryMetricPoint
	for ts, val := range trendEvents {
		eventsTrend = append(eventsTrend, TelemetryMetricPoint{Timestamp: ts, Value: val})
	}
	sort.Slice(eventsTrend, func(i, j int) bool {
		return eventsTrend[i].Timestamp < eventsTrend[j].Timestamp
	})

	var errorsTrend []TelemetryMetricPoint
	for ts, val := range trendErrors {
		errorsTrend = append(errorsTrend, TelemetryMetricPoint{Timestamp: ts, Value: val})
	}
	sort.Slice(errorsTrend, func(i, j int) bool {
		return errorsTrend[i].Timestamp < errorsTrend[j].Timestamp
	})

	// Live service health for the in-memory store: MySQL is not backed by a real
	// database so only the cache status is reported dynamically.
	redisStatus := redisHealthStatus(ctx, m.redisCache)
	status := "healthy"
	if redisStatus != "active" {
		status = "degraded"
	}

	return &OverviewMetrics{
		TotalEvents:                  totalEvents,
		TotalDiagnostics:             totalDiagnostics,
		RecentActiveDevices:          int64(len(devicesSet)),
		ErrorCount:                   errorCount,
		CriticalErrorCount:           criticalCount,
		AffectedDevicesCount:         int64(len(errorDevicesSet)),
		CoreOperationSuccessRate:     businessSuccessRate,
		BusinessOperationSuccessRate: businessSuccessRate,
		BusinessOperationSuccesses:   businessSuccesses,
		BusinessOperationFailures:    businessFailures,
		BusinessOperationDenominator: businessDenominator,
		BusinessOperationGroups:      businessMetrics,
		ErrorFreeSessionRate:         errorFreeSessionRate,
		ErrorFreeSessionSuccesses:    int64(errorFreeSessionSuccesses),
		ErrorFreeSessionDenominator:  int64(len(sessionTotal)),
		EventsTrend:                  eventsTrend,
		ErrorsTrend:                  errorsTrend,
		Latency:                      latency,
		PipelineHealth: PipelineHealthStats{
			Status:           status,
			RedisCacheStatus: redisStatus,
		},
		DeliveryDelay: deliveryDelayStats(deliveryRecords),
	}, nil
}
