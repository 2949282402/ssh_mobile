package telemetry

import (
	"context"
	"fmt"
	"time"
)

func (s *Service) IngestBatch(ctx context.Context, envelopes []TelemetryEnvelope) (results []IngestRecordResult, err error) {
	startedAt := time.Now()
	var metrics *ingestMetrics
	if s != nil {
		s.mu.RLock()
		metrics = s.ingestMetrics
		s.mu.RUnlock()
	}
	defer func() {
		if metrics != nil {
			metrics.record(time.Since(startedAt), err)
		}
	}()

	if len(envelopes) > MaxIngestBatchSize {
		return nil, fmt.Errorf("%w: maximum is %d records", ErrIngestBatchTooLarge, MaxIngestBatchSize)
	}
	if s == nil || s.store == nil {
		return nil, ErrServiceUnavailable
	}
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}

	// Unconditionally stamp server receive time; client-supplied receivedAt is ignored.
	now := time.Now().UTC()
	for i := range envelopes {
		envelopes[i].ReceivedAt = now
	}

	results, err = s.store.IngestBatch(ctx, envelopes)
	if err != nil {
		return nil, err
	}

	// Hot cache update for accepted diagnostics
	settings, err := s.store.GetSettings(ctx)
	if err != nil {
		// Cache is best-effort; a settings read failure must not fail ingestion.
		return results, nil
	}
	cacheEnabled := settings == nil || settings.RedisCacheEnabled
	maxRecords := 1000
	if settings != nil && settings.RedisMaxRecords > 0 {
		maxRecords = settings.RedisMaxRecords
	}

	if cacheEnabled {
		for i, res := range results {
			if res.Status == StatusAccepted && envelopes[i].RecordType == RecordTypeDiagnostic {
				_ = s.redisCache.PushDiagnostic(ctx, envelopes[i], maxRecords)
			}
		}
	}

	return results, nil
}

func (s *Service) QueryOverview(ctx context.Context, filter QueryFilter) (*OverviewMetrics, error) {
	if s.store == nil {
		return nil, ErrServiceUnavailable
	}
	// Inject the service Redis cache into the backing store so the overview can
	// report live Redis pipeline health. Stores that do not support injection
	// (e.g. mocks) simply report Redis as disabled.
	if w, ok := s.store.(interface{ SetRedisCache(RedisCache) }); ok {
		w.SetRedisCache(s.redisCache)
	}
	metrics, err := s.store.QueryOverview(ctx, filter)
	if err != nil {
		return nil, err
	}
	if metrics != nil {
		s.mu.RLock()
		ingestMetrics := s.ingestMetrics
		s.mu.RUnlock()
		metrics.PipelineHealth = pipelineHealthWithIngestMetrics(metrics.PipelineHealth, ingestMetrics)
	}
	return metrics, nil
}
