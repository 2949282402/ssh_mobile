package telemetry_test

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/ssh-mobile/relay/internal/telemetry"
)

func registerBoundaryMetricEvent(catalog *telemetry.Catalog, name, group, role string, propertyType string) {
	registerBoundaryMetricEventWithProperty(catalog, name, group, role, "duration_ms", propertyType)
}

func registerBoundaryMetricEventWithProperty(catalog *telemetry.Catalog, name, group, role, propertyName, propertyType string) {
	properties := []telemetry.AllowedProperty(nil)
	if propertyType != "" {
		properties = []telemetry.AllowedProperty{{Name: propertyName, Type: propertyType}}
	}
	catalog.RegisterEvent(telemetry.EventDefinition{
		Name:              name,
		Version:           1,
		RecordType:        telemetry.RecordTypeAnalytics,
		Feature:           "coverage-boundary",
		Severity:          telemetry.SeverityInfo,
		OperationGroup:    group,
		OperationRole:     role,
		BusinessOperation: true,
		AllowedProperties: properties,
	})
}

func boundaryMetricEnvelope(catalog *telemetry.Catalog, id, eventName string, properties map[string]any) telemetry.TelemetryEnvelope {
	definition, ok := catalog.GetEvent(eventName)
	if !ok {
		panic(fmt.Sprintf("missing boundary metric event %q", eventName))
	}
	return telemetry.TelemetryEnvelope{
		EventID:      id,
		RecordType:   definition.RecordType,
		EventName:    eventName,
		EventVersion: definition.Version,
		DeviceID:     "coverage-metric-device",
		SessionID:    id,
		TraceID:      "coverage-metric-trace",
		OccurredAt:   time.Now().UTC().Add(-time.Second),
		Feature:      definition.Feature,
		Severity:     definition.Severity,
		AppVersion:   "1.0.0",
		BuildNumber:  "1",
		Platform:     "linux",
		Properties:   properties,
	}
}

func TestOverviewMetricsCoversRelativeRangesPrimitiveLatenciesAndEmptyGroups(t *testing.T) {
	catalog := telemetry.NewCatalog()
	registerBoundaryMetricEvent(catalog, "coverage-latency-integer", "primitive", "success", "integer")
	registerBoundaryMetricEventWithProperty(catalog, "coverage-latency-alias", "primitive", "success", "latency_ms", "integer")
	registerBoundaryMetricEvent(catalog, "coverage-latency-string", "string-value", "success", "string")
	registerBoundaryMetricEvent(catalog, "coverage-empty-success", "", "success", "")
	registerBoundaryMetricEvent(catalog, "coverage-empty-failure", "", "failure", "")
	store := telemetry.NewMemoryStore(catalog)

	records := []telemetry.TelemetryEnvelope{
		boundaryMetricEnvelope(catalog, "float64", "coverage-latency-integer", map[string]any{"duration_ms": float64(11)}),
		boundaryMetricEnvelope(catalog, "float32", "coverage-latency-integer", map[string]any{"duration_ms": float32(12)}),
		boundaryMetricEnvelope(catalog, "int", "coverage-latency-integer", map[string]any{"duration_ms": int(13)}),
		boundaryMetricEnvelope(catalog, "int64", "coverage-latency-integer", map[string]any{"duration_ms": int64(14)}),
		boundaryMetricEnvelope(catalog, "int32", "coverage-latency-integer", map[string]any{"duration_ms": int32(15)}),
		boundaryMetricEnvelope(catalog, "uint64", "coverage-latency-integer", map[string]any{"duration_ms": uint64(16)}),
		boundaryMetricEnvelope(catalog, "json-number", "coverage-latency-integer", map[string]any{"duration_ms": json.Number("17")}),
		boundaryMetricEnvelope(catalog, "alias", "coverage-latency-alias", map[string]any{"latency_ms": int64(19)}),
		boundaryMetricEnvelope(catalog, "zero", "coverage-latency-integer", map[string]any{"duration_ms": int64(0)}),
		boundaryMetricEnvelope(catalog, "negative", "coverage-latency-integer", map[string]any{"duration_ms": int64(-1)}),
		boundaryMetricEnvelope(catalog, "missing", "coverage-latency-integer", nil),
		boundaryMetricEnvelope(catalog, "string", "coverage-latency-string", map[string]any{"duration_ms": "not-a-number"}),
		boundaryMetricEnvelope(catalog, "empty-success", "coverage-empty-success", nil),
		boundaryMetricEnvelope(catalog, "empty-failure", "coverage-empty-failure", nil),
	}
	results, err := store.IngestBatch(context.Background(), records)
	if err != nil {
		t.Fatalf("ingest metric boundary records: %v", err)
	}
	for _, result := range results {
		if result.Status != telemetry.StatusAccepted {
			t.Fatalf("metric boundary event %q status = %q, want accepted", result.EventID, result.Status)
		}
	}

	for _, timeRange := range []string{"1h", "1d", "24h", "7d", "30d", "2h", "unknown", "all"} {
		metrics, err := store.QueryOverview(context.Background(), telemetry.QueryFilter{TimeRange: timeRange})
		if err != nil {
			t.Fatalf("overview range %q: %v", timeRange, err)
		}
		if metrics.BusinessOperationDenominator != 14 || metrics.BusinessOperationSuccesses != 13 || metrics.BusinessOperationFailures != 1 {
			t.Fatalf("range %q business totals = %+v, want 13/1 denominator 14", timeRange, metrics)
		}
	}
	metrics, err := store.QueryOverview(context.Background(), telemetry.QueryFilter{})
	if err != nil {
		t.Fatalf("unbounded overview: %v", err)
	}
	if metrics.Latency.Samples != 8 {
		t.Fatalf("latency samples = %d, want seven primitive values plus alias", metrics.Latency.Samples)
	}
	if metrics.Latency.P50Ms <= 0 || metrics.Latency.P99Ms < metrics.Latency.P50Ms {
		t.Fatalf("latency percentiles = %+v, want positive sorted values", metrics.Latency)
	}
	if len(metrics.BusinessOperationGroups) != 2 {
		t.Fatalf("business groups = %+v, want primitive/string groups (empty group is aggregate-only)", metrics.BusinessOperationGroups)
	}
}

func TestOverviewMetricsCapsCustomBusinessGroups(t *testing.T) {
	catalog := telemetry.NewCatalog()
	for i := 0; i < 65; i++ {
		name := fmt.Sprintf("coverage-group-%02d", i)
		registerBoundaryMetricEvent(catalog, name, fmt.Sprintf("group-%02d", i), "success", "")
	}
	registerBoundaryMetricEvent(catalog, "coverage-group-zero-failure", "group-00", "failure", "")
	store := telemetry.NewMemoryStore(catalog)
	records := make([]telemetry.TelemetryEnvelope, 0, 66)
	for i := 0; i < 65; i++ {
		records = append(records, boundaryMetricEnvelope(catalog, fmt.Sprintf("group-event-%02d", i), fmt.Sprintf("coverage-group-%02d", i), nil))
	}
	records = append(records, boundaryMetricEnvelope(catalog, "group-event-failure", "coverage-group-zero-failure", nil))
	results, err := store.IngestBatch(context.Background(), records)
	if err != nil {
		t.Fatalf("ingest group records: %v", err)
	}
	for _, result := range results {
		if result.Status != telemetry.StatusAccepted {
			t.Fatalf("group event %q status = %q, want accepted", result.EventID, result.Status)
		}
	}
	metrics, err := store.QueryOverview(context.Background(), telemetry.QueryFilter{})
	if err != nil {
		t.Fatalf("query capped groups: %v", err)
	}
	if len(metrics.BusinessOperationGroups) != 64 {
		t.Fatalf("business group count = %d, want defensive cap 64", len(metrics.BusinessOperationGroups))
	}
	if metrics.BusinessOperationSuccesses != 65 || metrics.BusinessOperationFailures != 1 || metrics.BusinessOperationDenominator != 66 {
		t.Fatalf("capped group totals = successes=%d failures=%d denominator=%d, want 65/1/66", metrics.BusinessOperationSuccesses, metrics.BusinessOperationFailures, metrics.BusinessOperationDenominator)
	}
}
