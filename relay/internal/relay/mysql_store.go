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

// testAfterCounterCountHook 是测试专用缝隙：在 ensureEnrollmentCounter 的
// `SELECT COUNT(*)` 之后、`INSERT IGNORE` 之前调用，用于确定性构造「懒初始化基准
// 与并发 Remove 交错」的时序。生产环境始终为 nil。
var testAfterCounterCountHook func()

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
	// 启动时初始化容量计数器：serving 前该行必存在，使 RemoveEnrollment 的递减与
	// putEnrollment 的 FOR UPDATE 都作用于 record lock（而非缺失行 gap lock），且
	// 升级库（已有设备、无 counter 行）在首个 enroll/remove 前即拿到正确基准。
	// openMySQLStore 在本 store 对外服务前执行，无并发 cardinality 变更；多实例
	// 并发 open 由 INSERT IGNORE 幂等。
	initTx, err := db.BeginTx(ctx, nil)
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	if err := ensureEnrollmentCounter(ctx, initTx); err != nil {
		_ = initTx.Rollback()
		_ = db.Close()
		return nil, err
	}
	if err := initTx.Commit(); err != nil {
		_ = db.Close()
		return nil, err
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
	// InnoDB 并发插入同一索引 gap（空表首批新设备共享一个 gap、或计数器懒初始化
	// 期间的锁交互）会偶发死锁（1213）。死锁是瞬态事务冲突，MySQL 标准做法是重试
	// 整个事务；重试时计数器行已存在，串行化新设备入册，不再触发。容量命中
	// （errEnrollmentCapacity）不是死锁，直接返回。
	for attempt := 0; ; attempt++ {
		result, err := m.putEnrollment(ctx, device)
		if err == nil || !isDeadlockError(err) {
			return result, err
		}
		if attempt >= 2 {
			return enrollmentResourceLimit, fmt.Errorf("enrollment deadlocked after %d attempts: %w", attempt+1, err)
		}
		select {
		case <-ctx.Done():
			return enrollmentResourceLimit, ctx.Err()
		case <-time.After(time.Duration(attempt+1) * 5 * time.Millisecond):
		}
	}
}

// isDeadlockError reports whether err is an InnoDB deadlock (ER_LOCK_DEADLOCK,
// MySQL error 1213), which is transient and safe to retry.
func isDeadlockError(err error) bool {
	var mysqlErr *mysql.MySQLError
	return errors.As(err, &mysqlErr) && mysqlErr.Number == 1213
}

func (m *mysqlStore) putEnrollment(ctx context.Context, device *EnrolledDevice) (enrollmentResult, error) {
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

// ensureEnrollmentCounter 确保 relay_meta.enrollment_count 计数器行存在；缺失时以
// 调用时刻 devices 表的当前行数为基准幂等初始化（INSERT IGNORE，字面量值）。
//
// 基准取自调用方事务的 consistent-read 快照：putEnrollment 在插入新设备前调用
// （快照含既有设备），RemoveEnrollment 在删除前调用（快照仍含待删行）——两者基准
// 都是"变更前"计数，随后各自的 +1/−1 在 counter 行锁下与其它 cardinality 变更
// 串行，最终收敛到 COUNT(devices)。多实例并发初始化时 INSERT IGNORE 保证只存活
// 一个基准。
//
// 不能用 `INSERT ... SELECT COUNT(*)` 初始化：InnoDB 会对其源表 devices 取共享
// next-key 锁，与其它事务对 devices 的 FOR UPDATE gap 锁（X）冲突，两个并发新设备
// enroll 会在 devices 表上互相等待形成死锁（1213）。故先无锁一致读 COUNT（MVCC
// 快照，不取锁），再以字面值 INSERT IGNORE。
func ensureEnrollmentCounter(ctx context.Context, tx *sql.Tx) error {
	// 先无锁普通读探测计数器行（consistent read，不取任何锁）。不能用 FOR UPDATE
	// 探测缺失行：InnoDB 对不存在主键会取 gap lock（事务间互相兼容），随后
	// INSERT IGNORE 需要的 insert-intention lock 与对方 gap lock 冲突——两个并发
	// 新设备 enroll 在计数器缺失时会形成等待环死锁（1213）。
	var probe int
	err := tx.QueryRowContext(ctx,
		`SELECT meta_value FROM relay_meta WHERE meta_key = ?`, enrollmentCounterKey,
	).Scan(&probe)
	if err == nil {
		return nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	var initialCount int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices`).Scan(&initialCount); err != nil {
		return err
	}
	if testAfterCounterCountHook != nil {
		testAfterCounterCountHook()
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT IGNORE INTO relay_meta (meta_key, meta_value) VALUES (?, ?)`,
		enrollmentCounterKey, initialCount,
	); err != nil {
		return err
	}
	return nil
}

// reserveEnrollmentCapacity allocates one slot from the singleton enrollment
// counter inside tx. The counter row is locked FOR UPDATE, so concurrent
// new-device enrollments (different deviceIDs, possibly from other instances)
// serialize here and the MaxEnrolledDevices bound stays a hard limit instead of
// degrading to a soft one under the per-device lock stripes. A missing counter
// row (fresh DB or pre-upgrade) is initialized from the current device count
// before the check; the increment itself happens after the device insert.
func (m *mysqlStore) reserveEnrollmentCapacity(ctx context.Context, tx *sql.Tx) error {
	if err := ensureEnrollmentCounter(ctx, tx); err != nil {
		return err
	}
	// FOR UPDATE 锁住计数器行做容量分配（此时行必存在，取 record lock，串行正确）。
	var count int
	if err := tx.QueryRowContext(ctx,
		`SELECT meta_value FROM relay_meta WHERE meta_key = ? FOR UPDATE`,
		enrollmentCounterKey,
	).Scan(&count); err != nil {
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
	// 与 putEnrollment 保持相同锁序（device → counter）：先锁设备行确认存在，再
	// ensure 计数器（缺失时以「删除前」的 COUNT 为基准初始化，避免懒初始化基准与
	// 并发 Remove 交错造成永久 drift），随后删除并递减。设备不存在则无 cardinality
	// 变化，直接提交。
	var present int
	err = tx.QueryRowContext(ctx,
		`SELECT 1 FROM devices WHERE device_id = ? FOR UPDATE`, deviceID,
	).Scan(&present)
	if errors.Is(err, sql.ErrNoRows) {
		return tx.Commit()
	}
	if err != nil {
		return err
	}
	if err := ensureEnrollmentCounter(ctx, tx); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM devices WHERE device_id = ?`, deviceID); err != nil {
		return err
	}
	// 同步递减计数器（下限 0），避免容量上限随删除长期漂移而越变越严。设备行已由
	// FOR UPDATE 锁定，DELETE 必然删除该行，无需再检查 RowsAffected。
	if _, err := tx.ExecContext(ctx,
		`UPDATE relay_meta SET meta_value = GREATEST(meta_value - 1, 0) WHERE meta_key = ?`,
		enrollmentCounterKey,
	); err != nil {
		return err
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
