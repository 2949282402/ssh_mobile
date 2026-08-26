package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

func TestEnrolledDeviceLimitAllowsReplacementButRejectsNewDevice(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:      []byte("01234567890123456789012345678901"),
		EnrollmentToken:    "test-enrollment-token",
		MaxEnrolledDevices: 1,
	})
	defer server.Close()

	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	if server.replaceEnrollment("device-a", encodedKey, "test", RelayBootstrapProtocolVersion, time.Now()) != enrollmentOK {
		t.Fatal("first enrolled device was rejected")
	}
	if server.replaceEnrollment("device-b", encodedKey, "test", RelayBootstrapProtocolVersion, time.Now()) != enrollmentResourceLimit {
		t.Fatal("new device exceeded the enrolled-device limit")
	}
	if server.replaceEnrollment("device-a", encodedKey, "test-updated", RelayBootstrapProtocolVersion, time.Now()) != enrollmentOK {
		t.Fatal("existing device replacement was rejected at capacity")
	}
}

func TestPeerPendingFrameAndByteLimits(t *testing.T) {
	peer := &peer{
		outbound:         make(chan outboundFrame, 4),
		done:             make(chan struct{}),
		maxPendingFrames: 2,
		maxPendingBytes:  5,
	}
	first := outboundFrame{messageType: 1, data: []byte("abc")}
	if !peer.enqueue(first) {
		t.Fatal("first pending frame was rejected")
	}
	if peer.enqueue(outboundFrame{messageType: 1, data: []byte("def")}) {
		t.Fatal("pending byte limit was bypassed")
	}
	queued := <-peer.outbound
	peer.dequeue(queued)
	if !peer.enqueue(outboundFrame{messageType: 1, data: []byte("def")}) {
		t.Fatal("pending byte budget was not released after dequeue")
	}
}

func TestPerDeviceByteRateLimit(t *testing.T) {
	peer := &peer{
		maxFramesPerSecond: 10,
		maxBytesPerSecond:  5,
	}
	if !peer.allowFrame(3) {
		t.Fatal("first frame exceeded no byte budget")
	}
	if peer.allowFrame(3) {
		t.Fatal("per-device byte rate limit was bypassed")
	}
}

func TestDiscoveryPublishBudgetSurvivesConnectionReplacement(t *testing.T) {
	hub := newHub(Config{MaxEnrolledDevices: 2})
	defer hub.close()
	now := time.Now()
	for i := 0; i < int(discoveryPublishBurst); i++ {
		if !hub.allowDiscoveryPublish("device-a", now) {
			t.Fatalf("initial discovery burst rejected at index %d", i)
		}
	}
	if hub.allowDiscoveryPublish("device-a", now) {
		t.Fatal("discovery fan-out limiter accepted traffic beyond its burst")
	}
	// The key is device-scoped, so replacing a socket cannot reset the budget.
	if hub.allowDiscoveryPublish("device-a", now) {
		t.Fatal("same-device reconnect reset the discovery fan-out budget")
	}
	if !hub.allowDiscoveryPublish("device-a", now.Add(discoveryPublishRefill)) {
		t.Fatal("discovery budget did not refill after the documented interval")
	}
}

func TestDiscoveryPublishBudgetCapacityPrunesIdleDevices(t *testing.T) {
	limiter := newDiscoveryFanoutLimiter(1)
	now := time.Now()
	if !limiter.allow("device-a", now) {
		t.Fatal("first device was rejected")
	}
	if limiter.allow("device-b", now) {
		t.Fatal("limiter admitted a second device beyond its bounded map")
	}
	if !limiter.allow("device-b", now.Add(discoveryBudgetRetention)) {
		t.Fatal("idle device budget was not pruned for a new device")
	}
}

func TestDiscoveryPublishBudgetReleasesDurablyRevokedDevice(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:      []byte("01234567890123456789012345678901"),
		EnrollmentToken:    "test-enrollment-token",
		MaxEnrolledDevices: 1,
	})
	defer server.Close()

	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	if result := server.replaceEnrollment("device-a", encodedKey, "test", RelayBootstrapProtocolVersion, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll device-a: %v", result)
	}
	now := time.Now()
	if !server.hub.allowDiscoveryPublish("device-a", now) {
		t.Fatal("device-a first discovery publish was rejected")
	}

	revokeRequest := httptest.NewRequest(http.MethodPost, "/api/admin/v1/devices/device-a/revoke", nil)
	revokeRequest.SetPathValue("deviceId", "device-a")
	revokeResponse := httptest.NewRecorder()
	server.adminRevokeDevice(revokeResponse, revokeRequest)
	if revokeResponse.Code != http.StatusNoContent {
		t.Fatalf("revoke device-a: status=%d body=%s", revokeResponse.Code, revokeResponse.Body.String())
	}
	if result := server.replaceEnrollment("device-b", encodedKey, "test", RelayBootstrapProtocolVersion, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll device-b after revoke: %v", result)
	}
	if !server.hub.allowDiscoveryPublish("device-b", now) {
		t.Fatal("device-b first discovery publish remained blocked by revoked device-a's limiter slot")
	}
}

func TestV2QueueOverflowClosesPeerSynchronously(t *testing.T) {
	hub := &hub{}
	peer := &peer{
		outbound: make(chan outboundFrame, 1),
		done:     make(chan struct{}),
	}
	peer.outbound <- outboundFrame{messageType: websocket.BinaryMessage, data: []byte("occupied")}
	hub.sendV2Frame(peer, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_HeartbeatAck{HeartbeatAck: &v2.HeartbeatAck{
			RequestId: 1,
		}},
	})
	select {
	case <-peer.done:
	default:
		t.Fatal("queue overflow returned before closing the peer")
	}
	// Repeated overflow/close attempts are absorbed by the peer's once gate.
	closePeer(peer)
}

func TestAdminSessionLimitAndCleanup(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:    []byte("01234567890123456789012345678901"),
		MaxAdminSessions: 1,
		AdminSessionTTL:  time.Minute,
	})
	defer server.Close()
	ctx := context.Background()

	first, err := server.tryCreateAdminSession(ctx)
	if err != nil || first == "" {
		t.Fatal("first administrator session was not created")
	}
	if _, err = server.tryCreateAdminSession(ctx); !errors.Is(err, errAdminSessionCapacity) {
		t.Fatal("administrator session limit was bypassed")
	}
	if err := server.destroyAdminSession(ctx, first); err != nil {
		t.Fatalf("destroy administrator session: %v", err)
	}
	if _, err = server.tryCreateAdminSession(ctx); err != nil {
		t.Fatal("administrator session slot was not released")
	}
}

func TestAdminLoginRateLimitAndRequestProtection(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:           []byte("01234567890123456789012345678901"),
		AdminUser:               "test-admin",
		AdminPassword:           "test-password-123",
		AdminLoginMaxAttempts:   2,
		AdminLoginWindow:        time.Minute,
		AdminLoginBlockDuration: time.Minute,
	})
	defer server.Close()
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	login := func(username, password, contentType, origin, fetchSite string) *httptest.ResponseRecorder {
		t.Helper()
		body, err := json.Marshal(adminLoginRequest{Username: username, Password: password})
		if err != nil {
			t.Fatal(err)
		}
		request := httptest.NewRequest(http.MethodPost, "/api/admin/v1/auth/login", bytes.NewReader(body))
		request.RemoteAddr = "192.0.2.10:1234"
		if contentType != "" {
			request.Header.Set("Content-Type", contentType)
		}
		if origin != "" {
			request.Header.Set("Origin", origin)
		}
		if fetchSite != "" {
			request.Header.Set("Sec-Fetch-Site", fetchSite)
		}
		response := httptest.NewRecorder()
		mux.ServeHTTP(response, request)
		return response
	}

	if response := login("test-admin", "wrong-password", "application/json", "http://example.com", "same-origin"); response.Code != http.StatusUnauthorized {
		t.Fatalf("expected first failed login to be unauthorized, got %d", response.Code)
	}
	if response := login("test-admin", "wrong-password", "application/json", "http://example.com", "same-origin"); response.Code != http.StatusUnauthorized {
		t.Fatalf("expected second failed login to be unauthorized, got %d", response.Code)
	}
	if response := login("test-admin", "wrong-password", "application/json", "http://example.com", "same-origin"); response.Code != http.StatusTooManyRequests || response.Header().Get("Retry-After") == "" {
		t.Fatalf("expected rate-limited login with retry hint, got %d headers=%v", response.Code, response.Header())
	}

	if response := login("test-admin", "test-password-123", "application/json", "https://evil.example", "cross-site"); response.Code != http.StatusForbidden {
		t.Fatalf("cross-site login was not rejected, got %d", response.Code)
	}
	if response := login("test-admin", "test-password-123", "text/plain", "http://example.com", "same-origin"); response.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("non-JSON login was not rejected, got %d", response.Code)
	}

	request := httptest.NewRequest(
		http.MethodPost,
		"/api/admin/v1/auth/login",
		bytes.NewReader([]byte(`{"username":"test-admin","password":"test-password-123"}`)),
	)
	request.RemoteAddr = "192.0.2.11:1234"
	request.Header.Set("Content-Type", "application/json; charset=utf-8")
	request.Header.Set("Origin", "http://example.com")
	request.Header.Set("Sec-Fetch-Site", "same-origin")
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("same-origin JSON login was rejected, got %d", response.Code)
	}
}

func TestAdminTokenRotationIsProcessLocalAndRestartClearsDevices(t *testing.T) {
	const originalToken = "original-enrollment-token"
	const credentialKey = "01234567890123456789012345678901"
	server := NewServer(Config{
		CredentialKey:   []byte(credentialKey),
		EnrollmentToken: originalToken,
		AdminUser:       "test-admin",
		AdminPassword:   "test-password-123",
	})

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	loginBody := bytes.NewReader([]byte(`{"username":"test-admin","password":"test-password-123"}`))
	loginRequest := httptest.NewRequest(http.MethodPost, "/api/admin/v1/auth/login", loginBody)
	loginRequest.Header.Set("Content-Type", "application/json")
	loginResponse := httptest.NewRecorder()
	mux.ServeHTTP(loginResponse, loginRequest)
	if loginResponse.Code != http.StatusOK || len(loginResponse.Result().Cookies()) != 1 {
		t.Fatalf("administrator login failed: status=%d", loginResponse.Code)
	}

	rotateRequest := httptest.NewRequest(http.MethodPost, "/api/admin/v1/access/enrollment-token/rotate", nil)
	rotateRequest.AddCookie(loginResponse.Result().Cookies()[0])
	rotateResponse := httptest.NewRecorder()
	mux.ServeHTTP(rotateResponse, rotateRequest)
	if rotateResponse.Code != http.StatusOK {
		t.Fatalf("enrollment token rotation failed: status=%d", rotateResponse.Code)
	}
	var rotated map[string]string
	if err := json.NewDecoder(rotateResponse.Body).Decode(&rotated); err != nil {
		t.Fatal(err)
	}
	rotatedToken := rotated["enrollment_token"]
	if rotatedToken == "" || rotatedToken == originalToken {
		t.Fatal("token rotation did not produce a new in-memory token")
	}
	if server.validEnrollmentToken(originalToken) {
		t.Fatal("old enrollment token remained valid after same-process rotation")
	}
	if !server.validEnrollmentToken(rotatedToken) {
		t.Fatal("rotated enrollment token was not accepted")
	}

	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server.replaceEnrollment("device-a", base64.RawURLEncoding.EncodeToString(publicKey), "test", RelayBootstrapProtocolVersion, time.Now())
	server.Close()

	restarted := NewServer(Config{
		CredentialKey:   []byte(credentialKey),
		EnrollmentToken: originalToken,
	})
	defer restarted.Close()
	if !restarted.validEnrollmentToken(originalToken) || restarted.validEnrollmentToken(rotatedToken) {
		t.Fatal("rotated enrollment token incorrectly survived process restart")
	}
	deviceCount, _ := restarted.store.CountEnrollments(context.Background())
	if deviceCount != 0 {
		t.Fatalf("device enrollment state survived process restart: %d", deviceCount)
	}
}

func TestAdminTokenRotationRejectsNonDurableMutationInMySQLMode(t *testing.T) {
	const originalToken = "original-enrollment-token"
	server := NewServer(Config{
		StorageMode:     "mysql",
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: originalToken,
	})
	defer server.Close()

	request := httptest.NewRequest(http.MethodPost, "/api/admin/v1/access/enrollment-token/rotate", nil)
	response := httptest.NewRecorder()
	server.adminRotateToken(response, request)

	if response.Code != http.StatusConflict {
		t.Fatalf("mysql-mode rotation status=%d body=%s", response.Code, response.Body.String())
	}
	var failure adminErrorResponse
	if err := json.NewDecoder(response.Body).Decode(&failure); err != nil {
		t.Fatal(err)
	}
	if failure.Error.Code != adminErrorConflict {
		t.Fatalf("mysql-mode rotation error=%+v", failure)
	}
	if !server.validEnrollmentToken(originalToken) {
		t.Fatal("rejected mysql-mode rotation changed the configured token")
	}
}

func TestHubCloseIsIdempotentAndStopsPruner(t *testing.T) {
	hub := newHub(Config{})
	done := make(chan struct{})
	go func() {
		hub.close()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("hub close did not converge")
	}
	hub.close()
}
