package telemetry_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestHandlePublicIngestChunkedBodyBoundaryAndTrailingValidation(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	deviceID := "dev-body-boundary"
	token := mustAuth(t, service, store, deviceID)
	handler := NewHandler(service)
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)
	base, err := json.Marshal(IngestBatchRequest{Records: []TelemetryEnvelope{testEnvelope("evt-boundary", deviceID)}})
	if err != nil {
		t.Fatalf("marshal test batch: %v", err)
	}
	max := int(DefaultIngestConfig().MaxBodyBytes)
	if len(base) >= max {
		t.Fatalf("test payload unexpectedly exceeds configured body limit: %d >= %d", len(base), max)
	}
	exact := append(append([]byte(nil), base...), bytes.Repeat([]byte(" "), max-len(base))...)

	tests := []struct {
		name       string
		body       []byte
		wantStatus int
		wantCode   string
	}{
		{name: "exact chunked body is accepted", body: exact, wantStatus: http.StatusOK},
		{name: "one byte over chunked body is rejected", body: append(append([]byte(nil), exact...), ' '), wantStatus: http.StatusRequestEntityTooLarge, wantCode: "PAYLOAD_TOO_LARGE"},
		{name: "trailing json is rejected", body: append(append([]byte(nil), base...), []byte(` {}`)...), wantStatus: http.StatusBadRequest, wantCode: "INVALID_REQUEST"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, PathPublicIngest, bytes.NewReader(tc.body))
			req.ContentLength = -1
			req.Header.Set("Authorization", "Bearer "+token)
			req.Header.Set("X-Device-Id", deviceID)
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tc.wantStatus, rec.Body.String())
			}
			if tc.wantCode != "" && !strings.Contains(rec.Body.String(), tc.wantCode) {
				t.Fatalf("body = %s, want code %s", rec.Body.String(), tc.wantCode)
			}
		})
	}
}

func TestServiceAndStoresRejectOversizedDirectBatches(t *testing.T) {
	records := make([]TelemetryEnvelope, DefaultIngestMaxBatchSize+1)
	for i := range records {
		records[i] = testEnvelope("evt-direct-"+strconv.Itoa(i), "device-1")
	}

	service := NewServiceWithSecret(NewMemoryStore(DefaultCatalog()), DefaultCatalog(), &NoopRedisCache{}, testAuthSecret)
	if _, err := service.IngestBatch(context.Background(), records); !errors.Is(err, ErrIngestBatchTooLarge) {
		t.Fatalf("service oversized batch error = %v, want ErrIngestBatchTooLarge", err)
	}
	store := NewMemoryStore(DefaultCatalog())
	if _, err := store.IngestBatch(context.Background(), records); !errors.Is(err, ErrIngestBatchTooLarge) {
		t.Fatalf("memory oversized batch error = %v, want ErrIngestBatchTooLarge", err)
	}
	mysqlStore := NewMySQLStore(nil, DefaultCatalog())
	if _, err := mysqlStore.IngestBatch(context.Background(), records); !errors.Is(err, ErrIngestBatchTooLarge) {
		t.Fatalf("mysql oversized batch error = %v, want ErrIngestBatchTooLarge", err)
	}
}

func TestMySQLIngestCanceledContextShortCircuitsBeforeValidation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	store := NewMySQLStore(nil, DefaultCatalog())
	for _, tc := range []struct {
		name      string
		envelopes []TelemetryEnvelope
	}{
		{name: "empty batch", envelopes: nil},
		{name: "all invalid batch", envelopes: []TelemetryEnvelope{{EventID: ""}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := store.IngestBatch(ctx, tc.envelopes); !errors.Is(err, context.Canceled) {
				t.Fatalf("canceled MySQL ingest error = %v, want context.Canceled", err)
			}
		})
	}
	overSized := make([]TelemetryEnvelope, MaxIngestBatchSize+1)
	if _, err := store.IngestBatch(ctx, overSized); !errors.Is(err, ErrIngestBatchTooLarge) {
		t.Fatalf("canceled oversized MySQL ingest error = %v, want ErrIngestBatchTooLarge", err)
	}
}

func TestMemoryStoreCanceledContextAndReceivedAtParity(t *testing.T) {
	store := NewMemoryStore(DefaultCatalog())
	old := time.Unix(1, 0).UTC()
	envelope := testEnvelope("evt-received-at", "device-1")
	envelope.ReceivedAt = old
	if _, err := store.IngestBatch(context.Background(), []TelemetryEnvelope{envelope}); err != nil {
		t.Fatalf("initial ingest: %v", err)
	}
	events, _, err := store.QueryEvents(context.Background(), QueryFilter{DeviceID: "device-1", PageSize: 10})
	if err != nil {
		t.Fatalf("query after initial ingest: %v", err)
	}
	if len(events) != 1 || !events[0].ReceivedAt.Equal(old) {
		t.Fatalf("memory store ReceivedAt = %#v, want store to preserve service-stamped value %v", events, old)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := store.IngestBatch(ctx, []TelemetryEnvelope{testEnvelope("evt-canceled", "device-1")}); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled ingest error = %v, want context.Canceled", err)
	}
	events, _, err = store.QueryEvents(context.Background(), QueryFilter{DeviceID: "device-1", PageSize: 10})
	if err != nil {
		t.Fatalf("query after canceled ingest: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("canceled ingest changed store: got %d events, want 1", len(events))
	}
}

func TestMemoryStoreEventIDsRemainExactAndCaseSensitive(t *testing.T) {
	store := NewMemoryStore(DefaultCatalog())
	ids := []string{"evt-a", "EVT-A", "evt-a "}
	records := make([]TelemetryEnvelope, 0, len(ids))
	for _, id := range ids {
		records = append(records, testEnvelope(id, "device-1"))
	}
	acks, err := store.IngestBatch(context.Background(), records)
	if err != nil {
		t.Fatalf("initial ingest: %v", err)
	}
	for i, ack := range acks {
		if ack.Status != StatusAccepted || ack.EventID != ids[i] {
			t.Fatalf("ack[%d] = %#v, want accepted exact ID %q", i, ack, ids[i])
		}
	}
	replay, err := store.IngestBatch(context.Background(), records)
	if err != nil {
		t.Fatalf("replay ingest: %v", err)
	}
	for i, ack := range replay {
		if ack.Status != StatusAlreadySeen || ack.EventID != ids[i] {
			t.Fatalf("replay ack[%d] = %#v, want already_seen exact ID %q", i, ack, ids[i])
		}
	}
}
