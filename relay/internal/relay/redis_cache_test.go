// Redis-backed Cache integration tests and the fail-open degradation contract.
//
// The Redis tests require a live Redis reached via RELAY_TEST_REDIS_URL; without
// it they skip. TestAuthFailsOpenWhenCacheUnavailable needs no external service.

package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

func requireRedisURL(t *testing.T) string {
	t.Helper()
	url := os.Getenv("RELAY_TEST_REDIS_URL")
	if url == "" {
		t.Skip("RELAY_TEST_REDIS_URL not set; skipping Redis integration test")
	}
	return url
}

// cleanupRedisTestKeys removes keys this test file may have left behind.
func cleanupRedisTestKeys(t *testing.T, store *redisStore) {
	t.Helper()
	ctx := context.Background()
	_ = store.DeletePresence(ctx, "device-a")
	_ = store.ClearDeviceNonces(ctx, "device-a")
	_ = store.DeleteAdminSession(ctx, "tok-1")
}

func TestRedisStorePresenceNonceAndAdmin(t *testing.T) {
	ctx := context.Background()
	store, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatalf("open redis: %v", err)
	}
	defer store.Close()
	cleanupRedisTestKeys(t, store)

	if err := store.SetPresence(ctx, "device-a", Presence{InstanceID: "i1", RemoteAddr: "1.2.3.4"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	presence, present, err := store.GetPresence(ctx, "device-a")
	if err != nil || !present || presence.InstanceID != "i1" {
		t.Fatalf("presence round-trip failed: %+v present=%v err=%v", presence, present, err)
	}
	if err := store.DeletePresence(ctx, "device-a"); err != nil {
		t.Fatal(err)
	}
	if _, present, _ := store.GetPresence(ctx, "device-a"); present {
		t.Fatal("presence not deleted")
	}

	expiry := time.Now().Add(time.Minute)
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "nonce-1", expiry); replayed {
		t.Fatal("fresh nonce reported replay")
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "nonce-1", expiry); !replayed {
		t.Fatal("replayed nonce accepted")
	}
	if err := store.ClearDeviceNonces(ctx, "device-a"); err != nil {
		t.Fatal(err)
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "nonce-1", expiry); replayed {
		t.Fatal("nonce still present after clear")
	}

	if err := store.SetAdminSession(ctx, "tok-1", time.Minute); err != nil {
		t.Fatal(err)
	}
	if ok, _ := store.AdminSessionExists(ctx, "tok-1"); !ok {
		t.Fatal("admin session not found")
	}
	if err := store.DeleteAdminSession(ctx, "tok-1"); err != nil {
		t.Fatal(err)
	}
	if ok, _ := store.AdminSessionExists(ctx, "tok-1"); ok {
		t.Fatal("admin session not deleted")
	}
}

func TestRedisStoreEventBus(t *testing.T) {
	ctx := context.Background()
	store, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatalf("open redis: %v", err)
	}
	defer store.Close()

	subCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	received := make(chan RelayEvent, 4)
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = store.runEventSubscriber(subCtx, func(event RelayEvent) {
			received <- event
		})
	}()
	defer func() {
		cancel()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatal("event subscriber did not stop")
		}
	}()

	event := RelayEvent{Type: eventDeviceRevoked, DeviceID: "device-a", Time: time.Now().UnixMilli()}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if err := store.Publish(ctx, event); err != nil {
			t.Fatal(err)
		}
		select {
		case got := <-received:
			if got.DeviceID != "device-a" || got.Type != eventDeviceRevoked {
				t.Fatalf("unexpected event: %+v", got)
			}
			return
		default:
			time.Sleep(50 * time.Millisecond)
		}
	}
	t.Fatal("event was not received by the subscriber")
}

// erroringCache wraps a working cache and fails the state-plane calls, modeling
// a Redis outage. The device-plane (enrollment/revocation/nonce) nonce failure
// must NOT block authentication: that is the fail-open contract.
type erroringCache struct {
	Cache
}

func (erroringCache) ConsumeNonce(context.Context, string, string, time.Time) (bool, error) {
	return false, errors.New("cache unavailable")
}
func (erroringCache) SetPresence(context.Context, string, Presence, time.Duration) error {
	return errors.New("cache unavailable")
}
func (erroringCache) GetPresence(context.Context, string) (Presence, bool, error) {
	return Presence{}, false, errors.New("cache unavailable")
}
func (erroringCache) DeletePresence(context.Context, string) error {
	return errors.New("cache unavailable")
}
func (erroringCache) Publish(context.Context, RelayEvent) error {
	return errors.New("cache unavailable")
}

// TestAuthFailsOpenWhenCacheUnavailable verifies that device authentication
// still succeeds when the cache (nonce replay protection) is unavailable: MySQL
// enrollment/revocation remains the authority and nonce protection degrades.
func TestAuthFailsOpenWhenCacheUnavailable(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
		CredentialTTL:   time.Hour,
	})
	defer server.Close()
	server.cache = erroringCache{Cache: server.cache}

	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	if result := server.replaceEnrollment("device-a", encodedKey, "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	credential, err := issueCredential([]byte(mysqlTestCredentialKey), "device-a", publicKey, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{5}, 32))
	request := httptest.NewRequest("GET", "/v1/connect", nil)
	request.Header.Set("Authorization", "Bearer "+credential)
	request.Header.Set("X-Relay-Nonce", nonce)
	request.Header.Set("X-Relay-Signature", base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, []byte("GET\n/v1/connect\n"+nonce)),
	))
	if _, _, _, ok := server.authenticatedRequest(request); !ok {
		t.Fatal("authentication failed closed when the cache was unavailable")
	}
}

// TestMySQLRedisFullStackOnlineStats exercises the mysql+redis wiring end to
// end: enrollment is durable in MySQL, presence lives in Redis, and the admin
// online stats are driven by presence.
func TestMySQLRedisFullStackOnlineStats(t *testing.T) {
	mysqlDSN := requireMySQLDSN(t)
	redisURL := requireRedisURL(t)
	config := mysqlTestConfig(mysqlDSN)
	config.RedisURL = redisURL
	ctx := context.Background()

	server, err := OpenServer(config)
	if err != nil {
		t.Fatalf("open server: %v", err)
	}
	defer server.Close()
	resetMySQLTestDB(t, mysqlDSN)

	if result := server.replaceEnrollment("device-a", "key-a", "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	if server.cache.(*redisStore) == nil {
		t.Fatal("server cache is not the redis store")
	}
	// Simulate a connected device: presence written to Redis.
	if err := server.cache.SetPresence(ctx, "device-a", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	items, err := server.adminDeviceSnapshot()
	if err != nil || len(items) != 1 || !items[0].Online {
		t.Fatalf("admin snapshot should show the device online: err=%v items=%+v", err, items)
	}
	if err := server.cache.DeletePresence(ctx, "device-a"); err != nil {
		t.Fatal(err)
	}
	items, err = server.adminDeviceSnapshot()
	if err != nil || len(items) != 1 || items[0].Online {
		t.Fatalf("admin snapshot should show the device offline after presence removal: err=%v items=%+v", err, items)
	}
}
