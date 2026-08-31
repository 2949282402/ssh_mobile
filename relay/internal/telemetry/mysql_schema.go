package telemetry

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
)

func (s *MySQLStore) EnsureSchema(ctx context.Context) error {
	if s == nil || s.db == nil {
		return fmt.Errorf("%w: mysql telemetry store is unavailable", ErrServiceUnavailable)
	}
	if ctx == nil {
		ctx = context.Background()
	}
	queries := []string{
		`CREATE TABLE IF NOT EXISTS telemetry_events (
			id BIGINT AUTO_INCREMENT PRIMARY KEY,
			-- VARBINARY preserves exact event-id bytes, including case and
			-- trailing whitespace; MySQL text collations otherwise compare
			-- those values as equal and break Go-store idempotency parity.
			event_id VARBINARY(64) NOT NULL,
			record_type VARCHAR(32) NOT NULL,
			event_name VARCHAR(128) NOT NULL,
			event_version INT NOT NULL,
			device_id VARCHAR(128) NOT NULL,
			session_id VARCHAR(128) NOT NULL,
			trace_id VARCHAR(128) NOT NULL,
			occurred_at DATETIME(3) NOT NULL,
			received_at DATETIME(3) NOT NULL,
			feature VARCHAR(64) NOT NULL,
			severity VARCHAR(32) NOT NULL,
			error_code VARCHAR(64) DEFAULT NULL,
			app_version VARCHAR(32) NOT NULL,
			build_number VARCHAR(32) NOT NULL,
			platform VARCHAR(32) NOT NULL,
			release_channel VARCHAR(32) DEFAULT NULL,
			properties_json JSON DEFAULT NULL,
			error_json JSON DEFAULT NULL,
			created_at DATETIME(3) NOT NULL,
			UNIQUE KEY uq_telemetry_event_id (event_id),
			INDEX idx_telemetry_device (device_id),
			INDEX idx_telemetry_trace (trace_id),
			INDEX idx_telemetry_name_received (event_name, received_at),
			INDEX idx_telemetry_severity_received (severity, received_at),
			INDEX idx_telemetry_error_received (error_code, received_at),
			INDEX idx_telemetry_release_channel_received (release_channel, received_at),
			INDEX idx_telemetry_received (received_at)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;`,

		`CREATE TABLE IF NOT EXISTS telemetry_ingest_receipts (
			-- Keep the receipt key byte-exact with telemetry_events.event_id.
			event_id VARBINARY(64) PRIMARY KEY,
			device_id VARCHAR(128) NOT NULL,
			received_at DATETIME(3) NOT NULL,
			INDEX idx_receipt_received (received_at)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;`,

		`CREATE TABLE IF NOT EXISTS telemetry_settings (
			id INT PRIMARY KEY,
			settings_json JSON NOT NULL,
			updated_at DATETIME(3) NOT NULL
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;`,

		`CREATE TABLE IF NOT EXISTS telemetry_device_credentials (
			device_id VARCHAR(128) PRIMARY KEY,
			secret_hash VARCHAR(128) NOT NULL,
			enrollment_generation BIGINT NOT NULL DEFAULT 0,
			revoked_at DATETIME(3) DEFAULT NULL,
			created_at DATETIME(3) NOT NULL,
			updated_at DATETIME(3) NOT NULL
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;`,
	}

	for _, q := range queries {
		if _, err := s.db.ExecContext(ctx, q); err != nil {
			return fmt.Errorf("failed executing telemetry schema DDL: %w", err)
		}
	}
	// Existing telemetry databases predate the release-channel dimension. MySQL
	// does not support IF NOT EXISTS for ADD COLUMN, so inspect the catalog first
	// and only issue the ALTER for legacy tables. The nullable column keeps old
	// rows valid without manufacturing a channel value.
	var releaseChannelColumns int
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*)
		FROM information_schema.columns
		WHERE table_schema = DATABASE()
		  AND table_name = 'telemetry_events'
		  AND column_name = 'release_channel'
	`).Scan(&releaseChannelColumns); err != nil {
		return fmt.Errorf("inspect telemetry release channel column: %w", err)
	}
	if releaseChannelColumns == 0 {
		if _, err := s.db.ExecContext(ctx, `
			ALTER TABLE telemetry_events
				ADD COLUMN release_channel VARCHAR(32) DEFAULT NULL
		`); err != nil {
			return fmt.Errorf("failed adding telemetry release channel column: %w", err)
		}
	}
	if err := s.ensureReleaseChannelIndex(ctx); err != nil {
		return err
	}
	if err := s.ensureEventIDBinaryColumns(ctx); err != nil {
		return err
	}
	if err := s.ensureTelemetryReceiptConsistency(ctx); err != nil {
		return err
	}
	if err := s.ensureEventIDUniqueIndex(ctx); err != nil {
		return err
	}
	if err := s.ensureTelemetryCredentialColumns(ctx); err != nil {
		return err
	}
	return nil
}

// ensureTelemetryCredentialColumns upgrades credential tables created before
// generation-bound telemetry tokens. Existing rows remain usable at
// generation zero until the next proof-bound rotation.
func (s *MySQLStore) ensureTelemetryCredentialColumns(ctx context.Context) error {
	columns := []struct {
		name string
		ddl  string
	}{
		{name: "enrollment_generation", ddl: "ADD COLUMN enrollment_generation BIGINT NOT NULL DEFAULT 0"},
		{name: "revoked_at", ddl: "ADD COLUMN revoked_at DATETIME(3) DEFAULT NULL"},
	}
	for _, column := range columns {
		var count int
		if err := s.db.QueryRowContext(ctx, `
			SELECT COUNT(*)
			FROM information_schema.columns
			WHERE table_schema = DATABASE()
			  AND table_name = 'telemetry_device_credentials'
			  AND column_name = ?
		`, column.name).Scan(&count); err != nil {
			return fmt.Errorf("inspect telemetry credential column %s: %w", column.name, err)
		}
		if count == 0 {
			if _, err := s.db.ExecContext(ctx, "ALTER TABLE telemetry_device_credentials "+column.ddl); err != nil {
				return fmt.Errorf("add telemetry credential column %s: %w", column.name, err)
			}
		}
	}
	return nil
}

// ensureReleaseChannelIndex installs the canonical release-channel index on
// legacy telemetry tables. CREATE TABLE defines idx_telemetry_release_channel_received
// for fresh schemas, but the legacy ADD COLUMN migration never created the
// index; admin releaseChannel filters must see the same execution plan on every
// deployment history. A malformed legacy index is replaced rather than assumed
// correct.
func (s *MySQLStore) ensureReleaseChannelIndex(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `
		SELECT SEQ_IN_INDEX, COLUMN_NAME
		FROM information_schema.statistics
		WHERE table_schema = DATABASE()
		  AND table_name = 'telemetry_events'
		  AND index_name = 'idx_telemetry_release_channel_received'
		ORDER BY SEQ_IN_INDEX
	`)
	if err != nil {
		return fmt.Errorf("inspect telemetry release channel index: %w", err)
	}
	type indexPart struct {
		seqInIndex sql.NullInt64
		columnName sql.NullString
	}
	parts := make([]indexPart, 0, 2)
	for rows.Next() {
		var part indexPart
		if err := rows.Scan(&part.seqInIndex, &part.columnName); err != nil {
			_ = rows.Close()
			return fmt.Errorf("inspect telemetry release channel index: scan metadata: %w", err)
		}
		parts = append(parts, part)
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return fmt.Errorf("inspect telemetry release channel index: iterate metadata: %w", err)
	}
	if err := rows.Close(); err != nil {
		return fmt.Errorf("inspect telemetry release channel index: close metadata: %w", err)
	}

	canonical := len(parts) == 2 &&
		parts[0].seqInIndex.Valid && parts[0].seqInIndex.Int64 == 1 &&
		parts[0].columnName.Valid && parts[0].columnName.String == "release_channel" &&
		parts[1].seqInIndex.Valid && parts[1].seqInIndex.Int64 == 2 &&
		parts[1].columnName.Valid && parts[1].columnName.String == "received_at"
	if canonical {
		return nil
	}
	if len(parts) > 0 {
		if _, err := s.db.ExecContext(ctx, "ALTER TABLE telemetry_events DROP INDEX idx_telemetry_release_channel_received"); err != nil {
			return fmt.Errorf("replace invalid telemetry release channel index: drop existing index: %w", err)
		}
	}
	if _, err := s.db.ExecContext(ctx, "ALTER TABLE telemetry_events ADD INDEX idx_telemetry_release_channel_received (release_channel, received_at)"); err != nil {
		return fmt.Errorf("add telemetry release channel index: %w", err)
	}
	return nil
}

// ensureEventIDBinaryColumns upgrades pre-backpressure schemas whose event IDs
// were VARCHAR values under the database's default PAD SPACE/case-insensitive
// collation. VARBINARY(64) is the durable representation used by both tables;
// ALTER preserves all existing bytes and makes duplicate detection explicit in
// the following consistency check.
func (s *MySQLStore) ensureEventIDBinaryColumns(ctx context.Context) error {
	for _, table := range []string{"telemetry_events", "telemetry_ingest_receipts"} {
		var dataType string
		var maxLength sql.NullInt64
		err := s.db.QueryRowContext(ctx, `
			SELECT DATA_TYPE, CHARACTER_OCTET_LENGTH
			FROM information_schema.columns
			WHERE table_schema = DATABASE() AND table_name = ? AND column_name = 'event_id'
		`, table).Scan(&dataType, &maxLength)
		if err != nil {
			return fmt.Errorf("inspect %s event id column: %w", table, err)
		}
		if strings.EqualFold(dataType, "varbinary") && maxLength.Valid && maxLength.Int64 == 64 {
			continue
		}
		if _, err := s.db.ExecContext(ctx, "ALTER TABLE "+table+" MODIFY COLUMN event_id VARBINARY(64) NOT NULL"); err != nil {
			return fmt.Errorf("migrate %s event id column to exact binary: %w", table, err)
		}
	}
	return nil
}

// ensureTelemetryReceiptConsistency repairs legacy raw-event rows that were
// written before receipts became mandatory. Receipt-only rows are expected when
// raw telemetry is purged under ADR-033 because receipts persist for replay
// idempotency; only exact duplicate raw event IDs fail this migration.
func (s *MySQLStore) ensureTelemetryReceiptConsistency(ctx context.Context) error {
	var duplicateCount int
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM (
			SELECT BINARY event_id AS event_id
			FROM telemetry_events
			GROUP BY BINARY event_id
			HAVING COUNT(*) > 1
		) AS duplicate_event_ids
	`).Scan(&duplicateCount); err != nil {
		return fmt.Errorf("check duplicate telemetry event ids: %w", err)
	}
	if duplicateCount > 0 {
		return fmt.Errorf("telemetry schema migration found %d duplicate event ids; resolve duplicates before enabling receipt idempotency", duplicateCount)
	}

	var missingCount int
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*)
		FROM telemetry_events e
		LEFT JOIN telemetry_ingest_receipts r ON BINARY r.event_id = BINARY e.event_id
		WHERE r.event_id IS NULL
	`).Scan(&missingCount); err != nil {
		return fmt.Errorf("check telemetry receipt coverage: %w", err)
	}
	if missingCount == 0 {
		return nil
	}
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO telemetry_ingest_receipts (event_id, device_id, received_at)
		SELECT e.event_id, e.device_id, e.received_at
		FROM telemetry_events e
		LEFT JOIN telemetry_ingest_receipts r ON BINARY r.event_id = BINARY e.event_id
		WHERE r.event_id IS NULL
	`); err != nil {
		return fmt.Errorf("backfill %d missing telemetry ingest receipts: %w", missingCount, err)
	}
	var remaining int
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*)
		FROM telemetry_events e
		LEFT JOIN telemetry_ingest_receipts r ON BINARY r.event_id = BINARY e.event_id
		WHERE r.event_id IS NULL
	`).Scan(&remaining); err != nil {
		return fmt.Errorf("verify telemetry receipt backfill: %w", err)
	}
	if remaining != 0 {
		return fmt.Errorf("telemetry schema migration left %d raw events without receipts", remaining)
	}
	return nil
}

// ensureEventIDUniqueIndex upgrades telemetry databases created before event
// idempotency was enforced by the raw-events table. Existing duplicate rows
// intentionally fail this migration instead of silently deleting telemetry or
// weakening receipt semantics.
func (s *MySQLStore) ensureEventIDUniqueIndex(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `
		SELECT s.NON_UNIQUE, s.SEQ_IN_INDEX, s.COLUMN_NAME, s.SUB_PART,
		       c.DATA_TYPE, c.CHARACTER_OCTET_LENGTH, c.COLLATION_NAME
		FROM information_schema.statistics s
		LEFT JOIN information_schema.columns c
		  ON c.TABLE_SCHEMA = s.TABLE_SCHEMA
		 AND c.TABLE_NAME = s.TABLE_NAME
		 AND c.COLUMN_NAME = s.COLUMN_NAME
		WHERE s.TABLE_SCHEMA = DATABASE()
		  AND s.TABLE_NAME = 'telemetry_events'
		  AND s.INDEX_NAME = 'uq_telemetry_event_id'
		ORDER BY s.SEQ_IN_INDEX
	`)
	if err != nil {
		return fmt.Errorf("inspect telemetry event id index: %w", err)
	}

	type indexPart struct {
		nonUnique   sql.NullInt64
		seqInIndex  sql.NullInt64
		columnName  sql.NullString
		subPart     sql.NullInt64
		dataType    sql.NullString
		octetLength sql.NullInt64
		collation   sql.NullString
	}
	parts := make([]indexPart, 0, 1)
	for rows.Next() {
		var part indexPart
		if err := rows.Scan(
			&part.nonUnique,
			&part.seqInIndex,
			&part.columnName,
			&part.subPart,
			&part.dataType,
			&part.octetLength,
			&part.collation,
		); err != nil {
			_ = rows.Close()
			return fmt.Errorf("inspect telemetry event id index: scan metadata: %w", err)
		}
		parts = append(parts, part)
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return fmt.Errorf("inspect telemetry event id index: iterate metadata: %w", err)
	}
	if err := rows.Close(); err != nil {
		return fmt.Errorf("inspect telemetry event id index: close metadata: %w", err)
	}

	for _, part := range parts {
		if !part.nonUnique.Valid || !part.seqInIndex.Valid || !part.columnName.Valid ||
			!part.dataType.Valid || !part.octetLength.Valid {
			return fmt.Errorf("inspect telemetry event id index: required metadata is NULL")
		}
		if part.nonUnique.Int64 < 0 || part.seqInIndex.Int64 < 1 ||
			strings.TrimSpace(part.columnName.String) == "" ||
			strings.TrimSpace(part.dataType.String) == "" || part.octetLength.Int64 < 1 {
			return fmt.Errorf("inspect telemetry event id index: malformed required metadata")
		}
		if part.subPart.Valid && part.subPart.Int64 < 1 {
			return fmt.Errorf("inspect telemetry event id index: malformed prefix metadata")
		}
		if part.collation.Valid && strings.TrimSpace(part.collation.String) == "" {
			return fmt.Errorf("inspect telemetry event id index: malformed collation metadata")
		}
	}

	if len(parts) == 1 {
		part := parts[0]
		if part.nonUnique.Valid && part.nonUnique.Int64 == 0 &&
			part.seqInIndex.Valid && part.seqInIndex.Int64 == 1 &&
			part.columnName.Valid && part.columnName.String == "event_id" &&
			!part.subPart.Valid &&
			part.dataType.Valid && strings.EqualFold(part.dataType.String, "varbinary") &&
			part.octetLength.Valid && part.octetLength.Int64 == 64 &&
			!part.collation.Valid {
			return nil
		}
	}

	if len(parts) > 0 {
		if _, err := s.db.ExecContext(ctx, "ALTER TABLE telemetry_events DROP INDEX uq_telemetry_event_id"); err != nil {
			return fmt.Errorf("replace invalid telemetry event id index: drop existing index: %w", err)
		}
	}
	if _, err := s.db.ExecContext(ctx, "ALTER TABLE telemetry_events ADD UNIQUE KEY uq_telemetry_event_id (event_id)"); err != nil {
		return fmt.Errorf("add telemetry event id index: %w", err)
	}
	return nil
}
