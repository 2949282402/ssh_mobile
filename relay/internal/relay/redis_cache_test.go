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
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func TestRedisClientOptionsEnforceContextSocketAndPoolBounds(t *testing.T) {
	opts, err := redisClientOptions(
		"redis://localhost:6379/0?read_timeout=-1s&write_timeout=-1s&max_retries=9&pool_size=999",
		Config{RedisPassword: "test-independent-password"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if !opts.ContextTimeoutEnabled {
		t.Fatal("Redis commands do not honor caller deadlines")
	}
	if opts.MaxRetries != -1 || opts.DialTimeout != redisDialTimeout || opts.ReadTimeout != redisCommandTimeout || opts.WriteTimeout != redisCommandTimeout {
		t.Fatalf("Redis command bounds were not enforced: %+v", opts)
	}
	if opts.PoolTimeout != redisPoolTimeout || opts.PoolSize != redisPoolSize || opts.MaxActiveConns != redisMaxActiveConns {
		t.Fatalf("Redis pool bounds were not enforced: %+v", opts)
	}
	if opts.Password != "test-independent-password" {
		t.Fatal("independent Redis password did not override URL credentials")
	}
}

func TestRedisClientHonorsCallerDeadlineAgainstBlackhole(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		connection, acceptErr := listener.Accept()
		if acceptErr == nil {
			accepted <- connection
		}
	}()

	opts, err := redisClientOptions("redis://"+listener.Addr().String()+"/0", Config{})
	if err != nil {
		t.Fatal(err)
	}
	client := redis.NewClient(opts)
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	started := time.Now()
	if err := client.Ping(ctx).Err(); err == nil {
		t.Fatal("blackholed Redis command unexpectedly succeeded")
	}
	if elapsed := time.Since(started); elapsed >= 500*time.Millisecond {
		t.Fatalf("caller deadline was ignored; Redis command took %s", elapsed)
	}
	select {
	case connection := <-accepted:
		_ = connection.Close()
	case <-time.After(time.Second):
		t.Fatal("blackhole listener never accepted the Redis connection")
	}
}

func requireRedisURL(t *testing.T) string {
	t.Helper()
	url := os.Getenv("RELAY_TEST_REDIS_URL")
	if url == "" {
		t.Skip("RELAY_TEST_REDIS_URL not set; skipping Redis integration test")
	}
	return url
}

// cleanupRedisTestKeys removes keys this test file may have left behind.
// Presence uses the unconditional force-delete helper because tests may leave a
// lease owned by an arbitrary connection; the CAS ReleasePresence would miss.
func cleanupRedisTestKeys(t *testing.T, store *redisStore) {
	t.Helper()
	ctx := context.Background()
	_ = store.forceDeletePresence(ctx, "device-a")
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

	if _, _, err := store.TakePresence(ctx, "device-a", "conn-1", Presence{InstanceID: "i1", RemoteAddr: "1.2.3.4"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	presence, present, err := store.GetPresence(ctx, "device-a")
	if err != nil || !present || presence.InstanceID != "i1" || presence.ConnectionID != "conn-1" {
		t.Fatalf("presence round-trip failed: %+v present=%v err=%v", presence, present, err)
	}
	if ok, _ := store.RenewPresence(ctx, "device-a", "conn-1", presence, time.Minute); !ok {
		t.Fatal("owner could not renew its own lease")
	}
	if released, _ := store.ReleasePresence(ctx, "device-a", "conn-1"); !released {
		t.Fatal("owner could not release its own lease")
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
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "already-expired", time.Now().Add(-time.Second)); !replayed {
		t.Fatal("already-expired nonce window failed open")
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

// TestRedisStorePresenceLeaseSemantics pins the three Step-2 contracts at the
// store level: (1) the newest TakePresence wins and becomes the sole owner, so a
// dual connection does not flap the presence identity; (2) only the owner can
// renew, so a superseded connection's heartbeat cannot keep it "online";
// (3) ReleasePresence is CAS'd, so an old connection can never erase a newer
// one's lease.
func TestRedisStorePresenceLeaseSemantics(t *testing.T) {
	ctx := context.Background()
	store, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatalf("open redis: %v", err)
	}
	defer store.Close()
	if err := store.forceDeletePresence(ctx, "lease-device"); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = store.forceDeletePresence(ctx, "lease-device") }()

	if _, _, err := store.TakePresence(ctx, "lease-device", "conn-a", Presence{InstanceID: "i-a"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	// A second connection takes the lease over (cross-instance reconnect).
	if _, _, err := store.TakePresence(ctx, "lease-device", "conn-b", Presence{InstanceID: "i-b"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	presence, present, err := store.GetPresence(ctx, "lease-device")
	if err != nil || !present || presence.ConnectionID != "conn-b" || presence.InstanceID != "i-b" {
		t.Fatalf("newest connection should own the lease: %+v present=%v err=%v", presence, present, err)
	}
	// Superseded connection cannot renew or release.
	if ok, _ := store.RenewPresence(ctx, "lease-device", "conn-a", Presence{InstanceID: "i-a"}, time.Minute); ok {
		t.Fatal("superseded connection renewed a foreign lease")
	}
	if released, _ := store.ReleasePresence(ctx, "lease-device", "conn-a"); released {
		t.Fatal("superseded connection released a foreign lease")
	}
	if _, present, _ := store.GetPresence(ctx, "lease-device"); !present {
		t.Fatal("foreign lease was erased by a non-owner release")
	}
	// Current owner can renew and finally release.
	if ok, _ := store.RenewPresence(ctx, "lease-device", "conn-b", presence, time.Minute); !ok {
		t.Fatal("owner could not renew its own lease")
	}
	if released, _ := store.ReleasePresence(ctx, "lease-device", "conn-b"); !released {
		t.Fatal("owner could not release its own lease")
	}
	if _, present, _ := store.GetPresence(ctx, "lease-device"); present {
		t.Fatal("lease still present after owner release")
	}
}

// TestRedisStoreDiscoveryOwnerCas verifies the cross-instance discovery CAS:
// a discovery write requires the writer to still own the presence lease, so a
// superseded connection cannot overwrite the newer connection's discovery
// (Redis Lua atomic — the single-instance placeholder era had an unconditional
// SET here). Also verifies ListOnlinePeers requires matching owners.
func TestRedisStoreDiscoveryOwnerCas(t *testing.T) {
	ctx := context.Background()
	store, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatalf("open redis: %v", err)
	}
	defer store.Close()
	deviceID := "discovery-cas-device"
	if err := store.forceDeletePresence(ctx, deviceID); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_, _ = store.ReleaseDiscovery(ctx, deviceID, "conn-a")
		_, _ = store.ReleaseDiscovery(ctx, deviceID, "conn-b")
		_ = store.forceDeletePresence(ctx, deviceID)
	}()

	// 无 presence 时不能写 discovery。
	if err := store.TakeDiscovery(ctx, deviceID, "conn-a", Discovery{DeviceID: deviceID, Revision: 1}, time.Minute); !errors.Is(err, errDiscoveryNotOwner) {
		t.Fatalf("discovery write without presence should be rejected, got %v", err)
	}
	// conn-a 拥有 presence：可写 discovery。
	if _, _, err := store.TakePresence(ctx, deviceID, "conn-a", Presence{InstanceID: "i-a"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := store.TakeDiscovery(ctx, deviceID, "conn-a", Discovery{DeviceID: deviceID, Revision: 1}, time.Minute); err != nil {
		t.Fatalf("owner discovery write failed: %v", err)
	}
	// 新连接接管 presence：旧连接 conn-a 的写入被拒绝（CAS）。
	if _, _, err := store.TakePresence(ctx, deviceID, "conn-b", Presence{InstanceID: "i-b"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := store.TakeDiscovery(ctx, deviceID, "conn-a", Discovery{DeviceID: deviceID, Revision: 2}, time.Minute); !errors.Is(err, errDiscoveryNotOwner) {
		t.Fatalf("superseded connection write must be rejected, got %v", err)
	}
	d, present, err := store.GetDiscovery(ctx, deviceID)
	if err != nil || !present || d.Revision != 1 || d.ConnectionID != "conn-a" {
		t.Fatalf("stale write must not overwrite discovery: %+v present=%v err=%v", d, present, err)
	}
	// 当前 owner conn-b 可以写入并覆盖。
	if err := store.TakeDiscovery(ctx, deviceID, "conn-b", Discovery{DeviceID: deviceID, Revision: 3}, time.Minute); err != nil {
		t.Fatalf("current owner write failed: %v", err)
	}
	// owner 不匹配（presence=conn-b、discovery 旧 owner conn-a）时 ListOnlinePeers 不
	// 计入；owner 一致后才计入。
	store.mustForceDiscoveryOwner(t, deviceID, "conn-a", 9)
	online, err := store.ListOnlinePeers(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, present := online[deviceID]; present {
		t.Fatalf("owner-mismatched device must not be listed online: %+v", online)
	}
	if err := store.TakeDiscovery(ctx, deviceID, "conn-b", Discovery{DeviceID: deviceID, Revision: 9}, time.Minute); err != nil {
		t.Fatal(err)
	}
	online, err = store.ListOnlinePeers(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if got := online[deviceID]; got.Revision != 9 || got.ConnectionID != "conn-b" {
		t.Fatalf("owner-matched device should be online: %+v", online)
	}
}

// mustForceDiscoveryOwner 直接写 Redis discovery 键（绕过 CAS），用于构造 owner 与
// presence 不一致的离线态。仅测试隔离用。
func (store *redisStore) mustForceDiscoveryOwner(t *testing.T, deviceID, connID string, revision uint32) {
	t.Helper()
	data, err := json.Marshal(Discovery{DeviceID: deviceID, ConnectionID: connID, Revision: revision})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.client.Set(context.Background(), store.discoveryKey(deviceID), data, time.Minute).Err(); err != nil {
		t.Fatal(err)
	}
}

// TestRedisStorePresenceLegacyEntryNotRenewed verifies the upgrade path: a
// legacy presence JSON without a connection_id is treated as foreign, so it is
// not renewed (the pre-upgrade connection self-heals) and the next TakePresence
// overwrites it with the lease format.
func TestRedisStorePresenceLegacyEntryNotRenewed(t *testing.T) {
	ctx := context.Background()
	store, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatalf("open redis: %v", err)
	}
	defer store.Close()
	if err := store.forceDeletePresence(ctx, "legacy-device"); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = store.forceDeletePresence(ctx, "legacy-device") }()

	if err := store.client.Set(ctx, store.presenceKey("legacy-device"), `{"instance_id":"old","last_seen":"2026-01-01T00:00:00Z"}`, time.Minute).Err(); err != nil {
		t.Fatal(err)
	}
	if ok, _ := store.RenewPresence(ctx, "legacy-device", "conn-x", Presence{InstanceID: "new"}, time.Minute); ok {
		t.Fatal("legacy entry without an owner was renewed as if owned")
	}
	if _, _, err := store.TakePresence(ctx, "legacy-device", "conn-x", Presence{InstanceID: "new"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	presence, present, err := store.GetPresence(ctx, "legacy-device")
	if err != nil || !present || presence.ConnectionID != "conn-x" {
		t.Fatalf("lease format not established over the legacy entry: %+v present=%v err=%v", presence, present, err)
	}
	if ok, _ := store.RenewPresence(ctx, "legacy-device", "conn-x", presence, time.Minute); !ok {
		t.Fatal("owner could not renew after taking over a legacy entry")
	}

	// A non-object JSON value (here JSON null) is also treated as foreign rather
	// than raising, and self-heals on the next TakePresence.
	if err := store.forceDeletePresence(ctx, "legacy-device"); err != nil {
		t.Fatal(err)
	}
	if err := store.client.Set(ctx, store.presenceKey("legacy-device"), "null", time.Minute).Err(); err != nil {
		t.Fatal(err)
	}
	if ok, _ := store.RenewPresence(ctx, "legacy-device", "conn-x", Presence{InstanceID: "new"}, time.Minute); ok {
		t.Fatal("non-object presence value was renewed as if owned")
	}
}

// TestRedisStoreGetPresencesSkipsCorruptEntry pins the batch fail-open
// granularity: a corrupt (non-JSON) presence value must be skipped rather than
// surfaced as an error, so one bad key cannot blank the whole admin batch.
func TestRedisStoreGetPresencesSkipsCorruptEntry(t *testing.T) {
	ctx := context.Background()
	store, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatalf("open redis: %v", err)
	}
	defer store.Close()
	_ = store.forceDeletePresence(ctx, "corrupt-a")
	_ = store.forceDeletePresence(ctx, "corrupt-b")
	defer func() {
		_ = store.forceDeletePresence(ctx, "corrupt-a")
		_ = store.forceDeletePresence(ctx, "corrupt-b")
	}()

	if _, _, err := store.TakePresence(ctx, "corrupt-a", "conn-a", Presence{InstanceID: "i"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := store.client.Set(ctx, store.presenceKey("corrupt-b"), "not-json{{", time.Minute).Err(); err != nil {
		t.Fatal(err)
	}
	result, err := store.GetPresences(ctx, []string{"corrupt-a", "corrupt-b"})
	if err != nil {
		t.Fatalf("GetPresences should skip a corrupt entry, got error: %v", err)
	}
	if len(result) != 1 {
		t.Fatalf("expected only the live device, got %d: %v", len(result), result)
	}
	if _, ok := result["corrupt-b"]; ok {
		t.Fatal("corrupt entry was included in batch presence")
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
func (erroringCache) TakePresence(context.Context, string, string, Presence, time.Duration) (Presence, bool, error) {
	return Presence{}, false, errors.New("cache unavailable")
}
func (erroringCache) RenewPresence(context.Context, string, string, Presence, time.Duration) (bool, error) {
	return false, errors.New("cache unavailable")
}
func (erroringCache) ReleasePresence(context.Context, string, string) (bool, error) {
	return false, errors.New("cache unavailable")
}
func (erroringCache) GetPresence(context.Context, string) (Presence, bool, error) {
	return Presence{}, false, errors.New("cache unavailable")
}
func (erroringCache) GetPresences(context.Context, []string) (map[string]Presence, error) {
	return nil, errors.New("cache unavailable")
}
func (erroringCache) TakeDiscovery(context.Context, string, string, Discovery, time.Duration) error {
	return errors.New("cache unavailable")
}
func (erroringCache) RenewDiscovery(context.Context, string, string, time.Duration) (bool, error) {
	return false, errors.New("cache unavailable")
}
func (erroringCache) ReleaseDiscovery(context.Context, string, string) (bool, error) {
	return false, errors.New("cache unavailable")
}
func (erroringCache) GetDiscovery(context.Context, string) (Discovery, bool, error) {
	return Discovery{}, false, errors.New("cache unavailable")
}
func (erroringCache) GetDiscoveries(context.Context, []string) (map[string]Discovery, error) {
	return nil, errors.New("cache unavailable")
}
func (erroringCache) ListOnlinePeers(context.Context) (map[string]Discovery, error) {
	return nil, errors.New("cache unavailable")
}
func (erroringCache) CreateReservation(context.Context, Reservation) error {
	return errors.New("cache unavailable")
}
func (erroringCache) GetReservation(context.Context, string) (Reservation, bool, error) {
	return Reservation{}, false, errors.New("cache unavailable")
}
func (erroringCache) RenewReservation(context.Context, string, time.Duration) (bool, error) {
	return false, errors.New("cache unavailable")
}
func (erroringCache) DeleteReservation(context.Context, string) error {
	return errors.New("cache unavailable")
}
func (erroringCache) Publish(context.Context, RelayEvent) error {
	return errors.New("cache unavailable")
}

// TestAuthFailsClosedWhenCacheUnavailable verifies that device authentication
// rejects the request when the nonce replay-protection cache is unavailable.
// Accepting here would turn a transient cache outage into a replay window.
func TestAuthFailsClosedWhenCacheUnavailable(t *testing.T) {
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
	if result := server.replaceEnrollment("device-a", encodedKey, "test", RelayBootstrapProtocolVersion, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	credential, err := issueCredential([]byte(mysqlTestCredentialKey), "device-a", publicKey, mustEnrollmentGeneration(t, server, "device-a"), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{5}, 32))
	request := httptest.NewRequest("GET", "/v2/control", nil)
	request.Header.Set("Authorization", "Bearer "+credential)
	setCurrentSignedDeviceProof(request.Header, http.MethodGet, "/v2/control", privateKey, nonce)
	if _, _, code, ok := server.authenticatedRequest(request); ok || code != relayErrorAuthenticationFailed {
		t.Fatalf("authentication did not fail closed when the cache was unavailable: ok=%v code=%d", ok, code)
	}
}

// TestAdminSnapshotFailsOpenWhenPresenceUnavailable verifies the admin device
// snapshot stays 200 (fail-open) when the presence cache is unavailable, but
// surfaces the degraded state explicitly: presence_available=false tells the
// frontend that online status is unknown, NOT that every device is offline —
// the old code silently mapped "unknown" to "all offline".
func TestAdminSnapshotFailsOpenWhenPresenceUnavailable(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
		AdminUser:       "test-admin",
		AdminPassword:   "test-password-123",
	})
	defer server.Close()
	if result := server.replaceEnrollment("device-a", "key-a", "test", RelayBootstrapProtocolVersion, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	server.cache = erroringCache{Cache: server.cache}

	items, presenceAvailable, err := server.adminDeviceSnapshot()
	if err != nil {
		t.Fatalf("admin snapshot should fail open when presence is unavailable: %v", err)
	}
	if presenceAvailable {
		t.Fatal("snapshot must flag presence as unavailable when the cache errors")
	}
	if len(items) != 1 || items[0].Online {
		t.Fatalf("devices should report offline with presence_available=false: %+v", items)
	}

	// The HTTP response carries the degraded flag so the frontend can tell
	// "unknown" apart from "genuinely offline".
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	loginBody, _ := json.Marshal(map[string]string{"username": "test-admin", "password": "test-password-123"})
	loginRequest := httptest.NewRequest(http.MethodPost, "/api/admin/v1/auth/login", bytes.NewReader(loginBody))
	loginRequest.Header.Set("Content-Type", "application/json")
	loginResponse := httptest.NewRecorder()
	mux.ServeHTTP(loginResponse, loginRequest)
	if loginResponse.Code != http.StatusOK {
		t.Fatalf("admin login failed: %d", loginResponse.Code)
	}
	cookie := loginResponse.Result().Cookies()[0]
	request := httptest.NewRequest(http.MethodGet, "/api/admin/v1/devices", nil)
	request.AddCookie(cookie)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, request)
	if rec.Code != http.StatusOK {
		t.Fatalf("devices endpoint should stay 200, got %d", rec.Code)
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte(`"presence_available":false`)) {
		t.Fatalf("devices response must carry presence_available=false, body=%s", rec.Body.String())
	}
}

// TestAdminOverviewSnapshotFailsOpenWhenPresenceUnavailable mirrors the devices
// snapshot test for the overview endpoint: under a failing presence cache the
// snapshot still returns 200 (fail-open) with presence_available=false and
// online=0 — the flag distinguishes "unknown" from "all offline" in the overview
// path too, not just the devices list.
func TestAdminOverviewSnapshotFailsOpenWhenPresenceUnavailable(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
		AdminUser:       "test-admin",
		AdminPassword:   "test-password-123",
	})
	defer server.Close()
	if result := server.replaceEnrollment("device-a", "key-a", "test", RelayBootstrapProtocolVersion, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	server.cache = erroringCache{Cache: server.cache}

	snapshot, err := server.adminOverviewSnapshot()
	if err != nil {
		t.Fatalf("admin overview should fail open when presence is unavailable: %v", err)
	}
	if snapshot.PresenceAvailable {
		t.Fatal("overview must flag presence as unavailable when the cache errors")
	}
	if snapshot.Devices.Online != 0 {
		t.Fatalf("overview should report online=0 with presence_available=false, got %d", snapshot.Devices.Online)
	}
	if snapshot.Devices.Enrolled != 1 {
		t.Fatalf("enrolled count must stay accurate, got %d", snapshot.Devices.Enrolled)
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

	if result := server.replaceEnrollment("device-a", "key-a", "test", RelayBootstrapProtocolVersion, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	if server.cache.(*redisStore) == nil {
		t.Fatal("server cache is not the redis store")
	}
	// Simulate a connected device: presence lease written to Redis.
	if _, _, err := server.cache.TakePresence(ctx, "device-a", "conn-1", Presence{InstanceID: "i1", RemoteAddr: "203.0.113.5:9000"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	items, presenceAvailable, err := server.adminDeviceSnapshot()
	if err != nil || !presenceAvailable || len(items) != 1 || !items[0].Online || items[0].RemoteAddr != "203.0.113.5:9000" {
		t.Fatalf("admin snapshot should show the device online with its lease address: err=%v avail=%v items=%+v", err, presenceAvailable, items)
	}
	if released, err := server.cache.ReleasePresence(ctx, "device-a", "conn-1"); err != nil || !released {
		t.Fatalf("release presence: released=%v err=%v", released, err)
	}
	items, presenceAvailable, err = server.adminDeviceSnapshot()
	if err != nil || !presenceAvailable || len(items) != 1 || items[0].Online {
		t.Fatalf("admin snapshot should show the device offline after presence removal: err=%v avail=%v items=%+v", err, presenceAvailable, items)
	}
}
