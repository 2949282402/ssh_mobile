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
	"math/rand"
	"sync"
	"time"

	"github.com/go-sql-driver/mysql"
)

// mysqlSchemaStatements is applied idempotently when a MySQL store is opened,
// one statement per Exec (the driver rejects multi-statement strings unless
// multiStatements=true is set in the DSN). DATETIME(6) preserves sub-second
// enrollment/revocation precision so tombstone upper bounds computed from
// EnrolledAt never understate the real credential expiry.
//
// Step 3 (design §27) adds the durable User / Credential / Audit tables. They are
// strictly additive: existing enrollment/revocation rows and tables are
// untouched, and the current stateless HMAC credential path keeps working as-is.
// These tables exist so the auth path can be migrated onto durable records
// without changing the device-plane wire contract. MySQL remains the durable truth; Redis
// stays the rebuildable live-state layer (presence/discovery/nonce).
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
	// User durable record (design §27 "MySQL = Durable Truth"). A user is the
	// account that owns devices; this table is the migration target for a future
	// device→user binding. Additive; not yet referenced by the auth path.
	`CREATE TABLE IF NOT EXISTS users (
  user_id      VARCHAR(128) NOT NULL PRIMARY KEY,
  display_name VARCHAR(256) NOT NULL DEFAULT '',
  created_at   DATETIME(6)  NOT NULL,
  updated_at   DATETIME(6)  NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,
	// Credential durable record: the migration target for the stateless HMAC
	// token path. Today credentials are signed statelessly (verifyCredential);
	// this table lets a future auth path record issued credentials per device,
	// revoke them durably, and enumerate them for audit/rotation — without
	// changing the current stateless path.
	`CREATE TABLE IF NOT EXISTS credentials (
  credential_id VARCHAR(64)  NOT NULL PRIMARY KEY,
  user_id       VARCHAR(128) NOT NULL,
  device_id     VARCHAR(128) NOT NULL,
  public_key    VARCHAR(128) NOT NULL,
  issued_at     DATETIME(6)  NOT NULL,
  expires_at    DATETIME(6)  NOT NULL,
  revoked_at    DATETIME(6)  NULL,
  KEY idx_credentials_user (user_id),
  KEY idx_credentials_device (device_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,
	// Audit durable record: append-only administrative/device lifecycle trail.
	// Not yet written by handlers; the schema is the migration scaffold.
	`CREATE TABLE IF NOT EXISTS audit_log (
  audit_id   BIGINT        NOT NULL AUTO_INCREMENT PRIMARY KEY,
  actor      VARCHAR(128)  NOT NULL DEFAULT '',
  action     VARCHAR(128)  NOT NULL,
  resource   VARCHAR(256)  NOT NULL DEFAULT '',
  detail     TEXT          NULL,
  created_at DATETIME(6)   NOT NULL,
  KEY idx_audit_actor (actor),
  KEY idx_audit_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,
}

// enrollmentCounterKey 是 relay_meta 里记录当前设备数的 singleton 行。新设备入册的
// 容量分配通过它串行化（FOR UPDATE），MaxEnrolledDevices 在并发下保持硬上限。
const enrollmentCounterKey = "enrollment_count"

// errEnrollmentCapacity 表示容量检查命中上限；调用方映射为 enrollmentResourceLimit。
var errEnrollmentCapacity = errors.New("enrollment capacity reached")

const (
	// revocationPruneInterval bounds the growth of the durable revocations table:
	// rows whose protected credentials have expired are swept periodically.
	revocationPruneInterval = time.Hour
	// revocationPruneTimeout keeps one slow database operation from pinning the
	// store lifecycle forever. Close cancels the parent context as an additional
	// shutdown signal, so a compliant database driver releases the in-flight
	// query immediately instead of consuming the full timeout.
	revocationPruneTimeout = 5 * time.Second
)

// mysqlStore implements Storage against a MySQL database. database/sql's
// connection pool is concurrent-safe, so individual methods need no caller-held
// lock; composite device operations are serialized per device by the caller's
// lock stripe, letting different devices use the pool in parallel.
type mysqlStore struct {
	db              *sql.DB
	maxEnrolled     int
	lifecycleCtx    context.Context
	lifecycleCancel context.CancelFunc
	closeOnce       sync.Once
	closeErr        error
	wg              sync.WaitGroup
}

// openMySQLStore opens the database, applies the schema migration, and verifies
// connectivity. The DSN must enable parseTime and retain UTC location semantics
// (the driver default, canonically written as loc=UTC) so DATETIME columns
// round-trip into time.Time consistently across instances.
func openMySQLStore(ctx context.Context, dsn string, maxEnrolled int) (*mysqlStore, error) {
	cfg, err := mysql.ParseDSN(dsn)
	if err != nil {
		return nil, fmt.Errorf("invalid RELAY_DATABASE_URL: %w", err)
	}
	if !cfg.ParseTime {
		// Without parseTime the driver returns DATETIME columns as raw bytes and
		// every Scan into time.Time fails at runtime; fail fast at startup.
		return nil, errors.New("RELAY_DATABASE_URL must include parseTime=true")
	}
	if cfg.Loc != time.UTC {
		// Enrollment generations and revocation bounds are compared across Relay
		// instances. Parsing DATETIME in a process-local zone would make the same
		// durable row produce different instants, so reject it before dialing.
		return nil, errors.New("RELAY_DATABASE_URL location must be UTC")
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
	lifecycleCtx, lifecycleCancel := context.WithCancel(context.Background())
	store := &mysqlStore{
		db:              db,
		maxEnrolled:     maxEnrolled,
		lifecycleCtx:    lifecycleCtx,
		lifecycleCancel: lifecycleCancel,
	}
	store.wg.Add(1)
	go store.pruneRevocationsLoop()
	return store, nil
}

// Close 停止周期清理并释放数据库连接。
func (m *mysqlStore) Close() error {
	m.closeOnce.Do(func() {
		m.lifecycleCancel()
		m.wg.Wait()
		m.closeErr = m.db.Close()
	})
	return m.closeErr
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
		case <-m.lifecycleCtx.Done():
			return
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(m.lifecycleCtx, revocationPruneTimeout)
			_ = m.pruneExpiredRevocations(ctx)
			cancel()
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
	//
	// 退避用指数 + 抖动：并发新设备入册全部挤在同一 gap 时，线性短退避（5ms 起步）让
	// 重试仍落在其它事务持有 gap 锁的窗口内，自相碰撞、3 次预算在几路并发下即耗尽。
	// 指数退避把重试错开到首批事务提交之后（gap 随已有键细分），抖动避免同一批重试
	// 同步再撞。耗尽仍映射 enrollmentResourceLimit（enrollmentResult 枚举没有"瞬态
	// 失败"值，客户端语义不变）。
	for attempt := 0; ; attempt++ {
		result, err := m.putEnrollment(ctx, device)
		if err == nil || !isDeadlockError(err) {
			return result, err
		}
		if attempt >= 4 {
			return enrollmentResourceLimit, fmt.Errorf("enrollment deadlocked after %d attempts: %w", attempt+1, err)
		}
		select {
		case <-ctx.Done():
			return enrollmentResourceLimit, ctx.Err()
		case <-time.After(enrollmentDeadlockBackoff(attempt)):
		}
	}
}

// enrollmentDeadlockBackoff 返回第 attempt 次死锁重试前的退避：指数退避（10ms 起每次
// 翻倍：10/20/40/80ms）+ ±50% 随机抖动。抖动让同一批并发入册的重试错开，避免同步
// 重试再次撞上同一 gap（retry storm）。
func enrollmentDeadlockBackoff(attempt int) time.Duration {
	base := 10 * time.Millisecond * time.Duration(1<<uint(attempt))
	return base/2 + time.Duration(rand.Int63n(int64(base)))
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
	var storedEnrolledAt time.Time
	err = tx.QueryRowContext(ctx,
		`SELECT public_key, enrolled_at FROM devices WHERE device_id = ? FOR UPDATE`, device.DeviceID,
	).Scan(&storedKey, &storedEnrolledAt)
	isNewDevice := false
	switch {
	case err == nil:
		if storedKey != device.PublicKey {
			return enrollmentIdentityConflict, nil
		}
		device.EnrolledAt = nextEnrollmentTime(device.EnrolledAt, &EnrolledDevice{EnrolledAt: storedEnrolledAt})
	case errors.Is(err, sql.ErrNoRows):
		isNewDevice = true
		// Preserve the established device -> counter -> revocation lock order.
		// RevokeEnrollment takes the counter before inserting/updating its
		// tombstone; taking the tombstone first here would create an avoidable
		// cross-device lock inversion.
		if err := m.reserveEnrollmentCapacity(ctx, tx); err != nil {
			if errors.Is(err, errEnrollmentCapacity) {
				return enrollmentResourceLimit, nil
			}
			return enrollmentResourceLimit, err
		}
		var revokedAt time.Time
		revokeErr := tx.QueryRowContext(ctx,
			`SELECT revoked_at FROM revocations WHERE device_id = ? FOR UPDATE`, device.DeviceID,
		).Scan(&revokedAt)
		switch {
		case revokeErr == nil:
			device.EnrolledAt = nextEnrollmentTime(device.EnrolledAt, &EnrolledDevice{EnrolledAt: revokedAt})
		case errors.Is(revokeErr, sql.ErrNoRows):
			device.EnrolledAt = nextEnrollmentTime(device.EnrolledAt, nil)
		default:
			return enrollmentResourceLimit, revokeErr
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

// RevokeEnrollment 以单事务原子地完成吊销：先对 devices 行 FOR UPDATE（与
// putEnrollment 的首锁一致，跨实例与并发 re-enroll 严格串行），再写 tombstone、删
// enrollment、递减容量计数器。这消除旧复合流程（adminRevokeDevice 的 RecordRevocation
// + RemoveEnrollment 两个独立事务，仅靠进程内分片锁串行）在多实例下的撕裂窗口：实例 A
// 写墓碑后、删设备前，实例 B 的 re-enroll 曾可覆盖新行并清墓碑，随后 A 误删新 enrollment
// → "设备没了 + 墓碑也没了"。锁序 device → counter 与 putEnrollment/RemoveEnrollment
// 一致，无锁序反转。revocations 表上的 gap 锁交互（本事务的 INSERT 墓碑 vs 并发新设备
// 入册的 DELETE 清墓碑 + relay_meta 行锁）可偶发 1213 死锁，与入册路径一致做有限重试。
func (m *mysqlStore) RevokeEnrollment(ctx context.Context, deviceID string, credentialTTL time.Duration) (revokeResult, int64, error) {
	for attempt := 0; ; attempt++ {
		result, generation, err := m.revokeEnrollment(ctx, deviceID, credentialTTL)
		if err == nil || !isDeadlockError(err) {
			return result, generation, err
		}
		if attempt >= 2 {
			return revokeNotEnrolled, 0, fmt.Errorf("revocation deadlocked after %d attempts: %w", attempt+1, err)
		}
		select {
		case <-ctx.Done():
			return revokeNotEnrolled, 0, ctx.Err()
		case <-time.After(time.Duration(attempt+1) * 5 * time.Millisecond):
		}
	}
}

// revokeEnrollment 是 RevokeEnrollment 的单个事务本体；1213 死锁重试由外层包装处理。
func (m *mysqlStore) revokeEnrollment(ctx context.Context, deviceID string, credentialTTL time.Duration) (revokeResult, int64, error) {
	tx, err := m.db.BeginTx(ctx, nil)
	if err != nil {
		return revokeNotEnrolled, 0, err
	}
	defer func() { _ = tx.Rollback() }()

	// 首锁 device 行（与 putEnrollment 的 FOR UPDATE 相同）：并发 re-enroll 在此排队。
	// 行不存在 → 无 cardinality 变化，直接提交返回未注册。
	var enrolledAt time.Time
	err = tx.QueryRowContext(ctx,
		`SELECT enrolled_at FROM devices WHERE device_id = ? FOR UPDATE`, deviceID,
	).Scan(&enrolledAt)
	if errors.Is(err, sql.ErrNoRows) {
		return revokeNotEnrolled, 0, tx.Commit()
	}
	if err != nil {
		return revokeNotEnrolled, 0, err
	}
	// refresh 可在首次 enrollment 后任意时刻签发新的完整 TTL。以撤销时刻为上界
	// 起点，确保丢失 Pub/Sub 事件的其它实例在下一轮对账时仍能看到 tombstone 并关闭
	// 已建立连接；使用 EnrolledAt 会在老设备刚 refresh 后过早清除墓碑。
	now := time.Now()
	revokedAt := nextEnrollmentTime(now, &EnrolledDevice{EnrolledAt: enrolledAt})
	validUntil := now.Add(credentialTTL)
	// 墓碑与删除同一事务：要么都落地，要么都不落地。ensure 在删除前执行，其 COUNT 基准
	// 仍含待删行，随后递减 1 → 净结果 = 删除后正确计数（与 RemoveEnrollment 相同防漂移）。
	if err := ensureEnrollmentCounter(ctx, tx); err != nil {
		return revokeNotEnrolled, 0, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO revocations (device_id, revoked_at, valid_until)
		VALUES (?, ?, ?)
		ON DUPLICATE KEY UPDATE valid_until = GREATEST(valid_until, VALUES(valid_until))`,
		deviceID, revokedAt, validUntil,
	); err != nil {
		return revokeNotEnrolled, 0, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM devices WHERE device_id = ?`, deviceID); err != nil {
		return revokeNotEnrolled, 0, err
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE relay_meta SET meta_value = GREATEST(meta_value - 1, 0) WHERE meta_key = ?`,
		enrollmentCounterKey,
	); err != nil {
		return revokeNotEnrolled, 0, err
	}
	if err := tx.Commit(); err != nil {
		return revokeNotEnrolled, 0, err
	}
	return revokeOK, enrolledAt.UnixMicro(), nil
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
