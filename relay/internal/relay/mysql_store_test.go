// MySQL-backed Storage integration tests.
//
// These require a live MySQL reached via RELAY_TEST_MYSQL_DSN (with
// parseTime=true&loc=UTC); without it they skip. They exercise the headline
// Phase-1 behavior: durable enrollment/revocation that survives a relay restart.

package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
)

const mysqlTestCredentialKey = "01234567890123456789012345678901"

func mysqlTestConfig(dsn string) Config {
	return Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
		StorageMode:     "mysql",
		DatabaseURL:     dsn,
		RedisURL:        os.Getenv("RELAY_TEST_REDIS_URL"),
		CredentialTTL:   time.Hour,
	}
}

func requireMySQLDSN(t *testing.T) string {
	t.Helper()
	dsn := os.Getenv("RELAY_TEST_MYSQL_DSN")
	if dsn == "" {
		t.Skip("RELAY_TEST_MYSQL_DSN not set; skipping MySQL integration test")
	}
	return dsn
}

func TestMySQLStoreCloseCancelsLifecycleAndIsIdempotent(t *testing.T) {
	db, err := sql.Open("mysql", "user:password@tcp(127.0.0.1:1)/relay?parseTime=true&loc=UTC")
	if err != nil {
		t.Fatal(err)
	}
	lifecycleCtx, lifecycleCancel := context.WithCancel(context.Background())
	store := &mysqlStore{
		db:              db,
		lifecycleCtx:    lifecycleCtx,
		lifecycleCancel: lifecycleCancel,
	}
	store.wg.Add(1)
	go store.pruneRevocationsLoop()

	const closers = 8
	errs := make(chan error, closers)
	var wg sync.WaitGroup
	for range closers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs <- store.Close()
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("close mysql store: %v", err)
		}
	}
	if !errors.Is(lifecycleCtx.Err(), context.Canceled) {
		t.Fatalf("lifecycle context was not canceled: %v", lifecycleCtx.Err())
	}
}

// requireMySQLFullStack 需要 MySQL 与 Redis：mysql 模式强制要求 Redis，因此打开
// 服务器的集成测试必须两者齐备。
func requireMySQLFullStack(t *testing.T) (string, string) {
	t.Helper()
	dsn := requireMySQLDSN(t)
	redisURL := os.Getenv("RELAY_TEST_REDIS_URL")
	if redisURL == "" {
		t.Skip("RELAY_TEST_REDIS_URL not set; skipping MySQL integration test (mysql mode requires Redis)")
	}
	return dsn, redisURL
}

func resetMySQLTestDB(t *testing.T, dsn string) {
	t.Helper()
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, stmt := range []string{"DELETE FROM relay_meta", "DELETE FROM revocations", "DELETE FROM devices"} {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("reset test database: %v", err)
		}
	}
}

// TestMySQLStoreRestartSurvival is the headline Phase-1 acceptance: a device
// enrolled before a restart keeps working after it, with no re-enrollment.
func TestMySQLStoreRestartSurvival(t *testing.T) {
	dsn, _ := requireMySQLFullStack(t)
	config := mysqlTestConfig(dsn)

	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	server, err := OpenServer(config)
	if err != nil {
		t.Fatalf("open server: %v", err)
	}
	resetMySQLTestDB(t, dsn)
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	body, _ := json.Marshal(enrollRequest{
		DeviceID:        "device-a",
		PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
		EnrollmentToken: "test-token",
		ProtocolVersion: RelayBootstrapProtocolVersion,
		Platform:        "test",
	})
	req := httptest.NewRequest(http.MethodPost, PathEnrollV2, bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("enroll failed: %d", rec.Code)
	}
	server.Close()

	// Simulate a restart: a fresh server instance over the same database.
	restarted, err := OpenServer(config)
	if err != nil {
		t.Fatalf("reopen server: %v", err)
	}
	defer restarted.Close()

	credential, err := issueCredential([]byte(mysqlTestCredentialKey), "device-a", publicKey, mustEnrollmentGeneration(t, restarted, "device-a"), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	authReq := httptest.NewRequest("GET", "/v2/control", nil)
	authReq.Header.Set("Authorization", "Bearer "+credential)
	setCurrentSignedDeviceProof(authReq.Header, http.MethodGet, "/v2/control", privateKey, nonce)
	if _, _, _, ok := restarted.authenticatedRequest(authReq); !ok {
		t.Fatal("credential was rejected after restart")
	}
}

// TestMySQLStoreRevocationSurvivesRestart verifies a revocation recorded before
// a restart still blocks the device afterwards.
func TestMySQLStoreRevocationSurvivesRestart(t *testing.T) {
	dsn, _ := requireMySQLFullStack(t)
	config := mysqlTestConfig(dsn)
	ctx := context.Background()

	server, err := OpenServer(config)
	if err != nil {
		t.Fatalf("open server: %v", err)
	}
	resetMySQLTestDB(t, dsn)
	if result := server.replaceEnrollment("device-a", "key-a", "test", RelayBootstrapProtocolVersion, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	if recorded, err := server.store.RecordRevocation(ctx, "device-a", time.Now().Add(time.Hour)); err != nil || !recorded {
		t.Fatalf("revoke failed: recorded=%v err=%v", recorded, err)
	}
	server.Close()

	restarted, err := OpenServer(config)
	if err != nil {
		t.Fatalf("reopen server: %v", err)
	}
	defer restarted.Close()
	if revoked, err := restarted.store.IsRevoked(ctx, "device-a", time.Now()); err != nil || !revoked {
		t.Fatalf("revocation did not survive restart: revoked=%v err=%v", revoked, err)
	}
}

// TestMySQLStoreSeedMigration verifies the one-time seed path used by the
// -seed-enrollments flag: seeded enrollments are durable across a restart.
func TestMySQLStoreSeedMigration(t *testing.T) {
	dsn, _ := requireMySQLFullStack(t)
	config := mysqlTestConfig(dsn)
	ctx := context.Background()

	server, err := OpenServer(config)
	if err != nil {
		t.Fatalf("open server: %v", err)
	}
	resetMySQLTestDB(t, dsn)
	enrollments := []EnrolledDevice{
		{DeviceID: "device-a", PublicKey: "key-a", Platform: "test", ProtocolVersion: RelayBootstrapProtocolVersion, EnrolledAt: time.Now()},
	}
	if err := server.SeedEnrollments(ctx, enrollments); err != nil {
		t.Fatalf("seed failed: %v", err)
	}
	server.Close()

	restarted, err := OpenServer(config)
	if err != nil {
		t.Fatalf("reopen server: %v", err)
	}
	defer restarted.Close()
	device, err := restarted.store.GetEnrollment(ctx, "device-a")
	if err != nil || device == nil {
		t.Fatalf("seeded enrollment missing after restart: err=%v", err)
	}
}

// TestOpenServerClosesMySQLStoreOnRedisFailure verifies the mysql-mode startup
// path does not leak the already-open MySQL store when Redis cannot be reached:
// openMySQLStore succeeds, openRedisStore fails, and OpenServer must return an
// error with the store closed (connection pool released, prune goroutine
// stopped) rather than abandoning it. The idle-connection count is a
// deterministic red-green assertion: without the fix the leaked pool holds its
// connections (Sleep state) and the count grows; with it, Close reclaims them
// before OpenServer returns.
func TestOpenServerClosesMySQLStoreOnRedisFailure(t *testing.T) {
	dsn := requireMySQLDSN(t)
	config := mysqlTestConfig(dsn)
	// A connection-refused port fails fast in Ping, exercising the
	// openRedisStore failure branch (which also closes its own client).
	config.RedisURL = "redis://127.0.0.1:1"

	dbName, err := mysql.ParseDSN(dsn)
	if err != nil {
		t.Fatal(err)
	}
	probe, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer probe.Close()
	baseline := countIdleConnections(t, probe, dbName.DBName)

	if server, err := OpenServer(config); err == nil {
		server.Close()
		t.Fatal("expected OpenServer to fail when Redis is unreachable")
	} else if !strings.Contains(err.Error(), "open redis store") {
		t.Fatalf("error should surface the redis open failure, got: %v", err)
	}
	if after := countIdleConnections(t, probe, dbName.DBName); after > baseline {
		t.Fatalf("failed OpenServer leaked %d idle MySQL connection(s) (before=%d after=%d)", after-baseline, baseline, after)
	}

	// Reopening the same DSN must still succeed (no server-side state corrupted).
	reopened, err := openMySQLStore(context.Background(), dsn, config.MaxEnrolledDevices)
	if err != nil {
		t.Fatalf("reopen mysql store after failed OpenServer: %v", err)
	}
	_ = reopened.Close()
}

// countIdleConnections returns the number of idle (Sleep) connections to the
// given database. A leaked sql.DB pool keeps its pooled connections in Sleep
// state until Close reclaims them, so a rising count across a failed OpenServer
// is a deterministic leak detector. The probe handle's own idle connections are
// present in both counts, so they cancel out of the delta.
func countIdleConnections(t *testing.T, probe *sql.DB, dbName string) int {
	t.Helper()
	var count int
	query := "SELECT COUNT(*) FROM information_schema.processlist WHERE db = ? AND command = 'Sleep'"
	if err := probe.QueryRow(query, dbName).Scan(&count); err != nil {
		t.Fatalf("count idle connections: %v", err)
	}
	return count
}

// TestMySQLStoreCloseFreshAndIdempotent pins the precondition the startup
// cleanup relies on: Close on a freshly opened, never-used store is safe, and
// stopping it twice is idempotent.
func TestMySQLStoreCloseFreshAndIdempotent(t *testing.T) {
	dsn := requireMySQLDSN(t)
	store, err := openMySQLStore(context.Background(), dsn, 100)
	if err != nil {
		t.Fatalf("open mysql store: %v", err)
	}
	if err := store.Close(); err != nil {
		t.Fatalf("first close: %v", err)
	}
	if err := store.Close(); err != nil {
		t.Fatalf("double close should be safe, got: %v", err)
	}
}

// TestMySQLStoreEnrollmentCapacityHardUnderConcurrency pins the #40 capacity
// regression: two different devices enrolling concurrently must not both slip
// past the MaxEnrolledDevices bound. The singleton relay_meta counter row
// (locked FOR UPDATE) serializes the capacity allocation, so with one slot left
// exactly one concurrent enroll succeeds and the other hits the bound — the
// bound stays a hard limit instead of degrading to a soft one under the
// per-device lock stripes.
func TestMySQLStoreEnrollmentCapacityHardUnderConcurrency(t *testing.T) {
	dsn := requireMySQLDSN(t)
	ctx := context.Background()
	store, err := openMySQLStore(ctx, dsn, 3)
	if err != nil {
		t.Fatalf("open mysql store: %v", err)
	}
	defer store.Close()
	resetMySQLTestDB(t, dsn)

	// Two devices take two of the three slots.
	for _, id := range []string{"device-a", "device-b"} {
		if result, _ := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: id, PublicKey: "key-" + id, EnrolledAt: time.Now()}); result != enrollmentOK {
			t.Fatalf("enroll %s failed: %v", id, result)
		}
	}

	// Two different devices race for the one remaining slot; the counter row
	// serializes them so exactly one succeeds. err 必须为 nil：PutEnrollment 在连续
	// 3 次 deadlock 后会返回 enrollmentResourceLimit + error，绝不能把真实的数据库
	// 故障误判为"正确命中容量"。
	type outcome struct {
		result enrollmentResult
		err    error
	}
	results := make(chan outcome, 2)
	var wg sync.WaitGroup
	for _, id := range []string{"device-c", "device-d"} {
		wg.Add(1)
		go func(deviceID string) {
			defer wg.Done()
			result, err := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: deviceID, PublicKey: "key-" + deviceID, EnrolledAt: time.Now()})
			results <- outcome{result: result, err: err}
		}(id)
	}
	wg.Wait()
	close(results)
	okCount, limitCount := 0, 0
	for o := range results {
		if o.err != nil {
			t.Fatalf("unexpected database error during capacity race: %v", o.err)
		}
		switch o.result {
		case enrollmentOK:
			okCount++
		case enrollmentResourceLimit:
			limitCount++
		default:
			t.Fatalf("unexpected enrollment result %v", o.result)
		}
	}
	if okCount != 1 || limitCount != 1 {
		t.Fatalf("capacity bound should be a hard limit under concurrency: ok=%d limit=%d", okCount, limitCount)
	}
	count, err := store.CountEnrollments(ctx)
	if err != nil || count != 3 {
		t.Fatalf("enrollment count should stay at the bound, got %d err=%v", count, err)
	}
}

// TestMySQLStoreRemoveFreesCapacitySlot verifies RemoveEnrollment decrements the
// capacity counter, so a removed device's slot can be taken by a new one.
func TestMySQLStoreRemoveFreesCapacitySlot(t *testing.T) {
	dsn := requireMySQLDSN(t)
	ctx := context.Background()
	store, err := openMySQLStore(ctx, dsn, 1)
	if err != nil {
		t.Fatalf("open mysql store: %v", err)
	}
	defer store.Close()
	resetMySQLTestDB(t, dsn)

	if result, _ := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: "device-a", PublicKey: "key-a", EnrolledAt: time.Now()}); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	if err := store.RemoveEnrollment(ctx, "device-a"); err != nil {
		t.Fatalf("remove failed: %v", err)
	}
	if result, _ := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: "device-b", PublicKey: "key-b", EnrolledAt: time.Now()}); result != enrollmentOK {
		t.Fatalf("slot was not freed after removal: %v", result)
	}
}

// TestMySQLStoreConcurrentLazyInitNoDeadlock pins the counter lazy-init path
// under concurrency: two NEW devices enrolling concurrently when the counter
// row is absent (fresh DB / reset) must both succeed. The pre-fix code took a
// gap lock with SELECT ... FOR UPDATE on the missing row and then deadlocked on
// INSERT IGNORE (InnoDB 1213), rolling one enroll back into a spurious resource
// limit.
func TestMySQLStoreConcurrentLazyInitNoDeadlock(t *testing.T) {
	dsn := requireMySQLDSN(t)
	ctx := context.Background()
	store, err := openMySQLStore(ctx, dsn, 10)
	if err != nil {
		t.Fatalf("open mysql store: %v", err)
	}
	defer store.Close()
	resetMySQLTestDB(t, dsn) // counter row deleted: both enrolls race the lazy init

	type outcome struct {
		result enrollmentResult
		err    error
	}
	results := make(chan outcome, 2)
	var wg sync.WaitGroup
	for _, id := range []string{"device-a", "device-b"} {
		wg.Add(1)
		go func(deviceID string) {
			defer wg.Done()
			result, err := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: deviceID, PublicKey: "key-" + deviceID, EnrolledAt: time.Now()})
			results <- outcome{result: result, err: err}
		}(id)
	}
	wg.Wait()
	close(results)
	okCount := 0
	for o := range results {
		if o.err != nil || o.result != enrollmentOK {
			t.Fatalf("enroll failed under concurrent lazy init: result=%v err=%v", o.result, o.err)
		}
		okCount++
	}
	if okCount != 2 {
		t.Fatalf("both new-device enrolls should succeed, ok=%d", okCount)
	}
}

// TestMySQLStoreRemoveDuringCounterInitNoDrift pins the #41 P1 regression:
// lazy-init of the enrollment counter racing a concurrent RemoveEnrollment must
// not leave the counter permanently ahead of COUNT(devices). T1 holds an
// explicit REPEATABLE READ snapshot from before T2 removes an existing device;
// ensureEnrollmentCounter therefore computes a stale baseline after T2 commits.
// T2 must initialize and decrement the current counter first, so T1's
// INSERT IGNORE cannot overwrite it and the final counter equals the device count.
// Pre-fix the remove left the missing row untouched and the counter was seeded
// from a stale baseline → permanent overcount (capacity exhausted early).
func TestMySQLStoreRemoveDuringCounterInitNoDrift(t *testing.T) {
	dsn := requireMySQLDSN(t)
	ctx := context.Background()
	store, err := openMySQLStore(ctx, dsn, 10)
	if err != nil {
		t.Fatalf("open mysql store: %v", err)
	}
	defer store.Close()
	resetMySQLTestDB(t, dsn)

	for _, id := range []string{"device-a", "device-b"} {
		if result, err := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: id, PublicKey: "key-" + id, EnrolledAt: time.Now()}); err != nil || result != enrollmentOK {
			t.Fatalf("enroll %s failed: result=%v err=%v", id, result, err)
		}
	}
	// 删除计数器行，强制下一次 cardinality 操作走懒初始化。
	deleteEnrollmentCounterRow(t, dsn)

	// The first plain SELECT fixes T1's read view while device-a and device-b
	// both exist and the counter row is still absent.
	snapshotTx, err := store.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead})
	if err != nil {
		t.Fatalf("begin stale-snapshot transaction: %v", err)
	}
	defer func() { _ = snapshotTx.Rollback() }()
	var staleCount int
	if err := snapshotTx.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices`).Scan(&staleCount); err != nil {
		t.Fatalf("establish stale device snapshot: %v", err)
	}
	if staleCount != 2 {
		t.Fatalf("stale snapshot count=%d, want 2", staleCount)
	}

	// T2 uses current state to initialize the counter to 2 and then decrements
	// it to 1 while T1 continues to see its old two-device snapshot.
	if err := store.RemoveEnrollment(ctx, "device-a"); err != nil {
		t.Fatalf("remove device-a: %v", err)
	}
	if err := ensureEnrollmentCounter(ctx, snapshotTx); err != nil {
		t.Fatalf("initialize counter from stale snapshot: %v", err)
	}
	if err := snapshotTx.Commit(); err != nil {
		t.Fatalf("commit stale-snapshot transaction: %v", err)
	}

	// Finish the T1 cardinality change through the production path. A stale
	// counter overwrite would increment 2→3 here while only two devices exist.
	if result, err := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: "device-c", PublicKey: "key-c", EnrolledAt: time.Now()}); err != nil || result != enrollmentOK {
		t.Fatalf("enroll device-c: result=%v err=%v", result, err)
	}

	count, err := store.CountEnrollments(ctx)
	if err != nil {
		t.Fatalf("count enrollments: %v", err)
	}
	if count != 2 {
		t.Fatalf("expected device-b + device-c = 2, got %d", count)
	}
	counter, err := readEnrollmentCounter(t, dsn)
	if err != nil {
		t.Fatalf("read counter: %v", err)
	}
	if counter != count {
		t.Fatalf("counter drift: relay_meta.enrollment_count=%d but COUNT(devices)=%d", counter, count)
	}
}

// TestMySQLStoreRemoveInitializesCounterWhenMissing verifies that a remove of an
// existing device initializes a missing counter row from its pre-delete count
// (no double-decrement), so the invariant counter == COUNT(devices) holds even
// when the counter row is absent (upgrade DB / reset).
func TestMySQLStoreRemoveInitializesCounterWhenMissing(t *testing.T) {
	dsn := requireMySQLDSN(t)
	ctx := context.Background()
	store, err := openMySQLStore(ctx, dsn, 10)
	if err != nil {
		t.Fatalf("open mysql store: %v", err)
	}
	defer store.Close()
	resetMySQLTestDB(t, dsn)

	for _, id := range []string{"device-a", "device-b"} {
		if result, err := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: id, PublicKey: "key-" + id, EnrolledAt: time.Now()}); err != nil || result != enrollmentOK {
			t.Fatalf("enroll %s failed: result=%v err=%v", id, result, err)
		}
	}
	deleteEnrollmentCounterRow(t, dsn)

	if err := store.RemoveEnrollment(ctx, "device-a"); err != nil {
		t.Fatalf("remove device-a: %v", err)
	}
	count, err := store.CountEnrollments(ctx)
	if err != nil || count != 1 {
		t.Fatalf("expected 1 device after remove, got %d err=%v", count, err)
	}
	counter, err := readEnrollmentCounter(t, dsn)
	if err != nil {
		t.Fatalf("read counter: %v", err)
	}
	if counter != 1 {
		t.Fatalf("remove should initialize counter to post-remove count, got %d", counter)
	}
}

// TestMySQLStoreOpenInitializesCounterFromExistingDevices pins the openMySQLStore
// startup init: opening a store over a DB that already has devices but no
// counter row (upgrade) seeds the counter from the current count, so serving
// never starts without the row.
func TestMySQLStoreOpenInitializesCounterFromExistingDevices(t *testing.T) {
	dsn := requireMySQLDSN(t)
	ctx := context.Background()

	store, err := openMySQLStore(ctx, dsn, 10)
	if err != nil {
		t.Fatalf("open mysql store: %v", err)
	}
	for _, id := range []string{"device-a", "device-b"} {
		if result, err := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: id, PublicKey: "key-" + id, EnrolledAt: time.Now()}); err != nil || result != enrollmentOK {
			t.Fatalf("enroll %s failed: result=%v err=%v", id, result, err)
		}
	}
	store.Close()
	deleteEnrollmentCounterRow(t, dsn)

	reopened, err := openMySQLStore(ctx, dsn, 10)
	if err != nil {
		t.Fatalf("reopen mysql store: %v", err)
	}
	defer reopened.Close()
	counter, err := readEnrollmentCounter(t, dsn)
	if err != nil {
		t.Fatalf("read counter: %v", err)
	}
	if counter != 2 {
		t.Fatalf("open should initialize counter from existing devices, got %d", counter)
	}
}

func deleteEnrollmentCounterRow(t *testing.T, dsn string) {
	t.Helper()
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`DELETE FROM relay_meta WHERE meta_key = ?`, enrollmentCounterKey); err != nil {
		t.Fatalf("delete counter row: %v", err)
	}
}

func readEnrollmentCounter(t *testing.T, dsn string) (int, error) {
	t.Helper()
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return 0, err
	}
	defer db.Close()
	var value int
	err = db.QueryRow(`SELECT meta_value FROM relay_meta WHERE meta_key = ?`, enrollmentCounterKey).Scan(&value)
	return value, err
}

const (
	mysqlRevokeGateTable    = "relay_test_revoke_gate"
	mysqlRevokeGateDeviceID = "device-revoke-gate"
)

func cleanupMySQLRevokeGate(ctx context.Context, db *sql.DB) error {
	if _, err := db.ExecContext(ctx, `DROP TABLE IF EXISTS `+mysqlRevokeGateTable); err != nil {
		return fmt.Errorf("drop revoke gate table: %w", err)
	}
	return nil
}

func installMySQLRevokeGate(ctx context.Context, db *sql.DB) error {
	if _, err := db.ExecContext(ctx, `CREATE TABLE `+mysqlRevokeGateTable+` (
  gate_id   TINYINT      NOT NULL PRIMARY KEY,
  device_id VARCHAR(128) NOT NULL,
  CONSTRAINT relay_test_revoke_gate_device_fk
    FOREIGN KEY (device_id) REFERENCES devices (device_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`); err != nil {
		return fmt.Errorf("create revoke gate table: %w", err)
	}
	if _, err := db.ExecContext(ctx,
		`INSERT INTO `+mysqlRevokeGateTable+` (gate_id, device_id) VALUES (1, ?)`,
		mysqlRevokeGateDeviceID,
	); err != nil {
		return fmt.Errorf("seed revoke gate row: %w", err)
	}
	return nil
}

func waitForMySQLRevokeTombstone(ctx context.Context, db *sql.DB) error {
	tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadUncommitted, ReadOnly: true})
	if err != nil {
		return fmt.Errorf("begin revoke tombstone observer: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		var tombstones int
		if err := tx.QueryRowContext(ctx,
			`SELECT COUNT(*) FROM revocations WHERE device_id = ?`,
			mysqlRevokeGateDeviceID,
		).Scan(&tombstones); err != nil {
			return fmt.Errorf("read uncommitted revoke tombstone: %w", err)
		}
		if tombstones == 1 {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

// TestMySQLStoreRevokeEnrollmentAtomic verifies RevokeEnrollment is a durable
// atomic unit: after revokeOK the device row is gone, the revocation tombstone
// is present with the credential-bound expiry computed inside the transaction,
// and the capacity counter is decremented. A second revoke of the same device
// and a revoke of a never-enrolled device both report revokeNotEnrolled.
func TestMySQLStoreRevokeEnrollmentAtomic(t *testing.T) {
	dsn := requireMySQLDSN(t)
	ctx := context.Background()
	store, err := openMySQLStore(ctx, dsn, 10)
	if err != nil {
		t.Fatalf("open mysql store: %v", err)
	}
	defer store.Close()
	resetMySQLTestDB(t, dsn)

	enrolledAt := time.Now().Add(-time.Hour).Truncate(time.Microsecond) // DATETIME(6) 精度
	if result, err := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: "device-a", PublicKey: "key-a", EnrolledAt: enrolledAt}); err != nil || result != enrollmentOK {
		t.Fatalf("enroll failed: result=%v err=%v", result, err)
	}

	revokedAfter := time.Now()
	outcome, generation, err := store.RevokeEnrollment(ctx, "device-a", time.Hour)
	revokedBefore := time.Now()
	if err != nil || outcome != revokeOK {
		t.Fatalf("revoke failed: outcome=%v err=%v", outcome, err)
	}
	if generation != enrolledAt.UnixMicro() {
		t.Fatalf("revoked generation=%d, want %d", generation, enrolledAt.UnixMicro())
	}
	if device, err := store.GetEnrollment(ctx, "device-a"); err != nil || device != nil {
		t.Fatalf("device should be removed after revoke: %+v err=%v", device, err)
	}
	expiry, present, err := store.RevocationExpiry(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("tombstone should be present after revoke: present=%v err=%v", present, err)
	}
	// MySQL DATETIME(6) rounds to microsecond precision, so allow a small margin
	// around the process-side call window.
	if expiry.Before(revokedAfter.Add(time.Hour-time.Millisecond)) ||
		expiry.After(revokedBefore.Add(time.Hour+time.Millisecond)) {
		t.Fatalf("tombstone bound = %v, want revoke-time window [%v, %v]", expiry,
			revokedAfter.Add(time.Hour), revokedBefore.Add(time.Hour))
	}
	if count, _ := store.CountEnrollments(ctx); count != 0 {
		t.Fatalf("enrollment count should be 0 after revoke, got %d", count)
	}
	if counter, err := readEnrollmentCounter(t, dsn); err != nil || counter != 0 {
		t.Fatalf("counter should be 0 after revoke, got %d err=%v", counter, err)
	}

	if outcome, _, err := store.RevokeEnrollment(ctx, "device-a", time.Hour); err != nil || outcome != revokeNotEnrolled {
		t.Fatalf("double revoke should report not enrolled: outcome=%v err=%v", outcome, err)
	}
	if outcome, _, err := store.RevokeEnrollment(ctx, "device-never", time.Hour); err != nil || outcome != revokeNotEnrolled {
		t.Fatalf("revoke of a never-enrolled device should report not enrolled: outcome=%v err=%v", outcome, err)
	}
}

func TestMySQLStoreReenrollmentAdvancesPastRevokedGeneration(t *testing.T) {
	dsn := requireMySQLDSN(t)
	ctx := context.Background()
	store, err := openMySQLStore(ctx, dsn, 10)
	if err != nil {
		t.Fatalf("open mysql store: %v", err)
	}
	defer store.Close()
	resetMySQLTestDB(t, dsn)

	fixedTime := time.Now().UTC().Truncate(time.Microsecond)
	first := &EnrolledDevice{DeviceID: "device-a", PublicKey: "key-a", EnrolledAt: fixedTime}
	if result, err := store.PutEnrollment(ctx, first); err != nil || result != enrollmentOK {
		t.Fatalf("first enrollment: result=%v err=%v", result, err)
	}
	outcome, revokedGeneration, err := store.RevokeEnrollment(ctx, "device-a", time.Hour)
	if err != nil || outcome != revokeOK {
		t.Fatalf("revoke: outcome=%v err=%v", outcome, err)
	}
	second := &EnrolledDevice{DeviceID: "device-a", PublicKey: "key-a", EnrolledAt: fixedTime}
	if result, err := store.PutEnrollment(ctx, second); err != nil || result != enrollmentOK {
		t.Fatalf("re-enrollment: result=%v err=%v", result, err)
	}
	if second.EnrolledAt.UnixMicro() <= revokedGeneration {
		t.Fatalf("re-enrollment generation=%d did not advance past revoked=%d", second.EnrolledAt.UnixMicro(), revokedGeneration)
	}
}

// TestMySQLStoreRevokeReenrollLinearizesCrossInstance verifies the atomic revoke
// closes the cross-instance tear window. Two store calls on one shared database
// (no process-local shard lock) race: RevokeEnrollment vs PutEnrollment with a
// new key, exactly the multi-instance interleaving the per-device lock stripe
// cannot serialize. The outcome must always be a valid linearization — either
// the re-enroll won (enrolled, not revoked) or the revoke won (removed,
// tombstone in force). The lost-enrollment state (removed AND not revoked) and
// the both-on state (enrolled AND revoked) must never appear, and the capacity
// counter must track COUNT(devices). The old compound flow (RecordRevocation +
// RemoveEnrollment as separate transactions) let the revoke's delete run after
// the re-enroll cleared the tombstone → removed AND not revoked.
func TestMySQLStoreRevokeReenrollLinearizesCrossInstance(t *testing.T) {
	dsn := requireMySQLDSN(t)
	ctx := context.Background()
	store, err := openMySQLStore(ctx, dsn, 10)
	if err != nil {
		t.Fatalf("open mysql store: %v", err)
	}
	defer store.Close()
	resetMySQLTestDB(t, dsn)

	const deviceID = "device-a"
	for i := 0; i < 30; i++ {
		if result, err := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: deviceID, PublicKey: "key-original", EnrolledAt: time.Now()}); err != nil || result != enrollmentOK {
			t.Fatalf("iteration %d: seed enroll failed: result=%v err=%v", i, result, err)
		}
		var wg sync.WaitGroup
		wg.Add(2)
		go func(round int) {
			defer wg.Done()
			_, _, _ = store.RevokeEnrollment(ctx, deviceID, time.Hour)
		}(i)
		go func(round int) {
			defer wg.Done()
			_, _ = store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: deviceID, PublicKey: fmt.Sprintf("key-new-%d", round), EnrolledAt: time.Now()})
		}(i)
		wg.Wait()

		device, _ := store.GetEnrollment(ctx, deviceID)
		revoked, _ := store.IsRevoked(ctx, deviceID, time.Now())
		// 有效线性化只有两种：(注册, 未吊销) 或 (未注册, 已吊销)。撕裂态
		// (未注册, 未吊销) 与 (注册, 已吊销) 必须永不出现。
		if (device == nil) != revoked {
			t.Fatalf("iteration %d: invalid linearization: enrolled=%v revoked=%v", i, device != nil, revoked)
		}
		count, err := store.CountEnrollments(ctx)
		if err != nil {
			t.Fatalf("iteration %d: count enrollments: %v", i, err)
		}
		counter, err := readEnrollmentCounter(t, dsn)
		if err != nil {
			t.Fatalf("iteration %d: read counter: %v", i, err)
		}
		if counter != count {
			t.Fatalf("iteration %d: counter drift: relay_meta.enrollment_count=%d but COUNT(devices)=%d", i, counter, count)
		}

		// Reset 到干净注册态供下一轮：device 存在则先删（重新入册新 key 否则冲突），
		// 墓碑若在则被下一轮 PutEnrollment 清除。
		if device != nil {
			if err := store.RemoveEnrollment(ctx, deviceID); err != nil {
				t.Fatalf("iteration %d: reset remove: %v", i, err)
			}
		}
	}
}

// TestMySQLStoreRevokeHoldsDeviceLockThroughTombstone pins, deterministically,
// the serialization the single-transaction revoke provides. A test-only child
// table supplies a natural foreign-key gate: an uncommitted child-row DELETE
// makes the device DELETE wait for referential-integrity resolution. A READ
// UNCOMMITTED observer first proves the tombstone INSERT happened; at that
// database seam, a NOWAIT locking read must report the device row still locked
// by RevokeEnrollment's transaction. This needs no production hook or elevated
// MySQL TRIGGER/SUPER privilege.
func TestMySQLStoreRevokeHoldsDeviceLockThroughTombstone(t *testing.T) {
	dsn := requireMySQLDSN(t)
	ctx := context.Background()
	store, err := openMySQLStore(ctx, dsn, 10)
	if err != nil {
		t.Fatalf("open mysql store: %v", err)
	}
	gateDB, err := sql.Open("mysql", dsn)
	if err != nil {
		_ = store.Close()
		t.Fatalf("open revoke gate database: %v", err)
	}
	var blockerTx *sql.Tx
	var revokeCancel context.CancelFunc
	var revokeDone chan struct{}
	t.Cleanup(func() {
		if revokeCancel != nil {
			revokeCancel()
		}
		if blockerTx != nil {
			_ = blockerTx.Rollback()
		}
		if revokeDone != nil {
			select {
			case <-revokeDone:
			case <-time.After(5 * time.Second):
				t.Errorf("timed out waiting for revoke during cleanup")
			}
		}
		_ = store.Close()
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cleanupCancel()
		if err := cleanupMySQLRevokeGate(cleanupCtx, gateDB); err != nil {
			t.Errorf("cleanup revoke gate: %v", err)
		}
		_ = gateDB.Close()
	})

	cleanupCtx, cleanupCancel := context.WithTimeout(ctx, 5*time.Second)
	if err := cleanupMySQLRevokeGate(cleanupCtx, gateDB); err != nil {
		cleanupCancel()
		t.Fatalf("remove stale revoke gate: %v", err)
	}
	cleanupCancel()
	resetMySQLTestDB(t, dsn)

	if result, err := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: mysqlRevokeGateDeviceID, PublicKey: "key-original", EnrolledAt: time.Now()}); err != nil || result != enrollmentOK {
		t.Fatalf("seed enroll failed: result=%v err=%v", result, err)
	}
	setupCtx, setupCancel := context.WithTimeout(ctx, 5*time.Second)
	if err := installMySQLRevokeGate(setupCtx, gateDB); err != nil {
		setupCancel()
		t.Fatalf("install revoke gate: %v", err)
	}
	setupCancel()

	blockerTx, err = gateDB.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin revoke gate blocker: %v", err)
	}
	result, err := blockerTx.ExecContext(ctx, `DELETE FROM `+mysqlRevokeGateTable+` WHERE gate_id = 1`)
	if err != nil {
		t.Fatalf("delete revoke gate child row: %v", err)
	}
	if affected, err := result.RowsAffected(); err != nil || affected != 1 {
		t.Fatalf("delete revoke gate child row affected=%d err=%v", affected, err)
	}

	revokeDone = make(chan struct{})
	var revokeOutcome revokeResult
	var revokeErr error
	revokeCtx, cancelRevoke := context.WithTimeout(ctx, 15*time.Second)
	revokeCancel = cancelRevoke
	go func() {
		defer close(revokeDone)
		revokeOutcome, _, revokeErr = store.RevokeEnrollment(revokeCtx, mysqlRevokeGateDeviceID, time.Hour)
	}()

	signalCtx, signalCancel := context.WithTimeout(ctx, 10*time.Second)
	if err := waitForMySQLRevokeTombstone(signalCtx, gateDB); err != nil {
		signalCancel()
		t.Fatalf("wait for revoke tombstone: %v", err)
	}
	signalCancel()

	// The uncommitted tombstone proves revoke advanced past its INSERT. Its
	// device DELETE cannot pass the uncommitted child-row deletion, and revoke
	// must still own the device row lock from its initial FOR UPDATE.
	probeTx, err := gateDB.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin device lock probe: %v", err)
	}
	var lockedDeviceID string
	err = probeTx.QueryRowContext(ctx,
		`SELECT device_id FROM devices WHERE device_id = ? FOR UPDATE NOWAIT`,
		mysqlRevokeGateDeviceID,
	).Scan(&lockedDeviceID)
	_ = probeTx.Rollback()
	var mysqlErr *mysql.MySQLError
	if !errors.As(err, &mysqlErr) || mysqlErr.Number != 3572 {
		t.Fatalf("device row was not locked through revoke DELETE: err=%v", err)
	}

	if err := blockerTx.Commit(); err != nil {
		t.Fatalf("release revoke gate: %v", err)
	}
	blockerTx = nil
	select {
	case <-revokeDone:
	case <-time.After(10 * time.Second):
		t.Fatal("revoke did not complete after releasing delete gate")
	}
	if revokeErr != nil || revokeOutcome != revokeOK {
		t.Fatalf("revoke failed: outcome=%v err=%v", revokeOutcome, revokeErr)
	}

	// Re-enrollment after the atomic revoke is a valid later generation and
	// clears the tombstone without any lost-enrollment middle state.
	if result, err := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: mysqlRevokeGateDeviceID, PublicKey: "key-new", EnrolledAt: time.Now()}); err != nil || result != enrollmentOK {
		t.Fatalf("re-enroll after revoke: result=%v err=%v", result, err)
	}
	device, _ := store.GetEnrollment(ctx, mysqlRevokeGateDeviceID)
	revoked, _ := store.IsRevoked(ctx, mysqlRevokeGateDeviceID, time.Now())
	if device == nil || device.PublicKey != "key-new" || revoked {
		t.Fatalf("expected re-enroll to win after revoke commits: device=%+v revoked=%v", device, revoked)
	}
	count, err := store.CountEnrollments(ctx)
	if err != nil {
		t.Fatalf("count enrollments: %v", err)
	}
	counter, err := readEnrollmentCounter(t, dsn)
	if err != nil {
		t.Fatalf("read counter: %v", err)
	}
	if counter != count || counter != 1 {
		t.Fatalf("counter drift: relay_meta.enrollment_count=%d COUNT(devices)=%d", counter, count)
	}
}

// TestMySQLStoreRevokeInitializesCounterWhenMissing verifies a revoke over an
// upgrade DB (devices present, counter row absent) initializes the counter from
// its pre-delete snapshot — no double-decrement — while still writing the
// tombstone, so the invariant counter == COUNT(devices) holds.
func TestMySQLStoreRevokeInitializesCounterWhenMissing(t *testing.T) {
	dsn := requireMySQLDSN(t)
	ctx := context.Background()
	store, err := openMySQLStore(ctx, dsn, 10)
	if err != nil {
		t.Fatalf("open mysql store: %v", err)
	}
	defer store.Close()
	resetMySQLTestDB(t, dsn)

	for _, id := range []string{"device-a", "device-b"} {
		if result, err := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: id, PublicKey: "key-" + id, EnrolledAt: time.Now()}); err != nil || result != enrollmentOK {
			t.Fatalf("enroll %s failed: result=%v err=%v", id, result, err)
		}
	}
	deleteEnrollmentCounterRow(t, dsn)

	if outcome, _, err := store.RevokeEnrollment(ctx, "device-a", time.Hour); err != nil || outcome != revokeOK {
		t.Fatalf("revoke failed: outcome=%v err=%v", outcome, err)
	}
	count, err := store.CountEnrollments(ctx)
	if err != nil || count != 1 {
		t.Fatalf("expected 1 device after revoke, got %d err=%v", count, err)
	}
	counter, err := readEnrollmentCounter(t, dsn)
	if err != nil {
		t.Fatalf("read counter: %v", err)
	}
	if counter != 1 {
		t.Fatalf("revoke should initialize counter to post-revoke count, got %d", counter)
	}
	if _, present, _ := store.RevocationExpiry(ctx, "device-a"); !present {
		t.Fatal("tombstone missing after revoke initialized the counter")
	}
}

// TestMySQLStoreConcurrentNewDeviceEnrollBurstNoDeadlock verifies the enrollment
// deadlock retry survives a burst of concurrent NEW-device enrollments into an
// initially empty devices table (fresh DB: counter row also absent, so the
// lazy-init gap interaction is exercised too). Every new key lands in one shared
// gap, so the SELECT FOR UPDATE gap locks + INSERT insert-intention locks
// deadlock (1213) and must be absorbed by the retry's exponential + jitter
// backoff — a thin linear budget exhausts under this concurrency and misreports
// transient contention as a capacity limit. All enrolls must succeed and the
// counter must end exactly at COUNT(devices).
func TestMySQLStoreConcurrentNewDeviceEnrollBurstNoDeadlock(t *testing.T) {
	dsn := requireMySQLDSN(t)
	ctx := context.Background()
	store, err := openMySQLStore(ctx, dsn, 100)
	if err != nil {
		t.Fatalf("open mysql store: %v", err)
	}
	defer store.Close()
	resetMySQLTestDB(t, dsn)

	// 校准：N 路并发全部挤进空表同一 gap，足以让旧预算（3 次线性短退避）必红，新预算
	// （5 次指数+抖动）稳绿。
	const n = 8
	var wg sync.WaitGroup
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(round int) {
			defer wg.Done()
			id := fmt.Sprintf("device-%02d", round)
			result, err := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: id, PublicKey: "key-" + id, EnrolledAt: time.Now()})
			if err != nil || result != enrollmentOK {
				errs <- fmt.Errorf("enroll %s: result=%v err=%v", id, result, err)
				return
			}
			errs <- nil
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}

	count, err := store.CountEnrollments(ctx)
	if err != nil {
		t.Fatalf("count enrollments: %v", err)
	}
	if count != n {
		t.Fatalf("expected %d devices enrolled, got %d", n, count)
	}
	counter, err := readEnrollmentCounter(t, dsn)
	if err != nil {
		t.Fatalf("read counter: %v", err)
	}
	if counter != count {
		t.Fatalf("counter drift: relay_meta.enrollment_count=%d COUNT(devices)=%d", counter, count)
	}
}
