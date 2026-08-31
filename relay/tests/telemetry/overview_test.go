package telemetry_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/ssh-mobile/relay/internal/telemetry"
)

func overviewRecord(t *testing.T, catalog *telemetry.Catalog, id, eventName string, occurredAt time.Time) telemetry.TelemetryEnvelope {
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
		DeviceID:     "overview-device",
		SessionID:    "overview-session",
		TraceID:      "overview-trace",
		OccurredAt:   occurredAt,
		Feature:      definition.Feature,
		Severity:     definition.Severity,
		AppVersion:   "1.0.0",
		BuildNumber:  "100",
		Platform:     "android",
		Properties:   properties,
	}
}

func ingestOverviewRecords(t *testing.T, store *telemetry.MemoryStore, records ...telemetry.TelemetryEnvelope) {
	t.Helper()
	results, err := store.IngestBatch(context.Background(), records)
	if err != nil {
		t.Fatalf("ingest overview records: %v", err)
	}
	for _, result := range results {
		if result.Status != telemetry.StatusAccepted {
			t.Fatalf("overview fixture %q status = %q, want accepted", result.EventID, result.Status)
		}
	}
}

func TestOverviewZeroDenominatorsAreExplicitNoData(t *testing.T) {
	catalog := telemetry.DefaultCatalog()
	store := telemetry.NewMemoryStore(catalog)
	service := telemetry.NewService(store, catalog, &telemetry.NoopRedisCache{})

	metrics, err := service.QueryOverview(context.Background(), telemetry.QueryFilter{})
	if err != nil {
		t.Fatalf("empty overview query: %v", err)
	}
	if metrics.BusinessOperationDenominator != 0 || metrics.BusinessOperationSuccessRate != 0 {
		t.Fatalf("empty business metrics = denominator %d rate %v, want 0/0", metrics.BusinessOperationDenominator, metrics.BusinessOperationSuccessRate)
	}
	if metrics.ErrorFreeSessionDenominator != 0 || metrics.ErrorFreeSessionRate != 0 {
		t.Fatalf("empty session metrics = denominator %d rate %v, want 0/0", metrics.ErrorFreeSessionDenominator, metrics.ErrorFreeSessionRate)
	}
	health := metrics.PipelineHealth
	if health.ServerIngestRequests != 0 || health.ServerIngestErrorRate != 0 {
		t.Fatalf("empty ingest metrics = requests %d error rate %v, want 0/0", health.ServerIngestRequests, health.ServerIngestErrorRate)
	}
	encoded, err := json.Marshal(metrics)
	if err != nil {
		t.Fatalf("marshal empty overview: %v", err)
	}
	if strings.Contains(string(encoded), `"businessOperationSuccessRate":1`) || strings.Contains(string(encoded), `"errorFreeSessionRate":1`) {
		t.Fatalf("empty overview serialized a misleading 100%% rate: %s", encoded)
	}
}

func TestOverviewTrendBucketsMatchRangeAndAnalyticsDenominator(t *testing.T) {
	catalog := telemetry.DefaultCatalog()
	store := telemetry.NewMemoryStore(catalog)
	now := time.Now().UTC()
	records := []telemetry.TelemetryEnvelope{
		overviewRecord(t, catalog, "analytics", "ssh.session.started", now),
	}
	for i := 0; i < 5; i++ {
		records = append(records, overviewRecord(t, catalog, fmt.Sprintf("diagnostic-%d", i), "app.diagnostic.log", now))
	}
	ingestOverviewRecords(t, store, records...)

	tests := []struct {
		name       string
		timeRange  string
		wantFormat string
	}{
		{name: "one day", timeRange: "1d", wantFormat: "2006-01-02T15:00:00Z"},
		{name: "seven days", timeRange: "7d", wantFormat: "2006-01-02T00:00:00Z"},
		{name: "thirty days", timeRange: "30d", wantFormat: "2006-01-02T00:00:00Z"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			metrics, err := store.QueryOverview(context.Background(), telemetry.QueryFilter{
				TimeRange: test.timeRange,
				StartTime: now.Add(-31 * 24 * time.Hour),
				EndTime:   now.Add(time.Minute),
			})
			if err != nil {
				t.Fatalf("overview query: %v", err)
			}
			if metrics.TotalEvents != 1 {
				t.Fatalf("total analytics events = %d, want 1", metrics.TotalEvents)
			}
			var trendTotal float64
			for _, point := range metrics.EventsTrend {
				trendTotal += point.Value
				if _, err := time.Parse(test.wantFormat, point.Timestamp); err != nil {
					t.Fatalf("trend timestamp %q does not use %s buckets: %v", point.Timestamp, test.wantFormat, err)
				}
			}
			if trendTotal != float64(metrics.TotalEvents) {
				t.Fatalf("analytics trend total = %v, totalEvents = %d", trendTotal, metrics.TotalEvents)
			}
		})
	}
}

func TestTelemetryHandlerReturnsMySQLOverviewErrors(t *testing.T) {
	for _, mode := range []string{"count-error", "latency-rows-error", "delivery-rows-error", "trend-query-error", "ping-error"} {
		t.Run(mode, func(t *testing.T) {
			store, _, closeStore := newOverviewProbeStore(t, mode)
			defer closeStore()
			service := telemetry.NewService(store, telemetry.DefaultCatalog(), &telemetry.NoopRedisCache{})
			handler := telemetry.NewHandler(service)
			mux := http.NewServeMux()
			handler.RegisterAdminRoutes(mux, func(next http.HandlerFunc) http.HandlerFunc { return next })

			recorder := httptest.NewRecorder()
			mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, telemetry.PathAdminOverview, nil))
			if recorder.Code != http.StatusInternalServerError {
				t.Fatalf("overview error status = %d, want %d: %s", recorder.Code, http.StatusInternalServerError, recorder.Body.String())
			}
			if !strings.Contains(recorder.Body.String(), "QUERY_ERROR") {
				t.Fatalf("overview error body = %s, want QUERY_ERROR", recorder.Body.String())
			}
		})
	}
}

func TestFutureOccurredAtValidationUsesBoundedSkew(t *testing.T) {
	catalog := telemetry.DefaultCatalog()
	now := time.Date(2026, time.August, 28, 4, 0, 0, 0, time.UTC)
	within := overviewRecord(t, catalog, "future-within", "ssh.session.started", now.Add(4*time.Minute))
	if err := catalog.ValidateEnvelopeAt(&within, now); err != nil {
		t.Fatalf("normal clock skew was rejected: %v", err)
	}
	tooFar := overviewRecord(t, catalog, "future-too-far", "ssh.session.started", now.Add(telemetry.MaxTelemetryFutureSkew+time.Second))
	if err := catalog.ValidateEnvelopeAt(&tooFar, now); err == nil {
		t.Fatal("obviously future occurredAt was accepted")
	} else if !errors.Is(err, telemetry.ErrOccurredAtTooFarInFuture) {
		t.Fatalf("future timestamp error = %v, want ErrOccurredAtTooFarInFuture", err)
	}
	old := overviewRecord(t, catalog, "offline-old", "ssh.session.started", now.Add(-365*24*time.Hour))
	if err := catalog.ValidateEnvelopeAt(&old, now); err != nil {
		t.Fatalf("old offline event was rejected: %v", err)
	}

	store := telemetry.NewMemoryStore(catalog)
	ingestFuture := overviewRecord(t, catalog, "ingest-future-too-far", "ssh.session.started", time.Now().UTC().Add(telemetry.MaxTelemetryFutureSkew+time.Minute))
	results, err := store.IngestBatch(context.Background(), []telemetry.TelemetryEnvelope{ingestFuture})
	if err != nil {
		t.Fatalf("future ingest returned batch error: %v", err)
	}
	if len(results) != 1 || results[0].Status != telemetry.StatusRejected {
		t.Fatalf("future ingest result = %+v, want one rejected result", results)
	}
	events, total, err := store.QueryEvents(context.Background(), telemetry.QueryFilter{Page: 1, PageSize: 10})
	if err != nil {
		t.Fatalf("query after rejected future ingest: %v", err)
	}
	if total != 0 || len(events) != 0 {
		t.Fatalf("rejected future ingest persisted data: total=%d events=%d", total, len(events))
	}
}
