// MySQL-backed Storage: durable enrollment and revocation.
//
// Phase 1 moves the device-plane durable state (enrollment, revocation) to
// MySQL so a relay restart no longer clears it. The nonce replay cache stays
// in-memory (memoryStore) until Phase 2 moves it to Redis.

package relay

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/go-sql-driver/mysql"
)

// mysqlSchemaStatements is applied idempotently when a MySQL store is opened,
// one statement per Exec (the driver rejects multi-statement strings unless
// multiStatements=true is set in the DSN). DATETIME(6) preserves sub-second
// enrollment/revocation precision so tombstone upper bounds computed from
// EnrolledAt never understate the real credential expiry.
var mysqlSchemaStatements = []string{
	`CREATE TABLE IF NOT EXISTS devices (
  device_id        VARCHAR(128) NOT NULL PRIMARY KEY,
  public_key       VARCHAR(128) NOT NULL,
  platform         VARCHAR(64)  NOT NULL DEFAULT '',
  protocol_version INT          NOT NULL DEFAULT 1,
  enrolled_at      DATETIME(6)  NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,
	`CREATE TABLE IF NOT EXISTS revocations (
  device_id   VARCHAR(128) NOT NULL PRIMARY KEY,
  revoked_at  DATETIME(6)  NOT NULL,
  valid_until DATETIME(6)  NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,
	`CREATE TABLE IF NOT EXISTS relay_meta (
  meta_key   VARCHAR(64) NOT NULL PRIMARY KEY,
  meta_value BIGINT      NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,
}

// enrollmentCounterKey 是 relay_meta 里记录当前设备数的 singleton 行。新设备入册的
// 容量分配通过它串行化（FOR UPDATE），MaxEnrolledDevices 在并发下保持硬上限。
const enrollmentCounterKey = "enrollment_count"

// errEnrollmentCapacity 表示容量检查命中上限；调用方映射为 enrollmentResourceLimit。
var errEnrollmentCapacity = errors.New("enrollment capacity reached")

// revocationPruneInterval bounds the growth of the durable revocations table:
// rows whose protected credentials have expired are swept periodically.
const revocationPruneInterval = time.Hour

// mysqlStore implements Storage against a MySQL database. database/sql's
// connection pool is concurrent-safe, so individual methods need no caller-held
// lock; composite device operations are serialized per device by the caller's
// lock stripe, letting different devices use the pool in parallel.
type mysqlStore struct {
	db          *sql.DB
	maxEnrolled int
	closeCh     chan struct{}
	closeOnce   sync.Once
	wg          sync.WaitGroup
}

// openMySQLStore opens the database, applies the schema migration, and verifies
// connectivity. The DSN must include parseTime=true&loc=UTC so DATETIME columns
// round-trip into time.Time consistently.
func openMySQLStore(ctx context.Context, dsn string, maxEnrolled int) (*mysqlStore, error) {
	cfg, err := mysql.ParseDSN(dsn)
	if err != nil {
		return nil, fmt.Errorf("invalid RELAY_DATABASE_URL: %w", err)
	}
	if !cfg.ParseTime {
		// Without parseTime the driver returns DATETIME columns as raw bytes and
		// every Scan into time.Time fails at runtime; fail fast at startup.
		return nil, errors.New("RELAY_DATABASE_URL must include parseTime=true (and loc=UTC)")
	}
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	for _, statement := range mysqlSchemaStatements {
		if _, err := db.ExecContext(ctx, statement); err != nil {
			_ = db.Close()
			return nil, err
		}
	}
	store := &mysqlStore{db: db, maxEnrolled: maxEnrolled, closeCh: make(chan struct{})}
	store.wg.Add(1)
	go store.pruneRevocationsLoop()
	return store, nil
}

// Close 停止周期清理并释放数据库连接。
func (m *mysqlStore) Close() error {
	m.closeOnce.Do(func() { close(m.closeCh) })
	m.wg.Wait()
	return m.db.Close()
}

// pruneRevocationsLoop 周期性删除已过期的吊销 tombstone，防止 revocations 表随
// 历史吊销设备无界增长。行被 IsRevoked 惰性清理兜底，此任务只保证未被复查的设备
// 的过期行最终被清除。
func (m *mysqlStore) pruneRevocationsLoop() {
	defer m.wg.Done()
	ticker := time.NewTicker(revocationPruneInterval)
	defer ticker.Stop()
	for {
		select {
		case <-m.closeCh:
			return
		case <-ticker.C:
			_ = m.pruneExpiredRevocations(context.Background())
		}
	}
}

// pruneExpiredRevocations 删除 valid_until 已过的吊销行。单独抽出便于测试。
func (m *mysqlStore) pruneExpiredRevocations(ctx context.Context) error {
	_, err := m.db.ExecContext(ctx, `DELETE FROM revocations WHERE valid_until <= ?`, time.Now())
	return err
}

func (m *mysqlStore) GetEnrollment(ctx context.Context, deviceID string) (*EnrolledDevice, error) {
	var d EnrolledDevice
	err := m.db.QueryRowContext(ctx,
		`SELECT device_id, public_key, platform, protocol_version, enrolled_at
		   FROM devices WHERE device_id = ?`, deviceID,
	).Scan(&d.DeviceID, &d.PublicKey, &d.Platform, &d.ProtocolVersion, &d.EnrolledAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &d, nil
}

func (m *mysqlStore) PutEnrollment(ctx context.Context, device *EnrolledDevice) (enrollmentResult, error) {
	tx, err := m.db.BeginTx(ctx, nil)
	if err != nil {
		return enrollmentResourceLimit, err
	}
	defer func() { _ = tx.Rollback() }()

	// FOR UPDATE on the (possibly absent) device row serializes concurrent
	// enrolls of the same device_id across instances, so the identity-conflict
	// invariant is enforced atomically: a second transaction either blocks on
	// the gap/row lock and then sees the committed key, or it blocks on the
	// inserted row.
	var storedKey string
	err = tx.QueryRowContext(ctx,
		`SELECT public_key FROM devices WHERE device_id = ? FOR UPDATE`, device.DeviceID,
	).Scan(&storedKey)
	isNewDevice := false
	switch {
	case err == nil:
		if storedKey != device.PublicKey {
			return enrollmentIdentityConflict, nil
		}
	case errors.Is(err, sql.ErrNoRows):
		isNewDevice = true
		if err := m.reserveEnrollmentCapacity(ctx, tx); err != nil {
			if errors.Is(err, errEnrollmentCapacity) {
				return enrollmentResourceLimit, nil
			}
			return enrollmentResourceLimit, err
		}
	default:
		return enrollmentResourceLimit, err
	}

	// Upsert the enrollment and clear any revocation tombstone atomically so a
	// re-enroll both refreshes identity and un-revokes in one transaction.
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO devices (device_id, public_key, platform, protocol_version, enrolled_at)
		VALUES (?, ?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE
		  public_key = VALUES(public_key),
		  platform = VALUES(platform),
		  protocol_version = VALUES(protocol_version),
		  enrolled_at = VALUES(enrolled_at)`,
		device.DeviceID, device.PublicKey, device.Platform, device.ProtocolVersion, device.EnrolledAt,
	); err != nil {
		return enrollmentResourceLimit, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM revocations WHERE device_id = ?`, device.DeviceID); err != nil {
		return enrollmentResourceLimit, err
	}
	if isNewDevice {
		if _, err := tx.ExecContext(ctx,
			`UPDATE relay_meta SET meta_value = meta_value + 1 WHERE meta_key = ?`,
			enrollmentCounterKey,
		); err != nil {
			return enrollmentResourceLimit, err
		}
	}
	if err := tx.Commit(); err != nil {
		return enrollmentResourceLimit, err
	}
	return enrollmentOK, nil
}

// reserveEnrollmentCapacity allocates one slot from the singleton enrollment
// counter inside tx. The counter row is locked FOR UPDATE, so concurrent
// new-device enrollments (different deviceIDs, possibly from other instances)
// serialize here and the MaxEnrolledDevices bound stays a hard limit instead of
// degrading to a soft one under the per-device lock stripes. A missing counter
// row (fresh DB or pre-upgrade) is initialized from the current device count
// before the check; the increment itself happens after the device insert.
func (m *mysqlStore) reserveEnrollmentCapacity(ctx context.Context, tx *sql.Tx) error {
	var count int
	err := tx.QueryRowContext(ctx,
		`SELECT meta_value FROM relay_meta WHERE meta_key = ? FOR UPDATE`,
		enrollmentCounterKey,
	).Scan(&count)
	if errors.Is(err, sql.ErrNoRows) {
		// 计数器未初始化：以 devices 表当前行数为基准初始化。INSERT IGNORE 让并发
		// 初始化只落一次；随后的 FOR UPDATE 读到已提交值。
		if _, err := tx.ExecContext(ctx,
			`INSERT IGNORE INTO relay_meta (meta_key, meta_value)
			 VALUES (?, (SELECT COUNT(*) FROM devices))`,
			enrollmentCounterKey,
		); err != nil {
			return err
		}
		if err := tx.QueryRowContext(ctx,
			`SELECT meta_value FROM relay_meta WHERE meta_key = ? FOR UPDATE`,
			enrollmentCounterKey,
		).Scan(&count); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	if count >= m.maxEnrolled {
		return errEnrollmentCapacity
	}
	return nil
}

func (m *mysqlStore) RemoveEnrollment(ctx context.Context, deviceID string) error {
	tx, err := m.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	result, err := tx.ExecContext(ctx, `DELETE FROM devices WHERE device_id = ?`, deviceID)
	if err != nil {
		return err
	}
	if affected, err := result.RowsAffected(); err != nil {
		return err
	} else if affected > 0 {
		// 同步递减计数器（下限 0），避免容量上限随删除长期漂移而越变越严。
		if _, err := tx.ExecContext(ctx,
			`UPDATE relay_meta SET meta_value = GREATEST(meta_value - 1, 0) WHERE meta_key = ?`,
			enrollmentCounterKey,
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (m *mysqlStore) RecordRevocation(ctx context.Context, deviceID string, validUntil time.Time) (bool, error) {
	if _, err := m.db.ExecContext(ctx, `
		INSERT INTO revocations (device_id, revoked_at, valid_until)
		VALUES (?, ?, ?)
		ON DUPLICATE KEY UPDATE valid_until = GREATEST(valid_until, VALUES(valid_until))`,
		deviceID, time.Now(), validUntil,
	); err != nil {
		return false, err
	}
	// MySQL revocation is durable and not subject to the in-memory tombstone
	// capacity; the tombstone expires when its credential does.
	return true, nil
}

func (m *mysqlStore) RevocationExpiry(ctx context.Context, deviceID string) (time.Time, bool, error) {
	var validUntil time.Time
	err := m.db.QueryRowContext(ctx,
		`SELECT valid_until FROM revocations WHERE device_id = ?`, deviceID,
	).Scan(&validUntil)
	if errors.Is(err, sql.ErrNoRows) {
		return time.Time{}, false, nil
	}
	if err != nil {
		return time.Time{}, false, err
	}
	return validUntil, true, nil
}

func (m *mysqlStore) IsRevoked(ctx context.Context, deviceID string, now time.Time) (bool, error) {
	validUntil, present, err := m.RevocationExpiry(ctx, deviceID)
	if err != nil || !present {
		return false, err
	}
	if !now.Before(validUntil) {
		// Lazy-prune the expired tombstone; it cannot reauthorize a revoked
		// credential whose expiry has already passed.
		_, _ = m.db.ExecContext(ctx,
			`DELETE FROM revocations WHERE device_id = ? AND valid_until <= ?`, deviceID, now)
		return false, nil
	}
	return true, nil
}

func (m *mysqlStore) CountEnrollments(ctx context.Context) (int, error) {
	var count int
	err := m.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices`).Scan(&count)
	return count, err
}

func (m *mysqlStore) ListEnrollments(ctx context.Context) ([]*EnrolledDevice, error) {
	rows, err := m.db.QueryContext(ctx,
		`SELECT device_id, public_key, platform, protocol_version, enrolled_at FROM devices`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]*EnrolledDevice, 0, 16)
	for rows.Next() {
		var d EnrolledDevice
		if err := rows.Scan(&d.DeviceID, &d.PublicKey, &d.Platform, &d.ProtocolVersion, &d.EnrolledAt); err != nil {
			return nil, err
		}
		items = append(items, &d)
	}
	return items, rows.Err()
}
