package telemetry_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

type retentionWorkerStore struct {
	Store
	mu       sync.Mutex
	results  []retentionWorkerResult
	called   chan struct{}
	settings TelemetrySettings
}

type retentionWorkerResult struct {
	count int
	err   error
}

func (s *retentionWorkerStore) GetSettings(context.Context) (*TelemetrySettings, error) {
	settings := s.settings
	return &settings, nil
}

func (s *retentionWorkerStore) PurgeRetention(context.Context, time.Time, int, int) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := retentionWorkerResult{}
	if len(s.results) > 0 {
		result = s.results[0]
		s.results = s.results[1:]
	}
	select {
	case s.called <- struct{}{}:
	default:
	}
	return result.count, result.err
}

func TestRetentionWorkerUsesSafeDefaultInterval(t *testing.T) {
	store := NewMemoryStore(DefaultCatalog())
	worker := NewRetentionWorker(NewService(store, DefaultCatalog(), &NoopRedisCache{}), 0)
	if worker == nil {
		t.Fatal("NewRetentionWorker returned nil for a non-positive interval")
	}
}

func TestRetentionWorkerRunsErrorAndSuccessfulPurgeCycles(t *testing.T) {
	base := NewMemoryStore(DefaultCatalog())
	store := &retentionWorkerStore{
		Store: base,
		settings: TelemetrySettings{
			RetentionRowsEnabled: true,
			RetentionMaxRows:     1,
		},
		results: []retentionWorkerResult{
			{err: errors.New("retention backend unavailable")},
			{count: 1},
		},
		called: make(chan struct{}, 4),
	}
	service := NewService(store, DefaultCatalog(), &NoopRedisCache{})
	worker := NewRetentionWorker(service, time.Millisecond)
	worker.Start()
	defer worker.Stop()

	for i := 0; i < 2; i++ {
		select {
		case <-store.called:
		case <-time.After(time.Second):
			t.Fatalf("retention worker did not complete purge cycle %d", i+1)
		}
	}
}
