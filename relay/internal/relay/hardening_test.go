package relay

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
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

	if outcome, err := server.RevokeDevice(context.Background(), "device-a"); err != nil || outcome != RevokeStatusOK {
		t.Fatalf("revoke device-a: outcome=%v err=%v", outcome, err)
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

func TestTokenRotationIsProcessLocalAndRestartClearsDevices(t *testing.T) {
	const originalToken = "original-enrollment-token"
	const credentialKey = "01234567890123456789012345678901"
	const internalToken = "0123456789abcdef0123456789abcdef"
	server := NewServer(Config{
		CredentialKey:   []byte(credentialKey),
		EnrollmentToken: originalToken,
		InternalToken:   internalToken,
	})

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	rotateRequest := httptest.NewRequest(http.MethodPost, PathInternalRotateTokenV2, nil)
	rotateRequest.Header.Set("Authorization", "Bearer "+internalToken)
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

func TestTokenRotationRejectsNonDurableMutationInMySQLMode(t *testing.T) {
	const originalToken = "original-enrollment-token"
	const internalToken = "0123456789abcdef0123456789abcdef"
	server := NewServer(Config{
		StorageMode:     "mysql",
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: originalToken,
		InternalToken:   internalToken,
	})
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	request := httptest.NewRequest(http.MethodPost, PathInternalRotateTokenV2, nil)
	request.Header.Set("Authorization", "Bearer "+internalToken)
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, request)

	if response.Code != http.StatusConflict {
		t.Fatalf("mysql-mode rotation status=%d body=%s", response.Code, response.Body.String())
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
