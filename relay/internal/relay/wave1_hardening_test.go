package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// TestRevokeFailsClosedWhenTombstoneStoreSaturated verifies the revocation
// store rejects new revocations at capacity instead of dropping an in-force
// tombstone, and that the failed revocation leaves the device enrolled.
func TestRevokeFailsClosedWhenTombstoneStoreSaturated(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:      []byte("01234567890123456789012345678901"),
		EnrollmentToken:    "test-token",
		CredentialTTL:      time.Hour,
		MaxRevokedDevices:  1,
		MaxEnrolledDevices: 4,
	})
	defer server.Close()

	now := time.Now()
	for _, deviceID := range []string{"device-a", "device-b"} {
		if server.replaceEnrollment(deviceID, "pubkey-"+deviceID, "test", RelayBootstrapProtocolVersion, now) != enrollmentOK {
			t.Fatalf("%s enrollment was rejected", deviceID)
		}
	}
	revoke := func(deviceID string) RevokeOutcome {
		t.Helper()
		outcome, err := server.RevokeDevice(context.Background(), deviceID)
		if err != nil {
			t.Fatalf("revoke %s: %v", deviceID, err)
		}
		return outcome
	}

	if outcome := revoke("device-a"); outcome != RevokeStatusOK {
		t.Fatalf("first revocation should succeed, got %v", outcome)
	}
	if outcome := revoke("device-b"); outcome != RevokeStatusCapacity {
		t.Fatalf("second revocation should fail closed at capacity, got %v", outcome)
	}

	deviceB, _ := server.store.GetEnrollment(context.Background(), "device-b")
	stillEnrolled := deviceB != nil
	_, revokedA, _ := server.store.RevocationExpiry(context.Background(), "device-a")
	if !stillEnrolled {
		t.Fatal("failed-closed revocation must leave the target device enrolled")
	}
	if !revokedA {
		t.Fatal("the in-force first revocation tombstone was evicted")
	}
}

// TestRevokedDeviceStorePrunesExpiredTombstones verifies that tombstones whose
// protected credentials have expired are pruned to make room for new
// revocations.
func TestRevokedDeviceStorePrunesExpiredTombstones(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:     []byte("01234567890123456789012345678901"),
		CredentialTTL:     time.Hour,
		MaxRevokedDevices: 1,
	})
	defer server.Close()

	now := time.Now()
	// device-a's credential was issued more than one CredentialTTL ago, so its
	// tombstone is stale the moment it is recorded.
	if recorded, _ := server.store.RecordRevocation(context.Background(), "device-a", now.Add(-time.Hour)); !recorded {
		t.Fatal("stale tombstone insertion was rejected")
	}
	if recorded, _ := server.store.RecordRevocation(context.Background(), "device-b", now.Add(time.Hour)); !recorded {
		t.Fatal("expired tombstones were not pruned to make room")
	}
	if _, present, _ := server.store.RevocationExpiry(context.Background(), "device-a"); present {
		t.Fatal("expired revocation tombstone was retained")
	}
	if _, present, _ := server.store.RevocationExpiry(context.Background(), "device-b"); !present {
		t.Fatal("new revocation tombstone was not stored")
	}
}

// TestExpiredRevocationTombstoneDoesNotBlockValidCredential verifies the
// lazy-cleanup path: a tombstone whose recorded expiry has passed no longer
// blocks authentication and is removed from the store. In normal operation the
// credential would also be expired by then (the tombstone expiry is an upper
// bound on credential expiry); this test exercises the defensive path directly.
func TestExpiredRevocationTombstoneDoesNotBlockValidCredential(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey:      []byte("01234567890123456789012345678901"),
		CredentialTTL:      time.Hour,
		MaxRevokedDevices:  4,
		MaxEnrolledDevices: 2,
	})
	defer server.Close()

	now := time.Now()
	if server.replaceEnrollment("device-a", base64.RawURLEncoding.EncodeToString(publicKey), "test", RelayBootstrapProtocolVersion, now) != enrollmentOK {
		t.Fatal("device enrollment was rejected")
	}
	if recorded, _ := server.store.RecordRevocation(context.Background(), "device-a", now.Add(-time.Minute)); !recorded {
		t.Fatal("stale tombstone insertion was rejected")
	}

	credential, err := issueCredential(server.config.CredentialKey, "device-a", publicKey, mustEnrollmentGeneration(t, server, "device-a"), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32))
	request := httptest.NewRequest(http.MethodGet, PathControlV2, nil)
	request.Header.Set("Authorization", "Bearer "+credential)
	setCurrentSignedDeviceProof(request.Header, http.MethodGet, PathControlV2, privateKey, nonce)
	if _, _, _, ok := server.authenticatedRequest(request); !ok {
		t.Fatal("expired revocation tombstone incorrectly blocked a valid credential")
	}
	_, retained, _ := server.store.RevocationExpiry(context.Background(), "device-a")
	if retained {
		t.Fatal("expired revocation tombstone was not pruned during authentication")
	}
}

// TestHubCloseClosesLiveWebSocketPeer verifies the full shutdown path closes an
// active WebSocket peer and converges with a live connection in the hub.
func TestHubCloseClosesLiveWebSocketPeer(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: "0123456789abcdef",
		CredentialTTL:   time.Hour,
		MaxConnections:  2,
	})
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	httpServer := httptest.NewServer(mux)
	defer httpServer.Close()

	connection := enrollAndConnectRelayDevice(t, httpServer.URL, "device-a", 1, "0123456789abcdef")
	defer connection.Close()

	server.hub.mutex.Lock()
	active := len(server.hub.peers)
	server.hub.mutex.Unlock()
	if active != 1 {
		t.Fatalf("expected one active peer, got %d", active)
	}

	done := make(chan struct{})
	go func() {
		server.Close()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("server shutdown did not converge with a live peer")
	}

	_ = connection.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := connection.ReadMessage(); err == nil {
		t.Fatal("websocket peer remained open after server shutdown")
	}
}

// enrollAndConnectRelayDevice enrolls a device and dials the v2 control-plane
// WebSocket, returning the connection after the Ready frame is received.
func enrollAndConnectRelayDevice(t *testing.T, base, deviceID string, nonceByte byte, enrollmentToken string) *websocket.Conn {
	t.Helper()
	credential, _, privateKey := enrollViaHTTP(t, base, deviceID, enrollmentToken)
	return dialControlV2(t, base, credential, deviceID, nonceByte, privateKey)
}
