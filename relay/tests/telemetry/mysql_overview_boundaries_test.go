package telemetry_test

import (
	"context"
	"testing"

	"github.com/ssh-mobile/relay/internal/telemetry"
)

func TestMySQLOverviewAggregatesDataAndAppliesReleaseFilters(t *testing.T) {
	store, _, closeStore := newOverviewProbeStore(t, "business-data")
	defer closeStore()
	metrics, err := store.QueryOverview(context.Background(), telemetry.QueryFilter{ReleaseChannel: "stable"})
	if err != nil {
		t.Fatalf("business overview: %v", err)
	}
	if metrics.BusinessOperationSuccesses != 3 || metrics.BusinessOperationFailures != 2 || metrics.BusinessOperationDenominator != 5 {
		t.Fatalf("business totals = successes=%d failures=%d denominator=%d, want 3/2/5", metrics.BusinessOperationSuccesses, metrics.BusinessOperationFailures, metrics.BusinessOperationDenominator)
	}
	if len(metrics.BusinessOperationGroups) != 1 || metrics.BusinessOperationGroups[0].OperationGroup != "network.quic" {
		t.Fatalf("business groups = %+v, want network.quic", metrics.BusinessOperationGroups)
	}
}

func TestMySQLOverviewHandlesEmptyCatalogAndCountOutcomes(t *testing.T) {
	store, _, closeStore := newOverviewProbeStoreWithCatalog(t, "ok", telemetry.NewCatalog())
	defer closeStore()
	metrics, err := store.QueryOverview(context.Background(), telemetry.QueryFilter{})
	if err != nil {
		t.Fatalf("empty catalog overview: %v", err)
	}
	if metrics.BusinessOperationDenominator != 0 || len(metrics.BusinessOperationGroups) != 0 {
		t.Fatalf("empty catalog business metrics = %+v, want no groups/denominator", metrics)
	}
	if metrics.Latency.Samples != 0 {
		t.Fatalf("empty catalog latency = %+v, want no samples", metrics.Latency)
	}

	store, _, closeStore = newOverviewProbeStore(t, "count-values")
	defer closeStore()
	metrics, err = store.QueryOverview(context.Background(), telemetry.QueryFilter{})
	if err != nil {
		t.Fatalf("count outcome overview: %v", err)
	}
	if metrics.TotalEvents != 5 || metrics.TotalDiagnostics != 2 || metrics.ErrorCount != 3 || metrics.CriticalErrorCount != 1 || metrics.RecentActiveDevices != 4 || metrics.AffectedDevicesCount != 2 {
		t.Fatalf("count metrics = %+v, want configured probe values", metrics)
	}
	if metrics.ErrorFreeSessionDenominator != 3 || metrics.ErrorFreeSessionSuccesses != 2 || metrics.ErrorFreeSessionRate != 2.0/3.0 {
		t.Fatalf("session metrics = denominator=%d successes=%d rate=%v, want 3/2/2/3", metrics.ErrorFreeSessionDenominator, metrics.ErrorFreeSessionSuccesses, metrics.ErrorFreeSessionRate)
	}
}

func TestMySQLOverviewAggregatesLatencyAndDeliverySamples(t *testing.T) {
	store, _, closeStore := newOverviewProbeStore(t, "latency-data")
	defer closeStore()
	metrics, err := store.QueryOverview(context.Background(), telemetry.QueryFilter{})
	if err != nil {
		t.Fatalf("latency overview: %v", err)
	}
	if metrics.Latency.Samples != 2 || metrics.Latency.P50Ms != 10 || metrics.Latency.P95Ms != 20 || metrics.Latency.P99Ms != 20 {
		t.Fatalf("latency metrics = %+v, want samples 2 and percentiles 10/20/20", metrics.Latency)
	}

	store, _, closeStore = newOverviewProbeStore(t, "delivery-data")
	defer closeStore()
	metrics, err = store.QueryOverview(context.Background(), telemetry.QueryFilter{})
	if err != nil {
		t.Fatalf("delivery overview: %v", err)
	}
	if metrics.DeliveryDelay.Samples != 2 || metrics.DeliveryDelay.FutureTimestampCount != 1 || metrics.DeliveryDelay.P50Ms != 0 || metrics.DeliveryDelay.P95Ms != 10 || metrics.DeliveryDelay.P99Ms != 10 {
		t.Fatalf("delivery metrics = %+v, want two samples with one future timestamp", metrics.DeliveryDelay)
	}
}
