package telemetry

import (
	"context"
	"time"
)

func (s *Service) QueryEvents(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, error) {
	if s.store == nil {
		return nil, 0, ErrServiceUnavailable
	}
	return s.store.QueryEvents(ctx, filter)
}

// QueryDiagnostics always reads the authoritative durable store. Redis is an
// ingest acceleration buffer and has no durable retention watermark, so stale
// entries must never define diagnostic page contents or totals.
func (s *Service) QueryDiagnostics(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, string, error) {
	if s.store == nil {
		return nil, 0, "", ErrServiceUnavailable
	}
	records, total, err := s.store.QueryDiagnostics(ctx, filter)
	if err != nil {
		return nil, 0, "mysql", err
	}
	return records, total, "mysql", nil
}

func (s *Service) GetPolicy(ctx context.Context) (*TelemetryUploadPolicy, error) {
	settings, err := s.GetSettings(ctx)
	if err != nil {
		return nil, err
	}
	return &settings.Policy, nil
}

func (s *Service) GetSettings(ctx context.Context) (*TelemetrySettings, error) {
	if s.store == nil {
		return nil, ErrServiceUnavailable
	}
	return s.store.GetSettings(ctx)
}

func (s *Service) UpdateSettings(ctx context.Context, settings TelemetrySettings) error {
	if s.store == nil {
		return ErrServiceUnavailable
	}
	if err := ValidatePolicyVersion(settings.Policy.PolicyVersion); err != nil {
		return err
	}
	return s.store.SaveSettings(ctx, settings)
}

// PurgeRetention executes one retention cycle.
func (s *Service) PurgeRetention(ctx context.Context) (int, error) {
	if s.store == nil {
		return 0, ErrServiceUnavailable
	}
	settings, err := s.store.GetSettings(ctx)
	if err != nil {
		return 0, err
	}

	var cutoff time.Time
	if settings.RetentionTimeEnabled && settings.RetentionDays > 0 {
		cutoff = time.Now().UTC().Add(-time.Duration(settings.RetentionDays) * 24 * time.Hour)
	}
	maxRows := 0
	if settings.RetentionRowsEnabled && settings.RetentionMaxRows > 0 {
		maxRows = settings.RetentionMaxRows
	}
	if cutoff.IsZero() && maxRows == 0 {
		return 0, nil
	}
	return s.store.PurgeRetention(ctx, cutoff, maxRows, 500)
}
