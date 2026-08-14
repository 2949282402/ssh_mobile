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
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
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
	for _, stmt := range []string{"DELETE FROM revocations", "DELETE FROM devices"} {
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
		ProtocolVersion: 1,
		Platform:        "test",
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/devices/enroll", bytes.NewReader(body))
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

	credential, err := issueCredential([]byte(mysqlTestCredentialKey), "device-a", publicKey, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	authReq := httptest.NewRequest("GET", "/v1/connect", nil)
	authReq.Header.Set("Authorization", "Bearer "+credential)
	authReq.Header.Set("X-Relay-Nonce", nonce)
	authReq.Header.Set("X-Relay-Signature", base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, []byte("GET\n/v1/connect\n"+nonce)),
	))
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
	if result := server.replaceEnrollment("device-a", "key-a", "test", 1, time.Now()); result != enrollmentOK {
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
		{DeviceID: "device-a", PublicKey: "key-a", Platform: "test", ProtocolVersion: 1, EnrolledAt: time.Now()},
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
// stopped) rather than abandoning it.
func TestOpenServerClosesMySQLStoreOnRedisFailure(t *testing.T) {
	dsn := requireMySQLDSN(t)
	config := mysqlTestConfig(dsn)
	// A connection-refused port fails fast in Ping, exercising the
	// openRedisStore failure branch (which also closes its own client).
	config.RedisURL = "redis://127.0.0.1:1"

	if server, err := OpenServer(config); err == nil {
		server.Close()
		t.Fatal("expected OpenServer to fail when Redis is unreachable")
	}
	// The fix closes the MySQL store on this path; reopening the same DSN must
	// still succeed (no server-side state left corrupted).
	if _, err := openMySQLStore(context.Background(), dsn, config.MaxEnrolledDevices); err != nil {
		t.Fatalf("reopen mysql store after failed OpenServer: %v", err)
	}
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
