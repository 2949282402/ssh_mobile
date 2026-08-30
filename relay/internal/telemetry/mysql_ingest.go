package telemetry

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/go-sql-driver/mysql"
)

const (
	maxIngestTransactionAttempts = 3
	// A short, deterministic backoff lets a deadlock victim yield to the
	// transaction that won the conflicting lock without creating an unbounded
	// request wait. The attempt count remains the hard upper bound.
	baseIngestRetryDelay = 5 * time.Millisecond
)

func isDuplicateKeyError(err error) bool {
	if err == nil {
		return false
	}
	var mysqlErr *mysql.MySQLError
	if errors.As(err, &mysqlErr) && mysqlErr.Number == 1062 {
		return true
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "1062") || strings.Contains(msg, "duplicate entry") || strings.Contains(msg, "unique constraint")
}

var errConcurrentIngestDuplicate = errors.New("concurrent telemetry ingest duplicate")
var errRetryableIngestConflict = errors.New("retryable telemetry ingest transaction conflict")

// isRetryableIngestConflict recognizes duplicate races and the two InnoDB
// transaction conflicts that are safe to retry as a whole batch.
func isRetryableIngestConflict(err error) bool {
	if err == nil {
		return false
	}
	var mysqlErr *mysql.MySQLError
	if errors.As(err, &mysqlErr) {
		switch mysqlErr.Number {
		case 1062, 1205, 1213:
			return true
		}
	}
	msg := strings.ToLower(err.Error())
	return isDuplicateKeyError(err) ||
		strings.Contains(msg, "deadlock found") ||
		strings.Contains(msg, "lock wait timeout") ||
		strings.Contains(msg, "try restarting transaction") ||
		strings.Contains(msg, "error 1205") ||
		strings.Contains(msg, "error 1213")
}

func retryableIngestConflict(err error) error {
	if !isRetryableIngestConflict(err) {
		return err
	}
	if isDuplicateKeyError(err) {
		return fmt.Errorf("%w: %w: %v", errRetryableIngestConflict, errConcurrentIngestDuplicate, err)
	}
	return fmt.Errorf("%w: %v", errRetryableIngestConflict, err)
}

func orderedIngestEnvelopes(envelopes []TelemetryEnvelope) []TelemetryEnvelope {
	ordered := append([]TelemetryEnvelope(nil), envelopes...)
	sort.SliceStable(ordered, func(i, j int) bool {
		return ordered[i].EventID < ordered[j].EventID
	})
	return ordered
}

func waitForIngestRetry(ctx context.Context, attempt int) error {
	delay := baseIngestRetryDelay * time.Duration(attempt+1)
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func (s *MySQLStore) IngestBatch(ctx context.Context, envelopes []TelemetryEnvelope) ([]IngestRecordResult, error) {
	if len(envelopes) > MaxIngestBatchSize {
		return nil, fmt.Errorf("%w: maximum is %d records", ErrIngestBatchTooLarge, MaxIngestBatchSize)
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if s == nil || s.db == nil || s.catalog == nil {
		return nil, fmt.Errorf("%w: mysql telemetry store is unavailable", ErrServiceUnavailable)
	}
	now := time.Now().UTC()
	results := make([]IngestRecordResult, len(envelopes))
	valid := make([]TelemetryEnvelope, 0, len(envelopes))
	validIndexes := make([]int, 0, len(envelopes))
	seenInput := make(map[string]struct{}, len(envelopes))

	for i, env := range envelopes {
		if err := s.catalog.ValidateEnvelopeAt(&env, now); err != nil {
			results[i] = IngestRecordResult{
				EventID: env.EventID,
				Status:  StatusRejected,
				Reason:  err.Error(),
			}
			continue
		}

		// Service.IngestBatch stamps ReceivedAt before reaching the store. Keep
		// that value unchanged; the zero-value fallback is only for legacy direct
		// Store callers that bypass the service boundary.
		if env.ReceivedAt.IsZero() {
			env.ReceivedAt = now
		}
		if _, duplicate := seenInput[env.EventID]; duplicate {
			results[i] = IngestRecordResult{
				EventID: env.EventID,
				Status:  StatusAlreadySeen,
			}
			continue
		}
		seenInput[env.EventID] = struct{}{}
		valid = append(valid, env)
		validIndexes = append(validIndexes, i)
	}

	if len(valid) == 0 {
		return results, nil
	}

	// A concurrent request can win the receipt race after our locking read in
	// deployments that use READ COMMITTED or an older schema. Retry the whole
	// bounded batch once the winner commits; the next locking read then reports
	// the winner as already_seen without losing unrelated records.
	for attempt := 0; attempt < maxIngestTransactionAttempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		statuses, err := s.ingestValidBatch(ctx, valid, now)
		if errors.Is(err, errRetryableIngestConflict) {
			if attempt+1 < maxIngestTransactionAttempts {
				if waitErr := waitForIngestRetry(ctx, attempt); waitErr != nil {
					return nil, waitErr
				}
				continue
			}
			return nil, fmt.Errorf("ingest batch retry exhausted after %d attempts: %w", maxIngestTransactionAttempts, err)
		}
		if errors.Is(err, errConcurrentIngestDuplicate) {
			continue
		}
		if err != nil {
			return nil, err
		}
		for i := range valid {
			results[validIndexes[i]] = IngestRecordResult{
				EventID: valid[i].EventID,
				Status:  statuses[valid[i].EventID],
			}
		}
		return results, nil
	}
	return nil, fmt.Errorf("ingest batch retry exhausted after %d attempts: %w", maxIngestTransactionAttempts, errConcurrentIngestDuplicate)
}

func (s *MySQLStore) ingestValidBatch(ctx context.Context, envelopes []TelemetryEnvelope, now time.Time) (map[string]IngestStatus, error) {
	envelopes = orderedIngestEnvelopes(envelopes)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, retryableIngestConflict(fmt.Errorf("begin ingest tx: %w", err))
	}
	rollback := func() {
		_ = tx.Rollback()
	}
	committed := false
	defer func() {
		if !committed {
			rollback()
		}
	}()

	placeholders := mysqlPlaceholders(len(envelopes))
	rows, err := tx.QueryContext(ctx,
		"SELECT event_id FROM telemetry_ingest_receipts WHERE event_id IN ("+placeholders+") ORDER BY event_id FOR UPDATE",
		telemetryEventIDs(envelopes)...,
	)
	if err != nil {
		rollback()
		return nil, retryableIngestConflict(fmt.Errorf("query receipts: %w", err))
	}
	existing := make(map[string]struct{}, len(envelopes))
	for rows.Next() {
		var eventID string
		if err := rows.Scan(&eventID); err != nil {
			_ = rows.Close()
			rollback()
			return nil, retryableIngestConflict(fmt.Errorf("scan receipt: %w", err))
		}
		existing[eventID] = struct{}{}
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		rollback()
		return nil, retryableIngestConflict(fmt.Errorf("iterate receipts: %w", err))
	}
	if err := rows.Close(); err != nil {
		rollback()
		return nil, retryableIngestConflict(fmt.Errorf("close receipts: %w", err))
	}

	statuses := make(map[string]IngestStatus, len(envelopes))
	newEnvelopes := make([]TelemetryEnvelope, 0, len(envelopes))
	for _, env := range envelopes {
		if _, ok := existing[env.EventID]; ok {
			statuses[env.EventID] = StatusAlreadySeen
			continue
		}
		newEnvelopes = append(newEnvelopes, env)
	}
	if len(newEnvelopes) == 0 {
		if err := tx.Commit(); err != nil {
			return nil, retryableIngestConflict(fmt.Errorf("commit receipt lookup: %w", err))
		}
		committed = true
		return statuses, nil
	}

	eventArgs, err := telemetryEventInsertArgs(newEnvelopes, now)
	if err != nil {
		rollback()
		return nil, err
	}
	eventSQL := `INSERT INTO telemetry_events (
		event_id, record_type, event_name, event_version, device_id, session_id,
		trace_id, occurred_at, received_at, feature, severity, error_code,
		app_version, build_number, platform, release_channel, properties_json,
		error_json, created_at
	) VALUES ` + mysqlValueTuples(len(newEnvelopes), 19)
	if _, err := tx.ExecContext(ctx, eventSQL, eventArgs...); err != nil {
		rollback()
		if isRetryableIngestConflict(err) {
			return nil, retryableIngestConflict(err)
		}
		return nil, fmt.Errorf("insert raw events: %w", err)
	}

	receiptArgs := make([]any, 0, len(newEnvelopes)*3)
	for _, env := range newEnvelopes {
		receiptArgs = append(receiptArgs, env.EventID, env.DeviceID, env.ReceivedAt)
	}
	receiptSQL := `INSERT INTO telemetry_ingest_receipts (event_id, device_id, received_at) VALUES ` + mysqlValueTuples(len(newEnvelopes), 3)
	if _, err := tx.ExecContext(ctx, receiptSQL, receiptArgs...); err != nil {
		rollback()
		if isRetryableIngestConflict(err) {
			return nil, retryableIngestConflict(err)
		}
		return nil, fmt.Errorf("insert receipts: %w", err)
	}

	if err := tx.Commit(); err != nil {
		if isRetryableIngestConflict(err) {
			return nil, retryableIngestConflict(err)
		}
		return nil, fmt.Errorf("commit ingest tx: %w", err)
	}
	committed = true
	for _, env := range newEnvelopes {
		statuses[env.EventID] = StatusAccepted
	}
	return statuses, nil
}

func telemetryEventIDs(envelopes []TelemetryEnvelope) []any {
	args := make([]any, len(envelopes))
	for i := range envelopes {
		args[i] = envelopes[i].EventID
	}
	return args
}

func telemetryEventInsertArgs(envelopes []TelemetryEnvelope, now time.Time) ([]any, error) {
	args := make([]any, 0, len(envelopes)*19)
	for _, env := range envelopes {
		var propsValue any
		if env.Properties != nil {
			encoded, err := json.Marshal(env.Properties)
			if err != nil {
				return nil, fmt.Errorf("marshal properties for %q: %w", env.EventID, err)
			}
			propsValue = encoded
		}
		var errValue any
		var errorCode any
		if env.Error != nil {
			encoded, err := json.Marshal(env.Error)
			if err != nil {
				return nil, fmt.Errorf("marshal error for %q: %w", env.EventID, err)
			}
			errValue = encoded
			errorCode = env.Error.ErrorCode
		}
		var releaseChannel any
		if env.ReleaseChannel != "" {
			releaseChannel = env.ReleaseChannel
		}
		args = append(args,
			env.EventID, string(env.RecordType), env.EventName, env.EventVersion, env.DeviceID, env.SessionID,
			env.TraceID, env.OccurredAt, env.ReceivedAt, env.Feature, string(env.Severity), errorCode,
			env.AppVersion, env.BuildNumber, env.Platform, releaseChannel, propsValue, errValue, now,
		)
	}
	return args, nil
}

func mysqlPlaceholders(count int) string {
	placeholders := make([]string, count)
	for i := range placeholders {
		placeholders[i] = "?"
	}
	return strings.Join(placeholders, ", ")
}

func mysqlValueTuples(rows, columns int) string {
	tuples := make([]string, rows)
	values := strings.TrimSuffix(strings.Repeat("?, ", columns), ", ")
	for i := range tuples {
		tuples[i] = "(" + values + ")"
	}
	return strings.Join(tuples, ", ")
}
