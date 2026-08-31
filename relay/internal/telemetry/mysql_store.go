// Analytics MySQL store implementation for Telemetry.

package telemetry

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

type MySQLStore struct {
	db         *sql.DB
	catalog    *Catalog
	redisCache RedisCache
}

// SetRedisCache wires a live Redis cache used for pipeline health probing. It
// is best-effort: a nil cache simply reports Redis as disabled.
func (s *MySQLStore) SetRedisCache(cache RedisCache) {
	s.redisCache = cache
}

func NewMySQLStore(db *sql.DB, catalog *Catalog) *MySQLStore {
	if catalog == nil {
		catalog = DefaultCatalog()
	}
	return &MySQLStore{
		db:      db,
		catalog: catalog,
	}
}

// NewMySQLStoreFromDSN opens a MySQL database connection, verifies ping, and ensures schemas exist.
func NewMySQLStoreFromDSN(dsn string, catalog *Catalog) (*MySQLStore, error) {
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, fmt.Errorf("open mysql error: %w", err)
	}
	db.SetMaxOpenConns(6)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping mysql error: %w", err)
	}

	store := NewMySQLStore(db, catalog)
	if err := store.EnsureSchema(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ensure schema error: %w", err)
	}
	return store, nil
}

func (s *MySQLStore) QueryEvents(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, error) {
	var whereClauses []string
	var args []any

	if filter.RecordType != "" {
		whereClauses = append(whereClauses, "record_type = ?")
		args = append(args, string(filter.RecordType))
	}
	if filter.DeviceID != "" {
		whereClauses = append(whereClauses, "device_id = ?")
		args = append(args, filter.DeviceID)
	}
	if filter.TraceID != "" {
		whereClauses = append(whereClauses, "trace_id = ?")
		args = append(args, filter.TraceID)
	}
	if filter.EventName != "" {
		whereClauses = append(whereClauses, "event_name = ?")
		args = append(args, filter.EventName)
	}
	if filter.Feature != "" {
		whereClauses = append(whereClauses, "feature = ?")
		args = append(args, filter.Feature)
	}
	if filter.Severity != "" {
		whereClauses = append(whereClauses, "severity = ?")
		args = append(args, string(filter.Severity))
	}
	if filter.ErrorCode != "" {
		whereClauses = append(whereClauses, "error_code = ?")
		args = append(args, filter.ErrorCode)
	}
	if filter.AppVersion != "" {
		whereClauses = append(whereClauses, "app_version = ?")
		args = append(args, filter.AppVersion)
	}
	if filter.Platform != "" {
		whereClauses = append(whereClauses, "platform = ?")
		args = append(args, filter.Platform)
	}
	if filter.ReleaseChannel != "" {
		whereClauses = append(whereClauses, "release_channel = ?")
		args = append(args, filter.ReleaseChannel)
	}
	if !filter.StartTime.IsZero() {
		whereClauses = append(whereClauses, "received_at >= ?")
		args = append(args, filter.StartTime)
	}
	if !filter.EndTime.IsZero() {
		whereClauses = append(whereClauses, "received_at <= ?")
		args = append(args, filter.EndTime)
	}

	whereSQL := ""
	if len(whereClauses) > 0 {
		whereSQL = " WHERE " + strings.Join(whereClauses, " AND ")
	}

	// Count total
	var total int
	countQuery := "SELECT COUNT(*) FROM telemetry_events" + whereSQL
	if err := s.db.QueryRowContext(ctx, countQuery, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("count events query: %w", err)
	}

	page := filter.Page
	if page < 1 {
		page = 1
	}
	pageSize := filter.PageSize
	if pageSize < 1 {
		pageSize = 50
	}
	offset := (page - 1) * pageSize

	query := `
		SELECT event_id, record_type, event_name, event_version, device_id, session_id,
		       trace_id, occurred_at, received_at, feature, severity, app_version,
		       build_number, platform, release_channel, properties_json, error_json
		FROM telemetry_events
	` + whereSQL + " ORDER BY received_at DESC, event_id DESC LIMIT ? OFFSET ?"

	selectArgs := append(args, pageSize, offset)
	rows, err := s.db.QueryContext(ctx, query, selectArgs...)
	if err != nil {
		return nil, 0, fmt.Errorf("select events: %w", err)
	}
	defer rows.Close()

	var records []TelemetryEnvelope
	for rows.Next() {
		var env TelemetryEnvelope
		var recType, sev string
		var releaseChannel, propsRaw, errRaw sql.NullString

		err := rows.Scan(
			&env.EventID, &recType, &env.EventName, &env.EventVersion, &env.DeviceID, &env.SessionID,
			&env.TraceID, &env.OccurredAt, &env.ReceivedAt, &env.Feature, &sev, &env.AppVersion,
			&env.BuildNumber, &env.Platform, &releaseChannel, &propsRaw, &errRaw,
		)
		if err != nil {
			return nil, 0, fmt.Errorf("scan event row: %w", err)
		}

		env.RecordType = RecordType(recType)
		env.Severity = Severity(sev)
		if releaseChannel.Valid {
			env.ReleaseChannel = releaseChannel.String
		}

		if propsRaw.Valid && len(propsRaw.String) > 0 {
			var p map[string]any
			if err := json.Unmarshal([]byte(propsRaw.String), &p); err == nil {
				env.Properties = p
			}
		}

		if errRaw.Valid && len(errRaw.String) > 0 {
			var e TelemetryError
			if err := json.Unmarshal([]byte(errRaw.String), &e); err == nil {
				env.Error = &e
			}
		}

		records = append(records, env)
	}

	return records, total, nil
}

func (s *MySQLStore) QueryDiagnostics(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, error) {
	filter.RecordType = RecordTypeDiagnostic
	return s.QueryEvents(ctx, filter)
}

func (s *MySQLStore) GetSettings(ctx context.Context) (*TelemetrySettings, error) {
	var rawJSON string
	var updatedAt time.Time
	err := s.db.QueryRowContext(ctx, "SELECT settings_json, updated_at FROM telemetry_settings WHERE id = 1").Scan(&rawJSON, &updatedAt)
	if err == sql.ErrNoRows {
		def := DefaultSettings()
		return &def, nil
	} else if err != nil {
		return nil, fmt.Errorf("get telemetry settings: %w", err)
	}

	var settings TelemetrySettings
	if err := json.Unmarshal([]byte(rawJSON), &settings); err != nil {
		return nil, fmt.Errorf("unmarshal settings: %w", err)
	}
	settings.UpdatedAt = updatedAt
	return &settings, nil
}

func (s *MySQLStore) SaveSettings(ctx context.Context, settings TelemetrySettings) error {
	if err := ValidatePolicyVersion(settings.Policy.PolicyVersion); err != nil {
		return err
	}
	SanitizeSettings(&settings)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin telemetry settings update: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var currentJSON string
	err = tx.QueryRowContext(ctx, "SELECT settings_json FROM telemetry_settings WHERE id = 1 FOR UPDATE").Scan(&currentJSON)
	if err == nil {
		var current TelemetrySettings
		if unmarshalErr := json.Unmarshal([]byte(currentJSON), &current); unmarshalErr != nil {
			return fmt.Errorf("unmarshal current telemetry settings: %w", unmarshalErr)
		}
		SanitizeSettings(&current)
		if settings.Policy.PolicyVersion <= current.Policy.PolicyVersion {
			return fmt.Errorf("%w: current=%d incoming=%d", ErrPolicyVersionConflict, current.Policy.PolicyVersion, settings.Policy.PolicyVersion)
		}
	} else if err != sql.ErrNoRows {
		return fmt.Errorf("read current telemetry settings: %w", err)
	}

	now := time.Now().UTC()
	settings.UpdatedAt = now
	data, err := json.Marshal(settings)
	if err != nil {
		return fmt.Errorf("marshal settings: %w", err)
	}

	_, err = tx.ExecContext(ctx, `
		INSERT INTO telemetry_settings (id, settings_json, updated_at)
		VALUES (1, ?, ?)
		ON DUPLICATE KEY UPDATE settings_json = VALUES(settings_json), updated_at = VALUES(updated_at)
	`, string(data), now)
	if err != nil {
		return fmt.Errorf("persist telemetry settings: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit telemetry settings: %w", err)
	}
	return nil
}

func (s *MySQLStore) PurgeRetention(ctx context.Context, cutoff time.Time, maxRows int, batchSize int) (int, error) {
	if batchSize <= 0 {
		batchSize = 500
	}
	totalDeleted := 0

	// 1. Time based purge
	if !cutoff.IsZero() {
		for {
			res, err := s.db.ExecContext(ctx, `
				DELETE FROM telemetry_events
				WHERE received_at < ?
				ORDER BY received_at ASC, event_id ASC
				LIMIT ?
			`, cutoff, batchSize)
			if err != nil {
				return totalDeleted, fmt.Errorf("purge by time error: %w", err)
			}
			rowsAffected, _ := res.RowsAffected()
			totalDeleted += int(rowsAffected)
			if rowsAffected < int64(batchSize) {
				break
			}
		}
	}

	// 2. Max rows purge
	if maxRows > 0 {
		var currentCount int
		if err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM telemetry_events").Scan(&currentCount); err != nil {
			return totalDeleted, fmt.Errorf("count for maxRows purge: %w", err)
		}

		for currentCount > maxRows {
			excess := currentCount - maxRows
			toDelete := batchSize
			if excess < toDelete {
				toDelete = excess
			}

			res, err := s.db.ExecContext(ctx, `
				DELETE FROM telemetry_events
				ORDER BY received_at ASC, event_id ASC
				LIMIT ?
			`, toDelete)
			if err != nil {
				return totalDeleted, fmt.Errorf("purge by maxRows error: %w", err)
			}
			rowsAffected, _ := res.RowsAffected()
			totalDeleted += int(rowsAffected)
			currentCount -= int(rowsAffected)
			if rowsAffected == 0 {
				break
			}
		}
	}

	return totalDeleted, nil
}

func (s *MySQLStore) RegisterDeviceCredential(ctx context.Context, deviceID, secretHash string) error {
	return s.RegisterDeviceCredentialWithGeneration(ctx, deviceID, secretHash, 0)
}

// RegisterDeviceCredentialWithGeneration rotates a credential after a fresh
// Relay attestation and clears the revoked marker from the previous secret.
func (s *MySQLStore) RegisterDeviceCredentialWithGeneration(ctx context.Context, deviceID, secretHash string, generation int64) error {
	if generation < 0 {
		generation = 0
	}
	now := time.Now().UTC()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	var currentGeneration int64
	var revokedAt sql.NullTime
	err = tx.QueryRowContext(ctx, `
		SELECT enrollment_generation, revoked_at
		FROM telemetry_device_credentials
		WHERE device_id = ?
		FOR UPDATE
	`, deviceID).Scan(&currentGeneration, &revokedAt)
	switch {
	case err == sql.ErrNoRows:
		_, err = tx.ExecContext(ctx, `
			INSERT INTO telemetry_device_credentials
				(device_id, secret_hash, enrollment_generation, revoked_at, created_at, updated_at)
			VALUES (?, ?, ?, NULL, ?, ?)
		`, deviceID, secretHash, generation, now, now)
	case err != nil:
		return err
	case generation < currentGeneration || (revokedAt.Valid && generation <= currentGeneration):
		return ErrEnrollmentGenerationConflict
	default:
		_, err = tx.ExecContext(ctx, `
			UPDATE telemetry_device_credentials
			SET secret_hash = ?, enrollment_generation = ?, revoked_at = NULL, updated_at = ?
			WHERE device_id = ?
		`, secretHash, generation, now, deviceID)
	}
	if err != nil {
		return err
	}
	return tx.Commit()
}

// CreateDeviceCredential atomically creates a telemetry credential and refuses
// to overwrite an existing one. The public enrollment endpoint uses this
// create-only operation so a replay cannot rotate a secret implicitly.
func (s *MySQLStore) CreateDeviceCredential(ctx context.Context, deviceID, secretHash string) error {
	return s.CreateDeviceCredentialWithGeneration(ctx, deviceID, secretHash, 0)
}

// CreateDeviceCredentialWithGeneration creates a credential exactly once,
// except that a revoked row may be replaced by a strictly newer Relay
// enrollment generation.
func (s *MySQLStore) CreateDeviceCredentialWithGeneration(ctx context.Context, deviceID, secretHash string, generation int64) error {
	if strings.TrimSpace(deviceID) == "" || strings.TrimSpace(secretHash) == "" {
		return fmt.Errorf("invalid deviceId or secretHash")
	}
	if generation < 0 {
		generation = 0
	}
	now := time.Now().UTC()
	updated, err := s.db.ExecContext(ctx, `
		UPDATE telemetry_device_credentials
		SET secret_hash = ?, enrollment_generation = ?, revoked_at = NULL, updated_at = ?
		WHERE device_id = ? AND revoked_at IS NOT NULL AND enrollment_generation < ?
	`, secretHash, generation, now, deviceID, generation)
	if err != nil {
		return err
	}
	if count, countErr := updated.RowsAffected(); countErr == nil && count > 0 {
		return nil
	}
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO telemetry_device_credentials
			(device_id, secret_hash, enrollment_generation, revoked_at, created_at, updated_at)
		VALUES (?, ?, ?, NULL, ?, ?)
	`, deviceID, secretHash, generation, now, now)
	if isDuplicateKeyError(err) {
		return ErrDeviceCredentialAlreadyExists
	}
	return err
}

func (s *MySQLStore) GetDeviceCredential(ctx context.Context, deviceID string) (string, error) {
	var secretHash string
	err := s.db.QueryRowContext(ctx, "SELECT secret_hash FROM telemetry_device_credentials WHERE device_id = ?", deviceID).Scan(&secretHash)
	if err == sql.ErrNoRows {
		return "", fmt.Errorf("%w: %s", ErrDeviceCredentialNotFound, deviceID)
	}
	return secretHash, err
}

func (s *MySQLStore) GetDeviceCredentialMetadata(ctx context.Context, deviceID string) (DeviceCredential, error) {
	var credential DeviceCredential
	var revokedAt sql.NullTime
	err := s.db.QueryRowContext(ctx, `
		SELECT secret_hash, enrollment_generation, revoked_at
		FROM telemetry_device_credentials
		WHERE device_id = ?
	`, deviceID).Scan(&credential.SecretHash, &credential.EnrollmentGeneration, &revokedAt)
	if err == sql.ErrNoRows {
		return DeviceCredential{}, fmt.Errorf("%w: %s", ErrDeviceCredentialNotFound, deviceID)
	}
	if err != nil {
		return DeviceCredential{}, err
	}
	if revokedAt.Valid {
		value := revokedAt.Time
		credential.RevokedAt = &value
	}
	return credential, nil
}

func (s *MySQLStore) RevokeDeviceCredential(ctx context.Context, deviceID string) error {
	now := time.Now().UTC()
	result, err := s.db.ExecContext(ctx, `
		UPDATE telemetry_device_credentials
		SET revoked_at = COALESCE(revoked_at, ?), updated_at = ?
		WHERE device_id = ?
	`, now, now, deviceID)
	if err != nil {
		return err
	}
	if affected, rowsErr := result.RowsAffected(); rowsErr == nil && affected == 0 {
		// MySQL may report zero affected rows when the row already carries the
		// same revocation timestamp. Distinguish an idempotent revoke from a
		// missing credential with an explicit existence check.
		var exists int
		lookupErr := s.db.QueryRowContext(ctx,
			"SELECT 1 FROM telemetry_device_credentials WHERE device_id = ?", deviceID,
		).Scan(&exists)
		if lookupErr == sql.ErrNoRows {
			return fmt.Errorf("%w: %s", ErrDeviceCredentialNotFound, deviceID)
		}
		if lookupErr != nil {
			return lookupErr
		}
	}
	return nil
}

func (s *MySQLStore) Close() error {
	return s.db.Close()
}
