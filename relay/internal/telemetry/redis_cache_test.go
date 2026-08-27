package telemetry

import (
	"context"
	"errors"
	"testing"
	"time"
)

type mockFailingRedisCache struct {
	shouldFail bool
}

func (m *mockFailingRedisCache) PushDiagnostic(ctx context.Context, env TelemetryEnvelope, maxRecords int) error {
	if m.shouldFail {
		return errors.New("redis connection refused")
	}
	return nil
}

func (m *mockFailingRedisCache) GetRecentDiagnostics(ctx context.Context, limit int) ([]TelemetryEnvelope, error) {
	if m.shouldFail {
		return nil, errors.New("redis connection refused")
	}
	return nil, nil
}

func TestRedisCacheDegradation(t *testing.T) {
	ctx := context.Background()
	catalog := DefaultCatalog()
	store := NewMemoryStore(catalog)
	failingCache := &mockFailingRedisCache{shouldFail: true}

	service := NewService(store, catalog, failingCache)

	now := time.Now().UTC()
	records := []TelemetryEnvelope{
		{
			EventID:      "diag-001",
			RecordType:   RecordTypeDiagnostic,
			EventName:    "ssh.session.failed",
			EventVersion: 1,
			DeviceID:     "dev-1",
			SessionID:    "sess-1",
			TraceID:      "trace-1",
			OccurredAt:   now,
			Feature:      "ssh",
			Severity:     SeverityError,
			AppVersion:   "1.0.0",
			BuildNumber:  "100",
			Platform:     "android",
			Error: &TelemetryError{
				ErrorCode:       "SSH_TIMEOUT",
				Category:        "ssh",
				TerminalFailure: true,
			},
		},
	}

	// 1. Ingesting should SUCCEED even when Redis fails
	results, err := service.IngestBatch(ctx, records)
	if err != nil {
		t.Fatalf("expected IngestBatch to succeed despite redis failure, got error: %v", err)
	}
	if len(results) != 1 || results[0].Status != StatusAccepted {
		t.Fatalf("expected record to be accepted, got results: %v", results)
	}

	// 2. Querying diagnostics should fall back to MySQL store when Redis fails
	diagLogs, total, source, err := service.QueryDiagnostics(ctx, QueryFilter{Page: 1, PageSize: 50})
	if err != nil {
		t.Fatalf("expected QueryDiagnostics fallback to succeed, got error: %v", err)
	}
	if source != "mysql" {
		t.Errorf("expected source 'mysql' on redis failure, got %s", source)
	}
	if total != 1 || len(diagLogs) != 1 {
		t.Errorf("expected 1 diagnostic log returned from store fallback, got total=%d len=%d", total, len(diagLogs))
	}
}
