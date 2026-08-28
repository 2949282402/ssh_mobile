package telemetry_test

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/ssh-mobile/relay/internal/telemetry"
)

func metricEnvelope(t *testing.T, catalog *telemetry.Catalog, id, eventName string, occurredAt time.Time) telemetry.TelemetryEnvelope {
	t.Helper()
	definition, ok := catalog.GetEvent(eventName)
	if !ok {
		t.Fatalf("event %q is not registered", eventName)
	}
	properties := make(map[string]any)
	for _, property := range definition.AllowedProperties {
		if !property.Required {
			continue
		}
		switch property.Type {
		case "boolean":
			properties[property.Name] = true
		case "integer":
			properties[property.Name] = int64(1)
		case "number":
			properties[property.Name] = float64(1)
		default:
			properties[property.Name] = "fixture"
		}
	}
	return telemetry.TelemetryEnvelope{
		EventID:      id,
		RecordType:   definition.RecordType,
		EventName:    definition.Name,
		EventVersion: definition.Version,
		DeviceID:     "metrics-device",
		SessionID:    "metrics-session",
		TraceID:      "metrics-trace",
		OccurredAt:   occurredAt,
		Feature:      definition.Feature,
		Severity:     definition.Severity,
		AppVersion:   "1.0.0",
		BuildNumber:  "100",
		Platform:     "android",
		Properties:   properties,
	}
}

func requireAccepted(t *testing.T, results []telemetry.IngestRecordResult, want int) {
	t.Helper()
	if len(results) != want {
		t.Fatalf("ingest result count = %d, want %d", len(results), want)
	}
	for _, result := range results {
		if result.Status != telemetry.StatusAccepted {
			t.Fatalf("event %q status = %q, want accepted", result.EventID, result.Status)
		}
	}
}

func TestBusinessMetricsUseCatalogRolesAndExcludeNonTerminalSignals(t *testing.T) {
	catalog := telemetry.DefaultCatalog()
	catalog.RegisterEvent(telemetry.EventDefinition{
		Name:              "misleading.operation.failed",
		Version:           1,
		RecordType:        telemetry.RecordTypeAnalytics,
		Feature:           "test",
		Severity:          telemetry.SeverityError,
		OperationGroup:    "test.operation",
		OperationRole:     "success",
		BusinessOperation: true,
	})
	catalog.RegisterEvent(telemetry.EventDefinition{
		Name:              "misleading.operation.completed",
		Version:           1,
		RecordType:        telemetry.RecordTypeDiagnostic,
		Feature:           "test",
		Severity:          telemetry.SeverityInfo,
		OperationGroup:    "test.operation",
		OperationRole:     "failure",
		BusinessOperation: true,
	})
	store := telemetry.NewMemoryStore(catalog)
	now := time.Now().UTC()
	records := []telemetry.TelemetryEnvelope{
		metricEnvelope(t, catalog, "role-success", "misleading.operation.failed", now),
		metricEnvelope(t, catalog, "role-failure", "misleading.operation.completed", now),
		metricEnvelope(t, catalog, "started", "ssh.session.started", now),
		metricEnvelope(t, catalog, "fallback", "network.relay.fallback", now),
		metricEnvelope(t, catalog, "delivery-failure", "telemetry.batch.failed", now),
	}
	results, err := store.IngestBatch(context.Background(), records)
	if err != nil {
		t.Fatalf("IngestBatch failed: %v", err)
	}
	requireAccepted(t, results, len(records))

	metrics, err := store.QueryOverview(context.Background(), telemetry.QueryFilter{})
	if err != nil {
		t.Fatalf("QueryOverview failed: %v", err)
	}
	if metrics.BusinessOperationSuccesses != 1 || metrics.BusinessOperationFailures != 1 || metrics.BusinessOperationDenominator != 2 {
		t.Fatalf("catalog-role counts = successes=%d failures=%d denominator=%d, want 1/1/2", metrics.BusinessOperationSuccesses, metrics.BusinessOperationFailures, metrics.BusinessOperationDenominator)
	}
	if metrics.BusinessOperationSuccessRate != 0.5 || metrics.CoreOperationSuccessRate != 0.5 {
		t.Fatalf("catalog-role success rates = business=%v core=%v, want 0.5/0.5", metrics.BusinessOperationSuccessRate, metrics.CoreOperationSuccessRate)
	}
	if metrics.ErrorCount != 1 || metrics.ErrorFreeSessionRate != 0 {
		t.Fatalf("severity/session metrics = errorCount=%d errorFreeSessionRate=%v, want 1/0", metrics.ErrorCount, metrics.ErrorFreeSessionRate)
	}
	if len(metrics.BusinessOperationGroups) != 1 || metrics.BusinessOperationGroups[0].OperationGroup != "test.operation" {
		t.Fatalf("business operation groups = %+v, want only test.operation", metrics.BusinessOperationGroups)
	}
}

func TestDeliveryDelayUsesReceiptMinusOccurrenceAndClampsFutureSkew(t *testing.T) {
	catalog := telemetry.DefaultCatalog()
	startedAt := time.Now().UTC()
	records := []telemetry.TelemetryEnvelope{
		metricEnvelope(t, catalog, "delay-100", "ssh.session.started", startedAt.Add(-100*time.Millisecond)),
		metricEnvelope(t, catalog, "delay-200", "ssh.session.started", startedAt.Add(-200*time.Millisecond)),
		metricEnvelope(t, catalog, "delay-future", "ssh.session.started", startedAt.Add(5*time.Second)),
	}
	store := telemetry.NewMemoryStore(catalog)
	results, err := store.IngestBatch(context.Background(), records)
	if err != nil {
		t.Fatalf("IngestBatch failed: %v", err)
	}
	requireAccepted(t, results, len(records))

	metrics, err := store.QueryOverview(context.Background(), telemetry.QueryFilter{})
	if err != nil {
		t.Fatalf("QueryOverview failed: %v", err)
	}
	delay := metrics.DeliveryDelay
	if delay.Samples != 3 || delay.FutureTimestampCount != 1 {
		t.Fatalf("delivery delay samples/skew = %d/%d, want 3/1", delay.Samples, delay.FutureTimestampCount)
	}
	if delay.AverageMs < 50 || delay.AverageMs > 500 {
		t.Fatalf("delivery delay average = %vms, want roughly 100ms", delay.AverageMs)
	}
	if delay.P95Ms < 100 || delay.P95Ms > 500 {
		t.Fatalf("delivery delay p95 = %vms, want roughly 200ms", delay.P95Ms)
	}
}

func TestServiceOverviewUsesBoundaryIngestMetrics(t *testing.T) {
	catalog := telemetry.DefaultCatalog()
	store := telemetry.NewMemoryStore(catalog)
	service := telemetry.NewService(store, catalog, &telemetry.NoopRedisCache{})
	if _, err := service.IngestBatch(context.Background(), []telemetry.TelemetryEnvelope{
		metricEnvelope(t, catalog, "ingest-success", "ssh.session.started", time.Now().UTC()),
	}); err != nil {
		t.Fatalf("successful ingest failed: %v", err)
	}

	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := service.IngestBatch(canceled, []telemetry.TelemetryEnvelope{
		metricEnvelope(t, catalog, "ingest-canceled", "ssh.session.started", time.Now().UTC()),
	}); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled ingest error = %v, want context.Canceled", err)
	}

	metrics, err := service.QueryOverview(context.Background(), telemetry.QueryFilter{})
	if err != nil {
		t.Fatalf("QueryOverview failed: %v", err)
	}
	health := metrics.PipelineHealth
	if health.ServerIngestRequests != 2 || health.ServerIngestSuccesses != 1 || health.ServerIngestFailures != 1 {
		t.Fatalf("ingest boundary counts = requests=%d successes=%d failures=%d, want 2/1/1", health.ServerIngestRequests, health.ServerIngestSuccesses, health.ServerIngestFailures)
	}
	if health.ServerIngestErrorRate != 0.5 {
		t.Fatalf("ingest boundary error rate = %v, want 0.5", health.ServerIngestErrorRate)
	}
	if health.ServerIngestLatencyMs <= 0 || health.ServerIngestLatencySamples != 2 {
		t.Fatalf("ingest boundary latency = average=%v samples=%d, want positive/2", health.ServerIngestLatencyMs, health.ServerIngestLatencySamples)
	}
}

func TestServiceIngestMetricsAreBoundedAndConcurrencySafe(t *testing.T) {
	catalog := telemetry.DefaultCatalog()
	store := telemetry.NewMemoryStore(catalog)
	service := telemetry.NewService(store, catalog, &telemetry.NoopRedisCache{})
	const (
		workers    = 8
		iterations = 200
	)
	errorsFound := make(chan error, workers*iterations)
	var waitGroup sync.WaitGroup
	for worker := 0; worker < workers; worker++ {
		worker := worker
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			for iteration := 0; iteration < iterations; iteration++ {
				eventID := fmt.Sprintf("bounded-%d-%d", worker, iteration)
				if (worker+iteration)%2 == 0 {
					ctx, cancel := context.WithCancel(context.Background())
					cancel()
					_, err := service.IngestBatch(ctx, []telemetry.TelemetryEnvelope{
						metricEnvelope(t, catalog, eventID, "ssh.session.started", time.Now().UTC()),
					})
					if !errors.Is(err, context.Canceled) {
						errorsFound <- fmt.Errorf("canceled ingest error = %v", err)
					}
					continue
				}
				_, err := service.IngestBatch(context.Background(), []telemetry.TelemetryEnvelope{
					metricEnvelope(t, catalog, eventID, "ssh.session.started", time.Now().UTC()),
				})
				if err != nil {
					errorsFound <- fmt.Errorf("successful ingest error = %v", err)
				}
			}
		}()
	}
	waitGroup.Wait()
	close(errorsFound)
	for err := range errorsFound {
		t.Error(err)
	}

	metrics, err := service.QueryOverview(context.Background(), telemetry.QueryFilter{})
	if err != nil {
		t.Fatalf("QueryOverview failed: %v", err)
	}
	health := metrics.PipelineHealth
	wantRequests := int64(workers * iterations)
	if health.ServerIngestRequests != wantRequests || health.ServerIngestSuccesses+health.ServerIngestFailures != wantRequests {
		t.Fatalf("ingest boundary totals = requests=%d successes=%d failures=%d, want requests=%d and balanced outcomes", health.ServerIngestRequests, health.ServerIngestSuccesses, health.ServerIngestFailures, wantRequests)
	}
	if health.ServerIngestLatencySamples != 1024 {
		t.Fatalf("bounded latency samples = %d, want 1024", health.ServerIngestLatencySamples)
	}
	if health.ServerIngestLatencyMs <= 0 || health.ServerIngestLatencyP95Ms <= 0 {
		t.Fatalf("expected positive latency statistics, got average=%v p95=%v", health.ServerIngestLatencyMs, health.ServerIngestLatencyP95Ms)
	}
}
