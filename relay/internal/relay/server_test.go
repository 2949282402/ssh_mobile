// v1 Relay 服务端契约测试，覆盖 enrollment、认证、会话路由和管理端 HTTP 响应。

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
	"testing"
	"time"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

func mustEnrollmentGeneration(t *testing.T, server *Server, deviceID string) int64 {
	t.Helper()
	device, err := server.store.GetEnrollment(context.Background(), deviceID)
	if err != nil || device == nil {
		t.Fatalf("load enrollment generation for %s: device=%v err=%v", deviceID, device, err)
	}
	generation := device.EnrolledAt.UnixMicro()
	if generation <= 0 {
		t.Fatalf("invalid enrollment generation for %s: %d", deviceID, generation)
	}
	return generation
}

// TestCredentialBindsDeviceAndKey 验证凭据同时绑定设备标识和设备公钥。
func TestCredentialBindsDeviceAndKey(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	generation := time.Now().UnixMicro()
	credential, err := issueCredential([]byte("01234567890123456789012345678901"), "device-a", publicKey, generation, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	claims, restored, err := verifyCredential([]byte("01234567890123456789012345678901"), credential)
	if err != nil {
		t.Fatal(err)
	}
	if claims.DeviceID != "device-a" || claims.EnrollmentGeneration != generation || base64.RawURLEncoding.EncodeToString(restored) != base64.RawURLEncoding.EncodeToString(publicKey) {
		t.Fatal("credential lost identity binding")
	}
}

func TestSameKeyReenrollmentInvalidatesPriorCredentialGeneration(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{CredentialKey: []byte("01234567890123456789012345678901")})
	defer server.Close()
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	fixedTime := time.Now()
	if result := server.replaceEnrollment("device-a", encodedKey, "test", RelayBootstrapProtocolVersion, fixedTime); result != enrollmentOK {
		t.Fatalf("initial enrollment=%v", result)
	}
	oldGeneration := mustEnrollmentGeneration(t, server, "device-a")
	oldCredential, err := issueCredential(server.config.CredentialKey, "device-a", publicKey, oldGeneration, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if result := server.replaceEnrollment("device-a", encodedKey, "test", RelayBootstrapProtocolVersion, fixedTime); result != enrollmentOK {
		t.Fatalf("re-enrollment=%v", result)
	}
	newGeneration := mustEnrollmentGeneration(t, server, "device-a")
	if newGeneration <= oldGeneration {
		t.Fatalf("generation did not advance: old=%d new=%d", oldGeneration, newGeneration)
	}

	authRequest := func(credential string, nonceByte byte) *http.Request {
		nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{nonceByte}, 32))
		request := httptest.NewRequest(http.MethodGet, "/v2/control", nil)
		request.Header.Set("Authorization", "Bearer "+credential)
		setCurrentSignedDeviceProof(request.Header, http.MethodGet, "/v2/control", privateKey, nonce)
		return request
	}
	if _, _, _, ok := server.authenticatedRequest(authRequest(oldCredential, 0x31)); ok {
		t.Fatal("credential from the prior enrollment generation was accepted")
	}
	newCredential, err := issueCredential(server.config.CredentialKey, "device-a", publicKey, newGeneration, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, ok := server.authenticatedRequest(authRequest(newCredential, 0x32)); !ok {
		t.Fatal("credential from the current enrollment generation was rejected")
	}
}

// TestEnrollDevice 验证 v1 enrollment 返回完整的原生配置材料。
func TestEnrollDevice(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	server := NewServer(Config{
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: "test-token",
		CredentialTTL:   time.Hour,
	})
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	body, _ := json.Marshal(enrollRequest{
		DeviceID:        "test-device",
		PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
		EnrollmentToken: "test-token",
		ProtocolVersion: RelayBootstrapProtocolVersion,
		Platform:        "windows",
	})

	req := httptest.NewRequest("POST", PathEnrollV2, bytes.NewReader(body))
	rec := httptest.NewRecorder()

	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	var resp enrollResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if resp.Credential == "" || resp.ProtocolVersion != RelayBootstrapProtocolVersion {
		t.Fatalf("invalid enroll response: %+v", resp)
	}
}

// TestRelayHTTPErrorUsesStableNetworkShape 验证设备 HTTP 错误不依赖自由字符串。
func TestRelayHTTPErrorUsesStableNetworkShape(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: "test-token",
	})
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	body, _ := json.Marshal(enrollRequest{
		DeviceID:        "device-a",
		PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
		EnrollmentToken: "test-token",
		ProtocolVersion: RelayBootstrapProtocolVersion + 1,
		Platform:        "windows",
	})
	req := httptest.NewRequest("POST", PathEnrollV2, bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected status 400, got %d", rec.Code)
	}
	var response map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("failed to decode error response: %v", err)
	}
	if response["code"] != float64(relayErrorProtocolError) ||
		response["operation"] != "enroll_relay" ||
		response["peer_id"] != "device-a" {
		t.Fatalf("unexpected error response: %+v", response)
	}
	if _, exists := response["error"]; exists {
		t.Fatal("error response retained the deprecated error field")
	}
}

// TestDeviceProofRejectsReplayAndRevocation 验证证明重放和设备撤销都会被拒绝。
func TestDeviceProofRejectsReplayAndRevocation(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: "test-enrollment-token",
		CredentialTTL:   time.Hour,
	})
	defer server.Close()

	if _, err := server.store.PutEnrollment(context.Background(), &EnrolledDevice{
		DeviceID:        "device-a",
		PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
		ProtocolVersion: RelayBootstrapProtocolVersion,
		EnrolledAt:      time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	credential, err := issueCredential(
		server.config.CredentialKey,
		"device-a",
		publicKey,
		mustEnrollmentGeneration(t, server, "device-a"),
		time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}
	authenticatedRequest := func(nonceValue byte) *http.Request {
		nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{nonceValue}, 32))
		request := httptest.NewRequest("GET", "/v2/control", nil)
		request.Header.Set("Authorization", "Bearer "+credential)
		setCurrentSignedDeviceProof(request.Header, http.MethodGet, "/v2/control", privateKey, nonce)
		return request
	}

	first := authenticatedRequest(1)
	if _, _, _, ok := server.authenticatedRequest(first); !ok {
		t.Fatal("valid device proof was rejected")
	}
	if _, _, _, ok := server.authenticatedRequest(first); ok {
		t.Fatal("replayed device proof was accepted")
	}

	outcome, err := server.RevokeDevice(context.Background(), "device-a")
	if err != nil {
		t.Fatalf("revoke failed: %v", err)
	}
	if outcome != RevokeStatusOK {
		t.Fatalf("expected revoke status OK, got %v", outcome)
	}
	if _, _, _, ok := server.authenticatedRequest(authenticatedRequest(2)); ok {
		t.Fatal("revoked device credential was accepted")
	}
}

// TestCredentialRequiresCurrentEnrollment 验证旧进程凭据不能绕过当前 enrollment。
func TestCredentialRequiresCurrentEnrollment(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey: []byte("01234567890123456789012345678901"),
		CredentialTTL: time.Hour,
	})
	defer server.Close()
	credential, err := issueCredential(
		server.config.CredentialKey,
		"device-from-previous-process",
		publicKey,
		time.Now().UnixMicro(),
		time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{3}, 32))
	request := httptest.NewRequest("GET", "/v2/control", nil)
	request.Header.Set("Authorization", "Bearer "+credential)
	setCurrentSignedDeviceProof(request.Header, http.MethodGet, "/v2/control", privateKey, nonce)
	if _, _, _, ok := server.authenticatedRequest(request); ok {
		t.Fatal("credential from an unregistered relay process was accepted")
	}
}

// TestInternalStatusCountsOnlineDevices pins the status online count driven by
// presence: a device with a live lease is counted online through the batch
// GetPresences path, not just the enrolled count.
func TestInternalStatusCountsOnlineDevices(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	if result := server.replaceEnrollment("device-a", "key-a", "test", RelayBootstrapProtocolVersion, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	if _, _, err := server.cache.TakePresence(ctx, "device-a", "conn-1", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}

	snapshot, err := server.StatusSnapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Devices.Enrolled != 1 || snapshot.Devices.Online != 1 || !snapshot.PresenceAvailable {
		t.Fatalf("status should count the online device with presence available: %+v", snapshot.Devices)
	}
}

// TestInternalStatusCountsActiveRelayDataPairs pins the status metric to
// the real RelayData registry instead of the legacy control-plane hub.
func TestInternalStatusCountsActiveRelayDataPairs(t *testing.T) {
	server := NewServer(Config{})
	defer server.Close()
	ctx := context.Background()

	initiator := testRelayDataConnForRegistry("reservation-internal", "device-a", relayDataRoleInitiator)
	responder := testRelayDataConnForRegistry("reservation-internal", "device-b", relayDataRoleResponder)
	if _, ok := server.relayData.admitEndpoint(initiator); !ok {
		t.Fatal("initiator admission failed")
	}
	if _, ok := server.relayData.admitEndpoint(responder); !ok {
		t.Fatal("responder admission failed")
	}

	snapshot, err := server.StatusSnapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Relay.ActiveTransfers != 1 {
		t.Fatalf("status should report one active RelayData pair, got %d", snapshot.Relay.ActiveTransfers)
	}

	server.relayData.releaseEndpoint(responder)
	snapshot, err = server.StatusSnapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Relay.ActiveTransfers != 0 {
		t.Fatalf("released RelayData pair should not remain active, got %d", snapshot.Relay.ActiveTransfers)
	}
}

// TestHeartbeatRenewLost verifies the heartbeat-ownership contract: when a
// foreign connection (e.g. on another instance) takes over the device's
// presence lease, the superseded local connection discovers it on its next
// heartbeat renew and self-heals by closing, instead of keeping a zombie socket
// or flapping the presence identity. It also pins that presenceFor must write
// the peer's connectionID (an empty owner would renew against the foreign lease
// and fail closed on every heartbeat).
func TestHeartbeatRenewLost(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()

	ctx := context.Background()
	peer := injectPeer(server.hub, "device-a")
	// A foreign connection owns the lease (cross-instance takeover).
	if _, _, err := server.cache.TakePresence(ctx, "device-a", "foreign-conn", Presence{InstanceID: "i2"}, time.Minute); err != nil {
		t.Fatal(err)
	}

	server.hub.handleHeartbeatV2(peer, &v2.Heartbeat{RequestId: 1, SentAtMs: time.Now().UnixMilli()})

	select {
	case <-peer.done:
	default:
		t.Fatal("superseded connection was not closed after losing the lease")
	}
	presence, present, err := server.cache.GetPresence(ctx, "device-a")
	if err != nil || !present || presence.ConnectionID != "foreign-conn" {
		t.Fatalf("foreign lease should survive the superseded heartbeat: %+v present=%v err=%v", presence, present, err)
	}
}
