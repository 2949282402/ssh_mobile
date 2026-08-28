package telemetry_test

import (
	"context"
	"os"
	"strconv"
	"sync"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestIngestConfigFromEnvironment(t *testing.T) {
	t.Setenv("TELEMETRY_MAX_BODY_BYTES", "2048")
	t.Setenv("TELEMETRY_MAX_BATCH_SIZE", "7")
	t.Setenv("TELEMETRY_MAX_CONCURRENT_WRITERS", "8")
	t.Setenv("TELEMETRY_RATE_LIMIT_CAPACITY", "12")
	t.Setenv("TELEMETRY_RATE_LIMIT_REFILL_PER_SECOND", "2.5")
	t.Setenv("TELEMETRY_RATE_LIMIT_MAX_DEVICES", "32")
	t.Setenv("TELEMETRY_RATE_LIMIT_DEVICE_TTL", "30s")
	t.Setenv("TELEMETRY_RETRY_AFTER_SECONDS", "3")

	config, err := IngestConfigFromEnvironment()
	if err != nil {
		t.Fatalf("read ingest config: %v", err)
	}
	if config.MaxBodyBytes != 2048 || config.MaxBatchSize != 7 || config.MaxConcurrentWriters != 8 ||
		config.RateLimitCapacity != 12 || config.RateLimitRefillPerSecond != 2.5 ||
		config.RateLimitMaxDevices != 32 || config.RateLimitDeviceTTL != 30*time.Second || config.RetryAfterSeconds != 3 {
		t.Fatalf("unexpected environment config: %+v", config)
	}

	t.Setenv("TELEMETRY_MAX_BATCH_SIZE", "invalid")
	if _, err := IngestConfigFromEnvironment(); err == nil {
		t.Fatal("invalid environment config should fail closed")
	}
}

func TestIngestConfigRejectsNonFiniteRateValues(t *testing.T) {
	for _, value := range []string{"NaN", "+Inf", "-Inf"} {
		t.Run(value, func(t *testing.T) {
			t.Setenv("TELEMETRY_RATE_LIMIT_REFILL_PER_SECOND", value)
			if _, err := IngestConfigFromEnvironment(); err == nil {
				t.Fatal("non-finite refill rate should fail closed")
			}
		})
	}
}

func TestMySQLStoreConcurrentDuplicateEventIDs(t *testing.T) {
	store := openTelemetryMySQLOrSkip(t)
	defer store.Close()
	unique := strconv.FormatInt(time.Now().UnixNano(), 10)
	eventID := "evt-concurrent-mysql-duplicate-" + unique
	envelope := testEnvelope(eventID, "dev-concurrent-mysql-"+unique)
	const calls = 8
	statuses := make(chan IngestStatus, calls)
	var wait sync.WaitGroup
	for i := 0; i < calls; i++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			got, err := store.IngestBatch(context.Background(), []TelemetryEnvelope{envelope})
			if err != nil {
				t.Errorf("concurrent MySQL ingest: %v", err)
				return
			}
			statuses <- got[0].Status
		}()
	}
	wait.Wait()
	close(statuses)

	var accepted, alreadySeen int
	for status := range statuses {
		switch status {
		case StatusAccepted:
			accepted++
		case StatusAlreadySeen:
			alreadySeen++
		default:
			t.Fatalf("unexpected MySQL concurrent status %q", status)
		}
	}
	if accepted != 1 || alreadySeen != calls-1 {
		t.Fatalf("MySQL concurrent statuses accepted=%d alreadySeen=%d, want 1/%d", accepted, alreadySeen, calls-1)
	}
}

func TestMySQLStoreConcurrentReverseOverlapBatches(t *testing.T) {
	store := openTelemetryMySQLOrSkip(t)
	defer store.Close()
	unique := strconv.FormatInt(time.Now().UnixNano(), 10)
	deviceID := "dev-concurrent-mysql-overlap-" + unique
	ids := []string{"evt-reverse-overlap-a-" + unique, "evt-reverse-overlap-b-" + unique}
	forward := []TelemetryEnvelope{testEnvelope(ids[0], deviceID), testEnvelope(ids[1], deviceID)}
	reverse := []TelemetryEnvelope{testEnvelope(ids[1], deviceID), testEnvelope(ids[0], deviceID)}
	type batchResult struct {
		acks []IngestRecordResult
		err  error
	}
	results := make(chan batchResult, 2)
	go func() {
		acks, err := store.IngestBatch(context.Background(), forward)
		results <- batchResult{acks: acks, err: err}
	}()
	go func() {
		acks, err := store.IngestBatch(context.Background(), reverse)
		results <- batchResult{acks: acks, err: err}
	}()

	accepted := make(map[string]int)
	alreadySeen := make(map[string]int)
	for i := 0; i < 2; i++ {
		result := <-results
		if result.err != nil {
			t.Fatalf("reverse-overlap MySQL ingest: %v", result.err)
		}
		for _, ack := range result.acks {
			switch ack.Status {
			case StatusAccepted:
				accepted[ack.EventID]++
			case StatusAlreadySeen:
				alreadySeen[ack.EventID]++
			default:
				t.Fatalf("unexpected reverse-overlap status for %q: %q", ack.EventID, ack.Status)
			}
		}
	}
	for _, eventID := range ids {
		if accepted[eventID] != 1 || alreadySeen[eventID] != 1 {
			t.Fatalf("reverse-overlap event %q accepted=%d alreadySeen=%d, want 1/1", eventID, accepted[eventID], alreadySeen[eventID])
		}
	}
}

func TestMySQLStoreEventIDsPreserveCaseAndTrailingBytes(t *testing.T) {
	store := openTelemetryMySQLOrSkip(t)
	defer store.Close()
	unique := strconv.FormatInt(time.Now().UnixNano(), 10)
	deviceID := "dev-mysql-event-id-bytes-" + unique
	ids := []string{"evt-a-" + unique, "EVT-A-" + unique, "evt-a- " + unique}
	records := make([]TelemetryEnvelope, 0, len(ids))
	for _, eventID := range ids {
		records = append(records, testEnvelope(eventID, deviceID))
	}
	acks, err := store.IngestBatch(context.Background(), records)
	if err != nil {
		t.Fatalf("exact event-id ingest: %v", err)
	}
	for i, ack := range acks {
		if ack.EventID != ids[i] || ack.Status != StatusAccepted {
			t.Fatalf("exact event-id ack[%d] = %#v, want accepted %q", i, ack, ids[i])
		}
	}
	replay, err := store.IngestBatch(context.Background(), records)
	if err != nil {
		t.Fatalf("exact event-id replay: %v", err)
	}
	for i, ack := range replay {
		if ack.EventID != ids[i] || ack.Status != StatusAlreadySeen {
			t.Fatalf("exact event-id replay ack[%d] = %#v, want already_seen %q", i, ack, ids[i])
		}
	}
}

func openTelemetryMySQLOrSkip(t *testing.T) *MySQLStore {
	t.Helper()
	dsn := os.Getenv("TELEMETRY_TEST_MYSQL_DSN")
	if dsn == "" {
		dsn = os.Getenv("TELEMETRY_MYSQL_DSN")
	}
	if dsn == "" {
		t.Skip("TELEMETRY_TEST_MYSQL_DSN or TELEMETRY_MYSQL_DSN not set; skipping MySQL integration test")
	}
	store, err := NewMySQLStoreFromDSN(dsn, DefaultCatalog())
	if err != nil {
		t.Fatalf("open telemetry MySQL store: %v", err)
	}
	return store
}
