package telemetry

import (
	"encoding/json"
	"math"
	"sort"
	"sync"
	"time"
)

// OverviewMetrics holds aggregated metrics for the dashboard.
type OverviewMetrics struct {
	TotalEvents          int64 `json:"totalEvents"`
	TotalDiagnostics     int64 `json:"totalDiagnostics"`
	RecentActiveDevices  int64 `json:"recentActiveDevices"`
	ErrorCount           int64 `json:"errorCount"`
	CriticalErrorCount   int64 `json:"criticalErrorCount"`
	AffectedDevicesCount int64 `json:"affectedDevicesCount"`
	// CoreOperationSuccessRate is retained as a compatibility alias for the
	// dashboard field that predated the explicit business-operation contract.
	// It is calculated from the same catalog-defined business outcomes as
	// BusinessOperationSuccessRate; it never infers an outcome from an event
	// name suffix or severity.
	CoreOperationSuccessRate     float64                         `json:"coreOperationSuccessRate"`
	BusinessOperationSuccessRate float64                         `json:"businessOperationSuccessRate"`
	BusinessOperationSuccesses   int64                           `json:"businessOperationSuccesses"`
	BusinessOperationFailures    int64                           `json:"businessOperationFailures"`
	BusinessOperationDenominator int64                           `json:"businessOperationDenominator"`
	BusinessOperationGroups      []BusinessOperationGroupMetrics `json:"businessOperationGroups"`
	ErrorFreeSessionRate         float64                         `json:"errorFreeSessionRate"`
	EventsTrend                  []TelemetryMetricPoint          `json:"eventsTrend"`
	ErrorsTrend                  []TelemetryMetricPoint          `json:"errorsTrend"`
	Latency                      LatencyStats                    `json:"latency"`
	PipelineHealth               PipelineHealthStats             `json:"pipelineHealth"`
	DeliveryDelay                DeliveryDelayStats              `json:"deliveryDelay"`
}

// BusinessOperationGroupMetrics contains terminal outcomes for one
// catalog-defined operation group. Only events with businessOperation=true
// and operationRole=success|failure contribute; started, fallback, and
// diagnostic roles are intentionally excluded.
type BusinessOperationGroupMetrics struct {
	OperationGroup string  `json:"operationGroup"`
	Successes      int64   `json:"successes"`
	Failures       int64   `json:"failures"`
	Denominator    int64   `json:"denominator"`
	SuccessRate    float64 `json:"successRate"`
}

// DeliveryDelayStats describes the client-to-server delivery delay computed
// as receivedAt - occurredAt. A client timestamp that is in the future is a
// clock-skew sample: it remains in the denominator with a zero-millisecond
// clamped delay and increments FutureTimestampCount. Samples with either
// timestamp absent are not measurable and are excluded.
type DeliveryDelayStats struct {
	AverageMs            float64 `json:"averageMs"`
	P50Ms                float64 `json:"p50Ms"`
	P95Ms                float64 `json:"p95Ms"`
	P99Ms                float64 `json:"p99Ms"`
	Samples              int64   `json:"samples"`
	FutureTimestampCount int64   `json:"futureTimestampCount"`
}

// ingestMetricsSnapshot is a bounded snapshot of service-boundary ingestion
// outcomes. It contains no device, event, trace, or other request-controlled
// labels, so its cardinality is constant regardless of input traffic.
type ingestMetricsSnapshot struct {
	Requests         int64
	Successes        int64
	Failures         int64
	AverageLatencyMs float64
	Latency          LatencyStats
}

// ingestMetrics records the service/store boundary for public telemetry
// ingestion. The fixed sample ring is deliberately bounded; counters and the
// latency sum remain scalar and are safe for concurrent callers.
type ingestMetrics struct {
	mu             sync.Mutex
	requests       int64
	successes      int64
	failures       int64
	latencySumMs   float64
	latencySamples []float64
	nextSample     int
}

const maxIngestLatencySamples = 1024

func newIngestMetrics() *ingestMetrics {
	return &ingestMetrics{
		latencySamples: make([]float64, 0, maxIngestLatencySamples),
	}
}

// record records one service-boundary attempt. A nil error means that the
// store completed and returned a valid per-record ACK list; individual
// accepted/already_seen/rejected ACK statuses are therefore not failures.
func (m *ingestMetrics) record(duration time.Duration, err error) {
	if m == nil {
		return
	}
	if duration < 0 {
		duration = 0
	}
	latencyMs := float64(duration) / float64(time.Millisecond)
	m.mu.Lock()
	defer m.mu.Unlock()
	m.requests++
	if err == nil {
		m.successes++
	} else {
		m.failures++
	}
	m.latencySumMs += latencyMs
	if len(m.latencySamples) < maxIngestLatencySamples {
		m.latencySamples = append(m.latencySamples, latencyMs)
		return
	}
	m.latencySamples[m.nextSample] = latencyMs
	m.nextSample = (m.nextSample + 1) % maxIngestLatencySamples
}

// snapshot returns a race-free copy of the bounded service-ingest metrics.
func (m *ingestMetrics) snapshot() ingestMetricsSnapshot {
	if m == nil {
		return ingestMetricsSnapshot{}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	values := append([]float64(nil), m.latencySamples...)
	latency := latencyStats(values)
	average := float64(0)
	if m.requests > 0 {
		average = m.latencySumMs / float64(m.requests)
	}
	return ingestMetricsSnapshot{
		Requests:         m.requests,
		Successes:        m.successes,
		Failures:         m.failures,
		AverageLatencyMs: average,
		Latency:          latency,
	}
}

func pipelineHealthWithIngestMetrics(health PipelineHealthStats, metrics *ingestMetrics) PipelineHealthStats {
	snapshot := metrics.snapshot()
	health.ServerIngestLatencyMs = snapshot.AverageLatencyMs
	health.ServerIngestLatencyP50Ms = snapshot.Latency.P50Ms
	health.ServerIngestLatencyP95Ms = snapshot.Latency.P95Ms
	health.ServerIngestLatencyP99Ms = snapshot.Latency.P99Ms
	health.ServerIngestLatencySamples = snapshot.Latency.Samples
	health.ServerIngestRequests = snapshot.Requests
	health.ServerIngestSuccesses = snapshot.Successes
	health.ServerIngestFailures = snapshot.Failures
	if snapshot.Requests > 0 {
		health.ServerIngestErrorRate = float64(snapshot.Failures) / float64(snapshot.Requests)
	} else {
		health.ServerIngestErrorRate = 0
	}
	return health
}

// LatencyStats holds completion latency percentiles (in milliseconds) for
// catalog-declared successful business operations in the queried time range.
// Samples == 0 means no latency data is available.
type LatencyStats struct {
	P50Ms   float64 `json:"p50Ms"`
	P95Ms   float64 `json:"p95Ms"`
	P99Ms   float64 `json:"p99Ms"`
	Samples int64   `json:"samples"`
}

type TelemetryMetricPoint struct {
	Timestamp string  `json:"timestamp"`
	Value     float64 `json:"value"`
}

// PipelineHealthStats contains live pipeline state plus process-lifetime
// Service.IngestBatch boundary metrics. The latency average uses every
// boundary attempt; percentile fields use the bounded recent sample ring.
// Authentication, decoding, admission, and per-record rejected ACKs are not
// service failures.
type PipelineHealthStats struct {
	Status                     string  `json:"status"` // healthy, degraded, unhealthy
	ServerIngestLatencyMs      float64 `json:"serverIngestLatencyMs"`
	ServerIngestLatencyP50Ms   float64 `json:"serverIngestLatencyP50Ms"`
	ServerIngestLatencyP95Ms   float64 `json:"serverIngestLatencyP95Ms"`
	ServerIngestLatencyP99Ms   float64 `json:"serverIngestLatencyP99Ms"`
	ServerIngestLatencySamples int64   `json:"serverIngestLatencySamples"`
	ServerIngestRequests       int64   `json:"serverIngestRequests"`
	ServerIngestSuccesses      int64   `json:"serverIngestSuccesses"`
	ServerIngestFailures       int64   `json:"serverIngestFailures"`
	ServerIngestErrorRate      float64 `json:"serverIngestErrorRate"`
	RedisCacheStatus           string  `json:"redisCacheStatus"`
}

const maxBusinessOperationGroups = 64

// businessOutcome returns the outcome declared by the canonical catalog for an
// envelope. It deliberately does not inspect EventName, Severity, or Error:
// those fields describe transport/diagnostic detail and are not a terminal
// business outcome contract.
func businessOutcome(catalog *Catalog, env *TelemetryEnvelope) (string, string, bool) {
	if catalog == nil || env == nil {
		return "", "", false
	}
	definition, ok := catalog.GetEvent(env.EventName)
	if !ok || !definition.BusinessOperation {
		return "", "", false
	}
	switch definition.OperationRole {
	case "success", "failure":
		return definition.OperationGroup, definition.OperationRole, true
	default:
		// started, fallback, state_change, and diagnostic are intentionally
		// non-terminal even when their operation group is business-related.
		return "", "", false
	}
}

type businessOperationAccumulator struct {
	group     string
	successes int64
	failures  int64
}

func newBusinessOperationMetrics() map[string]*businessOperationAccumulator {
	return make(map[string]*businessOperationAccumulator)
}

func recordBusinessOutcome(
	groups map[string]*businessOperationAccumulator,
	group string,
	role string,
) (successes, failures int64) {
	if group == "" {
		if role == "success" {
			return 1, 0
		}
		if role == "failure" {
			return 0, 1
		}
		return 0, 0
	}
	accumulator, ok := groups[group]
	if !ok {
		// Business groups are catalog-owned and normally fewer than this bound.
		// Keep a defensive cap so a test/custom catalog cannot turn an overview
		// request into an unbounded map allocation.
		if len(groups) >= maxBusinessOperationGroups {
			if role == "success" {
				return 1, 0
			}
			if role == "failure" {
				return 0, 1
			}
			return 0, 0
		}
		accumulator = &businessOperationAccumulator{group: group}
		groups[group] = accumulator
	}
	if role == "success" {
		accumulator.successes++
		return 1, 0
	} else if role == "failure" {
		accumulator.failures++
		return 0, 1
	}
	return 0, 0
}

func buildBusinessOperationMetrics(groups map[string]*businessOperationAccumulator) []BusinessOperationGroupMetrics {
	keys := make([]string, 0, len(groups))
	for group := range groups {
		keys = append(keys, group)
	}
	sort.Strings(keys)
	result := make([]BusinessOperationGroupMetrics, 0, len(keys))
	for _, group := range keys {
		accumulator := groups[group]
		denominator := accumulator.successes + accumulator.failures
		rate := float64(1)
		if denominator > 0 {
			rate = float64(accumulator.successes) / float64(denominator)
		}
		result = append(result, BusinessOperationGroupMetrics{
			OperationGroup: group,
			Successes:      accumulator.successes,
			Failures:       accumulator.failures,
			Denominator:    denominator,
			SuccessRate:    rate,
		})
	}
	return result
}

func deliveryDelayStats(envelopes []TelemetryEnvelope) DeliveryDelayStats {
	values := make([]float64, 0, len(envelopes))
	var sum float64
	var futureCount int64
	for _, env := range envelopes {
		if env.ReceivedAt.IsZero() || env.OccurredAt.IsZero() {
			continue
		}
		delay := env.ReceivedAt.Sub(env.OccurredAt)
		if delay < 0 {
			futureCount++
			delay = 0
		}
		ms := float64(delay) / float64(time.Millisecond)
		values = append(values, ms)
		sum += ms
	}
	if len(values) == 0 {
		return DeliveryDelayStats{FutureTimestampCount: futureCount}
	}
	sort.Float64s(values)
	return DeliveryDelayStats{
		AverageMs:            sum / float64(len(values)),
		P50Ms:                percentile(values, 0.50),
		P95Ms:                percentile(values, 0.95),
		P99Ms:                percentile(values, 0.99),
		Samples:              int64(len(values)),
		FutureTimestampCount: futureCount,
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
