package telemetry

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
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

func TestNormalizeIngestConfigRejectsNonFiniteRateValuesAfterAliasSelection(t *testing.T) {
	cases := []IngestConfig{
		{RateLimitRefillPerSecond: math.NaN()},
		{RateLimitRefillPerSecond: math.Inf(1)},
		{RateLimitRefillPerSecond: 0, RateLimitRefillPerSec: math.NaN()},
		{RateLimitRefillPerSecond: 0, RateLimitRefillPerSec: math.Inf(-1)},
	}
	for _, input := range cases {
		got := normalizeIngestConfig(input)
		if math.IsNaN(got.RateLimitRefillPerSecond) || math.IsInf(got.RateLimitRefillPerSecond, 0) {
			t.Fatalf("normalizeIngestConfig(%+v) left non-finite refill rate: %v", input, got.RateLimitRefillPerSecond)
		}
		if got.RateLimitRefillPerSecond != DefaultIngestRateLimitRefillPerSec {
			t.Fatalf("normalized refill rate = %v, want safe default %v for %+v", got.RateLimitRefillPerSecond, DefaultIngestRateLimitRefillPerSec, input)
		}
	}
}

func TestWriteIngestRetryErrorUsesFractionalCeilingAndConfiguredBound(t *testing.T) {
	config := DefaultIngestConfig()
	config.RetryAfterSeconds = 2
	handler := NewHandlerWithConfig(nil, config)

	rec := httptest.NewRecorder()
	handler.writeIngestRetryError(rec, ErrIngestOverloaded, 1200*time.Millisecond)
	if got := rec.Header().Get("Retry-After"); got != "2" {
		t.Fatalf("Retry-After for fractional delay = %q, want 2", got)
	}
	rec = httptest.NewRecorder()
	handler.writeIngestRetryError(rec, ErrIngestOverloaded, 60*time.Second)
	if got := rec.Header().Get("Retry-After"); got != "2" {
		t.Fatalf("Retry-After exceeded configured ceiling: got %q, want 2", got)
	}
	rec = httptest.NewRecorder()
	handler.writeIngestRetryError(rec, ErrIngestOverloaded, time.Duration(1<<63-1))
	if got := rec.Header().Get("Retry-After"); got != "2" {
		t.Fatalf("Retry-After overflow escaped configured ceiling: got %q, want 2", got)
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
	var mysqlStore *MySQLStore
	if _, err := mysqlStore.IngestBatch(context.Background(), records); !errors.Is(err, ErrIngestBatchTooLarge) {
		t.Fatalf("mysql oversized batch error = %v, want ErrIngestBatchTooLarge", err)
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
	if len(events) != 1 || events[0].ReceivedAt.Equal(old) {
		t.Fatalf("memory store ReceivedAt = %#v, want current receipt time replacing %v", events, old)
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

func TestMySQLIngestOrdersEventIDsForDeterministicLockAcquisition(t *testing.T) {
	input := []TelemetryEnvelope{testEnvelope("evt-z", "device-1"), testEnvelope("EVT-A", "device-1"), testEnvelope("evt-a", "device-1")}
	ordered := orderedIngestEnvelopes(input)
	got := make([]string, 0, len(ordered))
	for _, envelope := range ordered {
		got = append(got, envelope.EventID)
	}
	want := []string{"EVT-A", "evt-a", "evt-z"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ordered event IDs = %#v, want %#v", got, want)
	}
	if input[0].EventID != "evt-z" {
		t.Fatalf("ordering helper mutated input: %#v", input)
	}
}

func TestMySQLMultirowInsertArgumentsPreserveJSONAndSQLNulls(t *testing.T) {
	plain := testEnvelope("evt-null-json", "device-1")
	plain.Properties = nil
	plain.Error = nil
	withJSON := testEnvelope("evt-json", "device-1")
	withJSON.Properties = map[string]any{"session_type": "interactive"}
	withJSON.Error = &TelemetryError{
		ErrorCode:       "SSH_AUTH_FAILED",
		Category:        "ssh",
		TerminalFailure: true,
		Message:         "redacted test failure",
	}
	args, err := telemetryEventInsertArgs([]TelemetryEnvelope{plain, withJSON}, time.Unix(10, 0).UTC())
	if err != nil {
		t.Fatalf("build multi-row insert args: %v", err)
	}
	if len(args) != 36 {
		t.Fatalf("multi-row arg count = %d, want 36", len(args))
	}
	if args[15] != nil || args[16] != nil || args[11] != nil {
		t.Fatalf("nil JSON/error fields were not SQL NULLs: props=%#v error=%#v code=%#v", args[15], args[16], args[11])
	}
	if got, ok := args[33].([]byte); !ok || string(got) != `{"session_type":"interactive"}` {
		t.Fatalf("properties JSON arg = %#v, want canonical JSON bytes", args[33])
	}
	if got, ok := args[34].([]byte); !ok || !strings.Contains(string(got), `"errorCode":"SSH_AUTH_FAILED"`) {
		t.Fatalf("error JSON arg = %#v, want encoded error", args[34])
	}
	if got := mysqlValueTuples(2, 18); strings.Count(got, "(") != 2 || strings.Count(got, "?") != 36 {
		t.Fatalf("multi-row SQL tuple shape = %q", got)
	}
}

func TestMySQLIngestRetriesDeadlockAndLockWaitErrors(t *testing.T) {
	cases := []error{
		&mysql.MySQLError{Number: 1213, Message: "Deadlock found when trying to get lock"},
		&mysql.MySQLError{Number: 1205, Message: "Lock wait timeout exceeded"},
		errors.New("Error 1213: deadlock found when trying to get lock"),
		errors.New("Error 1205: lock wait timeout exceeded"),
	}
	for _, err := range cases {
		if !isRetryableIngestConflict(err) {
			t.Fatalf("isRetryableIngestConflict(%v) = false, want true", err)
		}
	}
	if isRetryableIngestConflict(errors.New("validation failed")) {
		t.Fatal("validation error was classified as retryable")
	}
}
