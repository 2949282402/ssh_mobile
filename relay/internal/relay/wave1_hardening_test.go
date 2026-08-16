package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// TestAdminStateChangeRejectsCrossSiteForLogoutRevokeRotate verifies that the
// state-change middleware rejects cross-site Origin/Fetch-Metadata mutations
// for every mutation endpoint, not just login, and that same-origin requests
// still reach the auth/handler layer.
func TestAdminStateChangeRejectsCrossSiteForLogoutRevokeRotate(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: "test-token",
		AdminUser:       "test-admin",
		AdminPassword:   "test-password-123",
	})
	defer server.Close()
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	cases := []struct {
		name string
		path string
		// same-origin result when the endpoint needs no session (logout) or
		// fails auth (revoke/rotate without a cookie).
		wantSameOrigin int
	}{
		{"logout", "/api/admin/v1/auth/logout", http.StatusNoContent},
		{"device revoke", "/api/admin/v1/devices/device-a/revoke", http.StatusUnauthorized},
		{"token rotation", "/api/admin/v1/access/enrollment-token/rotate", http.StatusUnauthorized},
	}
	for _, tc := range cases {
		crossSite := httptest.NewRequest(http.MethodPost, tc.path, nil)
		crossSite.Header.Set("Origin", "https://evil.example")
		crossSite.Header.Set("Sec-Fetch-Site", "cross-site")
		crossSiteResponse := httptest.NewRecorder()
		mux.ServeHTTP(crossSiteResponse, crossSite)
		if crossSiteResponse.Code != http.StatusForbidden {
			t.Fatalf("%s cross-site request was not rejected: %d", tc.name, crossSiteResponse.Code)
		}

		sameOrigin := httptest.NewRequest(http.MethodPost, tc.path, nil)
		sameOrigin.Header.Set("Origin", "http://example.com")
		sameOrigin.Header.Set("Sec-Fetch-Site", "same-origin")
		sameOriginResponse := httptest.NewRecorder()
		mux.ServeHTTP(sameOriginResponse, sameOrigin)
		if sameOriginResponse.Code == http.StatusForbidden {
			t.Fatalf("%s same-origin request was rejected by the state-change middleware", tc.name)
		}
		if sameOriginResponse.Code != tc.wantSameOrigin {
			t.Fatalf("%s same-origin request returned %d, want %d", tc.name, sameOriginResponse.Code, tc.wantSameOrigin)
		}
	}
}

func performAdminLoginAttempt(t *testing.T, mux *http.ServeMux, remoteAddr, xForwardedFor, xRealIP string) int {
	t.Helper()
	body, _ := json.Marshal(adminLoginRequest{Username: "test-admin", Password: "wrong-password"})
	request := httptest.NewRequest(http.MethodPost, "/api/admin/v1/auth/login", bytes.NewReader(body))
	request.RemoteAddr = remoteAddr
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Origin", "http://example.com")
	request.Header.Set("Sec-Fetch-Site", "same-origin")
	if xForwardedFor != "" {
		request.Header.Set("X-Forwarded-For", xForwardedFor)
	}
	if xRealIP != "" {
		request.Header.Set("X-Real-IP", xRealIP)
	}
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, request)
	return response.Code
}

// TestLoginLimiterUsesRemoteAddrUnlessTrustedProxy verifies the default
// boundary: without a configured trusted proxy, X-Forwarded-For / X-Real-IP
// are ignored and RemoteAddr drives the limiter key.
func TestLoginLimiterUsesRemoteAddrUnlessTrustedProxy(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:           []byte("01234567890123456789012345678901"),
		AdminUser:               "test-admin",
		AdminPassword:           "test-password-123",
		AdminLoginMaxAttempts:   1,
		AdminLoginWindow:        time.Minute,
		AdminLoginBlockDuration: time.Minute,
	})
	defer server.Close()
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	// A spoofed forwarding header must not change the limiter key: the second
	// attempt from the same RemoteAddr is blocked even though the XFF value
	// would map to a different key.
	if code := performAdminLoginAttempt(t, mux, "198.51.100.10:1234", "203.0.113.99", "203.0.113.99"); code != http.StatusUnauthorized {
		t.Fatalf("first login attempt: got %d, want 401", code)
	}
	if code := performAdminLoginAttempt(t, mux, "198.51.100.10:1234", "203.0.113.99", "203.0.113.99"); code != http.StatusTooManyRequests {
		t.Fatalf("second login attempt from same RemoteAddr: got %d, want 429 (forwarded header must be ignored)", code)
	}
}

// TestLoginLimiterTrustedProxyUsesForwardedFor verifies that when the peer is
// an explicitly configured trusted proxy, the forwarded address drives the
// limiter key.
func TestLoginLimiterTrustedProxyUsesForwardedFor(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:           []byte("01234567890123456789012345678901"),
		AdminUser:               "test-admin",
		AdminPassword:           "test-password-123",
		AdminLoginMaxAttempts:   1,
		AdminLoginWindow:        time.Minute,
		AdminLoginBlockDuration: time.Minute,
		TrustedProxyCIDRs:       []netip.Prefix{netip.MustParsePrefix("192.0.2.5/32")},
	})
	defer server.Close()
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	proxyAddr := "192.0.2.5:1234"
	if code := performAdminLoginAttempt(t, mux, proxyAddr, "203.0.113.99", ""); code != http.StatusUnauthorized {
		t.Fatalf("first forwarded login attempt: got %d, want 401", code)
	}
	if code := performAdminLoginAttempt(t, mux, proxyAddr, "203.0.113.99", ""); code != http.StatusTooManyRequests {
		t.Fatalf("second forwarded login attempt: got %d, want 429", code)
	}
	// A different forwarded address is a different limiter key even though the
	// physical peer is unchanged.
	if code := performAdminLoginAttempt(t, mux, proxyAddr, "198.51.100.77", ""); code != http.StatusUnauthorized {
		t.Fatalf("forwarded address change: got %d, want 401", code)
	}
}

// TestLoginLimiterTrustedProxyUsesRightmostForwardedFor verifies the relay
// walks X-Forwarded-For from the right, skipping trusted proxies, so a forged
// leftward chain cannot select a spoofed client address.
func TestLoginLimiterTrustedProxyUsesRightmostForwardedFor(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:           []byte("01234567890123456789012345678901"),
		AdminUser:               "test-admin",
		AdminPassword:           "test-password-123",
		AdminLoginMaxAttempts:   1,
		AdminLoginWindow:        time.Minute,
		AdminLoginBlockDuration: time.Minute,
		TrustedProxyCIDRs:       []netip.Prefix{netip.MustParsePrefix("192.0.2.5/32")},
	})
	defer server.Close()
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	proxyAddr := "192.0.2.5:1234"
	if code := performAdminLoginAttempt(t, mux, proxyAddr, "1.2.3.4, 203.0.113.99", ""); code != http.StatusUnauthorized {
		t.Fatalf("first spoofed-chain login: got %d, want 401", code)
	}
	// Same rightmost (real client) address but a different forged left entry
	// must still hit the same limiter key.
	if code := performAdminLoginAttempt(t, mux, proxyAddr, "5.6.7.8, 203.0.113.99", ""); code != http.StatusTooManyRequests {
		t.Fatalf("spoofed leftward XFF entry changed the limiter key: got %d, want 429", code)
	}
}

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
		if server.replaceEnrollment(deviceID, "pubkey-"+deviceID, "test", 1, now) != enrollmentOK {
			t.Fatalf("%s enrollment was rejected", deviceID)
		}
	}
	revoke := func(deviceID string) int {
		t.Helper()
		request := httptest.NewRequest(http.MethodPost, "/api/admin/v1/devices/"+deviceID+"/revoke", nil)
		request.SetPathValue("deviceId", deviceID)
		response := httptest.NewRecorder()
		server.adminRevokeDevice(response, request)
		return response.Code
	}

	if code := revoke("device-a"); code != http.StatusNoContent {
		t.Fatalf("first revocation should succeed, got %d", code)
	}
	if code := revoke("device-b"); code != http.StatusTooManyRequests {
		t.Fatalf("second revocation should fail closed at capacity, got %d", code)
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
	if server.replaceEnrollment("device-a", base64.RawURLEncoding.EncodeToString(publicKey), "test", 1, now) != enrollmentOK {
		t.Fatal("device enrollment was rejected")
	}
	if recorded, _ := server.store.RecordRevocation(context.Background(), "device-a", now.Add(-time.Minute)); !recorded {
		t.Fatal("stale tombstone insertion was rejected")
	}

	credential, err := issueCredential(server.config.CredentialKey, "device-a", publicKey, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32))
	request := httptest.NewRequest("GET", "/v2/control", nil)
	request.Header.Set("Authorization", "Bearer "+credential)
	request.Header.Set("X-Relay-Nonce", nonce)
	request.Header.Set(
		"X-Relay-Signature",
		base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, []byte("GET\n/v2/control\n"+nonce))),
	)
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
