// Regression tests for code-review package A fixes: revocation integrity,
// glob-injection-safe nonce clearing, and presence lifecycle.

package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// TestRefreshRejectsRevokedButStillEnrolledDevice verifies a device whose
// enrollment survived a revocation (e.g. the DELETE failed) cannot refresh a
// fresh credential: the tombstone alone must block it.
func TestRefreshRejectsRevokedButStillEnrolledDevice(t *testing.T) {
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

	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	if result := server.replaceEnrollment("device-a", encodedKey, "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	server.devicesMutex.Lock()
	recorded, err := server.store.RecordRevocation(context.Background(), "device-a", time.Now().Add(time.Hour))
	server.devicesMutex.Unlock()
	if err != nil || !recorded {
		t.Fatalf("revoke failed: recorded=%v err=%v", recorded, err)
	}
	server.devicesMutex.Lock()
	device, _ := server.store.GetEnrollment(context.Background(), "device-a")
	server.devicesMutex.Unlock()
	if device == nil {
		t.Fatal("enrollment unexpectedly missing")
	}

	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{8}, 32))
	body, _ := json.Marshal(refreshRequest{
		DeviceID:  "device-a",
		PublicKey: encodedKey,
		Nonce:     nonce,
		Signature: base64.RawURLEncoding.EncodeToString(
			ed25519.Sign(privateKey, []byte("POST\n/v1/devices/refresh\n"+nonce)),
		),
	})
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	request := httptest.NewRequest(http.MethodPost, "/v1/devices/refresh", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, request)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("revoked-but-enrolled device refresh: expected 401, got %d", rec.Code)
	}
}

// failingRemoveStore wraps a working store whose enrollment deletion fails,
// modeling a transient MySQL DELETE failure during revocation.
type failingRemoveStore struct {
	Storage
}

func (failingRemoveStore) RemoveEnrollment(context.Context, string) error {
	return errors.New("injected delete failure")
}

// TestAdminRevokeReturnsErrorWhenEnrollmentDeleteFails verifies the revoke
// handler reports 500 instead of a false 204 when the enrollment row cannot be
// removed, so the operator knows the revocation did not fully land.
func TestAdminRevokeReturnsErrorWhenEnrollmentDeleteFails(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
		CredentialTTL:   time.Hour,
	})
	defer server.Close()
	if result := server.replaceEnrollment("device-a", "key-a", "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	server.store = failingRemoveStore{Storage: server.store}

	request := httptest.NewRequest(http.MethodPost, "/api/admin/v1/devices/device-a/revoke", nil)
	request.SetPathValue("deviceId", "device-a")
	rec := httptest.NewRecorder()
	server.adminRevokeDevice(rec, request)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500 when enrollment delete fails, got %d", rec.Code)
	}
}

// TestDisconnectDeviceClearsPresence verifies the revoke/kick disconnect path
// removes the device's own lease instead of leaving a stale online entry.
func TestDisconnectDeviceClearsPresence(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()

	ctx := context.Background()
	peer := injectPeer(server.hub, "device-a")
	if _, _, err := server.cache.TakePresence(ctx, "device-a", peer.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	server.hub.disconnectDevice("device-a")

	if _, present, _ := server.cache.GetPresence(ctx, "device-a"); present {
		t.Fatal("presence retained after disconnectDevice")
	}
}

// TestDisconnectDeviceDoesNotClearForeignPresence verifies the disconnect path
// releases only the lease owned by the local connection: a lease already taken
// over by another connection (e.g. on another instance) survives, so an old
// connection can never erase a newer one's presence (P0 cross-instance bug).
func TestDisconnectDeviceDoesNotClearForeignPresence(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()

	ctx := context.Background()
	// A foreign connection owns the lease (simulates another instance).
	if _, _, err := server.cache.TakePresence(ctx, "device-a", "foreign-conn", Presence{InstanceID: "i2"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	// The local hub still has its own (superseded) peer for the device.
	injectPeer(server.hub, "device-a")
	server.hub.disconnectDevice("device-a")

	presence, present, err := server.cache.GetPresence(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("foreign-owned presence was erased by the local disconnect: present=%v err=%v", present, err)
	}
	if presence.ConnectionID != "foreign-conn" {
		t.Fatalf("presence owner changed: %q", presence.ConnectionID)
	}
}

// gatePresenceStore blocks the first TakePresence until released, to
// deterministically interleave concurrent same-device lease claims.
type gatePresenceStore struct {
	Cache
	once    sync.Once
	blocked chan struct{}
	release chan struct{}
}

func newGatePresenceStore(cache Cache) *gatePresenceStore {
	return &gatePresenceStore{Cache: cache, blocked: make(chan struct{}), release: make(chan struct{})}
}

func (g *gatePresenceStore) TakePresence(ctx context.Context, deviceID, connID string, p Presence, ttl time.Duration) (Presence, bool, error) {
	g.once.Do(func() {
		close(g.blocked)
		<-g.release
	})
	return g.Cache.TakePresence(ctx, deviceID, connID, p, ttl)
}

// TestHubAddSerializesConcurrentSameDeviceClaims pins the admission-ordering
// race: two connections for the same device claiming concurrently must land
// their lease in establishment order, so the newer connection can never be
// kicked by a stale, slower claim from the older (already replaced) one. The
// first claim is gated; the second must wait at the admission lock, not race it.
func TestHubAddSerializesConcurrentSameDeviceClaims(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
		MaxConnections:  10,
	})
	defer server.Close()

	gate := newGatePresenceStore(server.cache)
	server.cache = gate
	server.hub.presence = gate
	ctx := context.Background()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	httpServer := httptest.NewServer(mux)
	defer httpServer.Close()

	credential, _, privateKey := enrollViaHTTP(t, httpServer.URL, "device-a", "test-token")

	// A1 connects; its lease claim is gated (blocks before the ready frame).
	connA1 := dialDeviceNoReady(t, httpServer.URL, credential, "device-a", 0x10, privateKey)
	defer connA1.Close()
	<-gate.blocked

	// A2 connects while A1's claim is in flight: it must block at the admission
	// lock (not reach the map or Redis) until A1's claim completes.
	connA2 := dialDeviceNoReady(t, httpServer.URL, credential, "device-a", 0x11, privateKey)
	defer connA2.Close()
	time.Sleep(100 * time.Millisecond)
	server.hub.mutex.Lock()
	current := server.hub.peers["device-a"]
	server.hub.mutex.Unlock()
	if current == nil || current.connectionID == "" {
		t.Fatal("A1 is not in the hub map while its claim is in flight")
	}

	close(gate.release)

	// A2's admission completes only after A1's claim; read A2's ready frame.
	var ready controlFrame
	_ = connA2.SetReadDeadline(time.Now().Add(3 * time.Second))
	if err := connA2.ReadJSON(&ready); err != nil || ready.Type != "ready" || ready.DeviceID != "device-a" {
		t.Fatalf("A2 was not admitted after serialized claim: %+v (%v)", ready, err)
	}
	_ = connA2.SetReadDeadline(time.Time{})

	// Final state: A2 is the hub's current peer and owns the lease; A1 is closed.
	server.hub.mutex.Lock()
	current = server.hub.peers["device-a"]
	server.hub.mutex.Unlock()
	presence, present, err := gate.GetPresence(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("presence missing: present=%v err=%v", present, err)
	}
	if current == nil || presence.ConnectionID != current.connectionID {
		t.Fatalf("lease owner should be the newest connection (current peer %v), got %q", current, presence.ConnectionID)
	}

	// A1's superseded socket must be closed (replaced by A2).
	deadline := time.Now().Add(3 * time.Second)
	closed := false
	for time.Now().Before(deadline) {
		_ = connA1.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		if _, _, err := connA1.ReadMessage(); err != nil {
			closed = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !closed {
		t.Fatal("A1 was not closed after being replaced by A2")
	}
}

// TestHubAddAfterCloseRegistersNoWorkers pins the shutdown lifecycle race: if
// the hub closes while a connection's lease claim is still in flight, the claim
// must complete to a rejected admission (add returns false) WITHOUT registering
// write/read workers — otherwise close()'s Wait() could return before the
// workers exist, and the server would tear down Redis/MySQL underneath live
// goroutines. The nil socket is safe because a correct add() never starts
// workers on a peer that was closed mid-claim. The claim itself must also be
// unwound: the lease TakePresence wrote after close() must be released, or the
// device would linger "online" with no live connection behind it.
func TestHubAddAfterCloseRegistersNoWorkers(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	gate := newGatePresenceStore(server.cache)
	server.cache = gate
	server.hub.presence = gate

	peer := &peer{
		deviceID:     "device-a",
		connectionID: "conn-a",
		outbound:     make(chan outboundFrame, 8),
		done:         make(chan struct{}),
	}

	addDone := make(chan bool, 1)
	go func() { addDone <- server.hub.add(peer) }()
	<-gate.blocked // the claim is in flight; the peer is in the map

	server.hub.close() // closed=true, peers cleared, peer closed

	close(gate.release) // release the in-flight claim

	if result := <-addDone; result {
		t.Fatal("add succeeded after hub close (workers would outlive shutdown)")
	}
	select {
	case <-peer.done:
	default:
		t.Fatal("peer was not closed after rejected admission")
	}
	// A regressed add() would have started write/read on the nil socket here and
	// panicked; reaching this line means no workers were registered.
	// The in-flight claim wrote a lease after close(); add() must have released
	// it, otherwise the device is reported online with no live connection.
	_, present, err := gate.GetPresence(context.Background(), "device-a")
	if err != nil {
		t.Fatal(err)
	}
	if present {
		t.Fatal("rejected admission resurrected presence after hub close")
	}
}

// TestHubAddRejectedAfterDisconnectDoesNotResurrectPresence pins the lease
// lifecycle across a revoke/kick admission race: if the device is disconnected
// while a new connection's lease claim is in flight, the claim completes to a
// rejected admission (the hub no longer has the peer) and must release the
// lease it wrote — the device must not linger "online" after the disconnect,
// exactly as with the shutdown path above.
func TestHubAddRejectedAfterDisconnectDoesNotResurrectPresence(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	gate := newGatePresenceStore(server.cache)
	server.cache = gate
	server.hub.presence = gate

	peer := &peer{
		deviceID:     "device-a",
		connectionID: "conn-a",
		outbound:     make(chan outboundFrame, 8),
		done:         make(chan struct{}),
	}

	addDone := make(chan bool, 1)
	go func() { addDone <- server.hub.add(peer) }()
	<-gate.blocked // the claim is in flight; the peer is in the map

	// Revoke/kick the device while the claim is blocked: the hub removes the
	// peer and attempts a release that misses (the lease is not written yet).
	server.hub.disconnectDevice("device-a")

	close(gate.release) // release the in-flight claim

	if result := <-addDone; result {
		t.Fatal("add succeeded after the device was disconnected")
	}
	select {
	case <-peer.done:
	default:
		t.Fatal("peer was not closed after rejected admission")
	}
	_, present, err := gate.GetPresence(context.Background(), "device-a")
	if err != nil {
		t.Fatal(err)
	}
	if present {
		t.Fatal("rejected admission resurrected presence after disconnect")
	}
}

// TestDisconnectConnectionTargetsSpecificConnection verifies the directed
// disconnect used by connection.replaced: only the exact connection ID is
// closed and released; a stale/delayed ID is a no-op and cannot kick a newer
// connection or erase its lease.
func TestDisconnectConnectionTargetsSpecificConnection(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	peer := injectPeer(server.hub, "device-a") // connID "conn-device-a"
	if _, _, err := server.cache.TakePresence(ctx, "device-a", peer.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}

	server.hub.disconnectConnection("device-a", "stale-conn")
	server.hub.mutex.Lock()
	_, present := server.hub.peers["device-a"]
	server.hub.mutex.Unlock()
	if !present {
		t.Fatal("stale directed disconnect removed the current peer")
	}
	if _, present, _ := server.cache.GetPresence(ctx, "device-a"); !present {
		t.Fatal("stale directed disconnect released the lease")
	}

	server.hub.disconnectConnection("device-a", peer.connectionID)
	server.hub.mutex.Lock()
	_, present = server.hub.peers["device-a"]
	server.hub.mutex.Unlock()
	if present {
		t.Fatal("directed disconnect did not remove the matching peer")
	}
	if _, present, _ := server.cache.GetPresence(ctx, "device-a"); present {
		t.Fatal("directed disconnect did not release the lease")
	}
	select {
	case <-peer.done:
	default:
		t.Fatal("matching peer was not closed")
	}
}

// TestConnectionReplacedEventDisconnectsTargetedConnection verifies
// handleRelayEvent routes connection.replaced to a directed disconnect: the
// event for a stale connection ID is ignored; the matching one disconnects.
func TestConnectionReplacedEventDisconnectsTargetedConnection(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	peer := injectPeer(server.hub, "device-a")
	if _, _, err := server.cache.TakePresence(ctx, "device-a", peer.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}

	server.handleRelayEvent(RelayEvent{Type: eventConnectionReplaced, DeviceID: "device-a", OldConnectionID: "stale"})
	server.hub.mutex.Lock()
	_, present := server.hub.peers["device-a"]
	server.hub.mutex.Unlock()
	if !present {
		t.Fatal("replaced event for a stale connection ID disconnected the current peer")
	}

	server.handleRelayEvent(RelayEvent{Type: eventConnectionReplaced, DeviceID: "device-a", OldConnectionID: peer.connectionID})
	server.hub.mutex.Lock()
	_, present = server.hub.peers["device-a"]
	server.hub.mutex.Unlock()
	if present {
		t.Fatal("replaced event did not disconnect the matching peer")
	}
}

// TestRedisStoreClearNoncesIgnoresGlobDeviceID verifies a device ID containing
// Redis glob metacharacters cannot wipe another device's nonce keys.
func TestRedisStoreClearNoncesIgnoresGlobDeviceID(t *testing.T) {
	ctx := context.Background()
	store, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_ = store.ClearDeviceNonces(ctx, "device-a")
	_ = store.ClearDeviceNonces(ctx, "x*y")

	expiry := time.Now().Add(time.Hour)
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "nonce-a1", expiry); replayed {
		t.Fatal("fresh nonce reported replay")
	}
	// A glob-bearing device ID clearing its own keys must not touch device-a.
	if err := store.ClearDeviceNonces(ctx, "x*y"); err != nil {
		t.Fatal(err)
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "nonce-a1", expiry); !replayed {
		t.Fatal("glob device ID cleared another device's nonce")
	}
	_ = store.ClearDeviceNonces(ctx, "device-a")
}

// TestRedisStoreNonceCap verifies the per-device active-nonce cap is enforced
// in Redis, matching the in-memory 128-entry bound.
func TestRedisStoreNonceCap(t *testing.T) {
	ctx := context.Background()
	store, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_ = store.ClearDeviceNonces(ctx, "cap-device")

	expiry := time.Now().Add(time.Hour)
	for i := 0; i < maxProofNoncesPerDevice; i++ {
		if replayed, _ := store.ConsumeNonce(ctx, "cap-device", fmt.Sprintf("n-%d", i), expiry); replayed {
			t.Fatalf("nonce %d unexpectedly rejected before the cap", i)
		}
	}
	if replayed, _ := store.ConsumeNonce(ctx, "cap-device", "n-over", expiry); !replayed {
		t.Fatal("nonce beyond the cap was accepted")
	}
	_ = store.ClearDeviceNonces(ctx, "cap-device")
}

// TestRedisStoreNonceExpiryFreesCap is the P0 regression: with the old SET-based
// store, nonce keys expired but their SET members never did, so a device was
// permanently locked out after 128 cumulative nonces since the last clear. A
// ZSET prunes expired members, so the cap counts only *live* nonces and the
// 129th succeeds once earlier ones have expired.
func TestRedisStoreNonceExpiryFreesCap(t *testing.T) {
	ctx := context.Background()
	store, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_ = store.ClearDeviceNonces(ctx, "ttl-device")

	// A per-iteration 1s expiry gives the 128 EVAL round-trips a comfortable
	// window so the fill always lands while every nonce is still live, even on
	// a slow CI runner; the poll loop below then waits out the expiry.
	for i := 0; i < maxProofNoncesPerDevice; i++ {
		if replayed, _ := store.ConsumeNonce(ctx, "ttl-device", fmt.Sprintf("t-%d", i), time.Now().Add(time.Second)); replayed {
			t.Fatalf("nonce %d unexpectedly rejected before the cap", i)
		}
	}
	if replayed, _ := store.ConsumeNonce(ctx, "ttl-device", "t-over", time.Now().Add(time.Hour)); !replayed {
		t.Fatal("nonce beyond the cap was accepted while all nonces are live")
	}

	// Poll rather than sleep: the over-cap rejection does not record the nonce,
	// so retrying the same fresh nonce is safe and never flakes on CI timing.
	deadline := time.Now().Add(5 * time.Second)
	for {
		if replayed, _ := store.ConsumeNonce(ctx, "ttl-device", "t-fresh", time.Now().Add(time.Hour)); !replayed {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("expired nonces were not pruned; cap never freed (P0 regression)")
		}
		time.Sleep(50 * time.Millisecond)
	}
	if replayed, _ := store.ConsumeNonce(ctx, "ttl-device", "t-0", time.Now().Add(time.Hour)); replayed {
		t.Fatal("expired nonce still treated as replay (P0 regression)")
	}
	_ = store.ClearDeviceNonces(ctx, "ttl-device")
}
