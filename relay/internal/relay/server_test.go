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

// TestCredentialBindsDeviceAndKey 验证凭据同时绑定设备标识和设备公钥。
func TestCredentialBindsDeviceAndKey(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	credential, err := issueCredential([]byte("01234567890123456789012345678901"), "device-a", publicKey, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	claims, restored, err := verifyCredential([]byte("01234567890123456789012345678901"), credential)
	if err != nil {
		t.Fatal(err)
	}
	if claims.DeviceID != "device-a" || base64.RawURLEncoding.EncodeToString(restored) != base64.RawURLEncoding.EncodeToString(publicKey) {
		t.Fatal("credential lost identity binding")
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
		ProtocolVersion: 1,
		Platform:        "windows",
	})

	req := httptest.NewRequest("POST", "/v1/devices/enroll", bytes.NewReader(body))
	rec := httptest.NewRecorder()

	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	var resp enrollResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if resp.Credential == "" || resp.ProtocolVersion != 1 {
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
		ProtocolVersion: 2,
		Platform:        "windows",
	})
	req := httptest.NewRequest("POST", "/v1/devices/enroll", bytes.NewReader(body))
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

	credential, err := issueCredential(
		server.config.CredentialKey,
		"device-a",
		publicKey,
		time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := server.store.PutEnrollment(context.Background(), &EnrolledDevice{
		DeviceID:        "device-a",
		PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
		ProtocolVersion: 1,
		EnrolledAt:      time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	authenticatedRequest := func(nonceValue byte) *http.Request {
		nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{nonceValue}, 32))
		request := httptest.NewRequest("GET", "/v2/control", nil)
		request.Header.Set("Authorization", "Bearer "+credential)
		request.Header.Set("X-Relay-Nonce", nonce)
		request.Header.Set(
			"X-Relay-Signature",
			base64.RawURLEncoding.EncodeToString(
				ed25519.Sign(privateKey, []byte("GET\n/v2/control\n"+nonce)),
			),
		)
		return request
	}

	first := authenticatedRequest(1)
	if _, _, _, ok := server.authenticatedRequest(first); !ok {
		t.Fatal("valid device proof was rejected")
	}
	if _, _, _, ok := server.authenticatedRequest(first); ok {
		t.Fatal("replayed device proof was accepted")
	}

	revokeRequest := httptest.NewRequest("POST", "/api/admin/v1/devices/device-a/revoke", nil)
	revokeRequest.SetPathValue("deviceId", "device-a")
	revokeResponse := httptest.NewRecorder()
	server.adminRevokeDevice(revokeResponse, revokeRequest)
	if revokeResponse.Code != http.StatusNoContent {
		t.Fatalf("expected revoke status 204, got %d", revokeResponse.Code)
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
		time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{3}, 32))
	request := httptest.NewRequest("GET", "/v2/control", nil)
	request.Header.Set("Authorization", "Bearer "+credential)
	request.Header.Set("X-Relay-Nonce", nonce)
	request.Header.Set(
		"X-Relay-Signature",
		base64.RawURLEncoding.EncodeToString(
			ed25519.Sign(privateKey, []byte("GET\n/v2/control\n"+nonce)),
		),
	)
	if _, _, _, ok := server.authenticatedRequest(request); ok {
		t.Fatal("credential from an unregistered relay process was accepted")
	}
}

// TestAdminApiContract 验证独立版本化的管理员 API 契约。
func TestAdminApiContract(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: "test-token",
		AdminUser:       "test-admin",
		AdminPassword:   "test-password-123",
	})
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	for _, path := range []string{
		"/api/admin/v1/overview",
		"/api/admin/v1/access/enrollment-token",
	} {
		request := httptest.NewRequest("GET", path, nil)
		response := httptest.NewRecorder()
		mux.ServeHTTP(response, request)
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("expected status 401 for unauthenticated %s, got %d", path, response.Code)
		}
		var payload adminErrorResponse
		if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
			t.Fatalf("failed to decode admin error: %v", err)
		}
		if payload.Error.Code != adminErrorUnauthorized {
			t.Fatalf("unexpected admin error: %+v", payload)
		}
	}

	oldRoute := httptest.NewRecorder()
	mux.ServeHTTP(oldRoute, httptest.NewRequest("GET", "/api/stats", nil))
	if oldRoute.Code != http.StatusNotFound {
		t.Fatalf("expected removed legacy route to return 404, got %d", oldRoute.Code)
	}

	loginBody, _ := json.Marshal(map[string]string{
		"username": "test-admin",
		"password": "test-password-123",
	})
	loginRequest := httptest.NewRequest("POST", "/api/admin/v1/auth/login", bytes.NewReader(loginBody))
	loginRequest.Header.Set("Content-Type", "application/json")
	loginResponse := httptest.NewRecorder()
	mux.ServeHTTP(loginResponse, loginRequest)
	if loginResponse.Code != http.StatusOK {
		t.Fatalf("expected status 200 for login, got %d", loginResponse.Code)
	}
	var loginPayload map[string]any
	if err := json.NewDecoder(loginResponse.Body).Decode(&loginPayload); err != nil {
		t.Fatalf("failed to decode login response: %v", err)
	}
	if loginPayload["username"] != "test-admin" {
		t.Fatalf("unexpected login response: %+v", loginPayload)
	}
	cookie := loginResponse.Result().Cookies()[0]

	sessionRequest := httptest.NewRequest("GET", "/api/admin/v1/auth/session", nil)
	sessionRequest.AddCookie(cookie)
	sessionResponse := httptest.NewRecorder()
	mux.ServeHTTP(sessionResponse, sessionRequest)
	var sessionPayload adminSessionResponse
	if sessionResponse.Code != http.StatusOK || json.NewDecoder(sessionResponse.Body).Decode(&sessionPayload) != nil {
		t.Fatalf("unexpected session response: status=%d body=%s", sessionResponse.Code, sessionResponse.Body.String())
	}
	if !sessionPayload.Authenticated || sessionPayload.Username != "test-admin" {
		t.Fatalf("unexpected session payload: %+v", sessionPayload)
	}

	overviewRequest := httptest.NewRequest("GET", "/api/admin/v1/overview", nil)
	overviewRequest.AddCookie(cookie)
	overviewResponse := httptest.NewRecorder()
	mux.ServeHTTP(overviewResponse, overviewRequest)
	if overviewResponse.Code != http.StatusOK {
		t.Fatalf("expected status 200 for overview, got %d", overviewResponse.Code)
	}
	var overview adminOverviewResponse
	if err := json.NewDecoder(overviewResponse.Body).Decode(&overview); err != nil {
		t.Fatalf("failed to decode overview: %v", err)
	}
	if overview.Devices.Enrolled != 0 || overview.Devices.Online != 0 {
		t.Fatalf("unexpected overview devices: %+v", overview.Devices)
	}
	if bytes.Contains(overviewResponse.Body.Bytes(), []byte("enrollment_token")) {
		t.Fatal("overview response leaked the enrollment token")
	}

	server.replaceEnrollment(
		"device-a",
		base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, ed25519.PublicKeySize)),
		"android",
		1,
		time.Date(2026, time.August, 10, 0, 0, 0, 0, time.UTC),
	)
	devicesRequest := httptest.NewRequest("GET", "/api/admin/v1/devices", nil)
	devicesRequest.AddCookie(cookie)
	devicesResponse := httptest.NewRecorder()
	mux.ServeHTTP(devicesResponse, devicesRequest)
	if devicesResponse.Code != http.StatusOK {
		t.Fatalf("expected status 200 for devices, got %d", devicesResponse.Code)
	}
	var devicesPayload adminDevicesResponse
	if err := json.NewDecoder(devicesResponse.Body).Decode(&devicesPayload); err != nil {
		t.Fatalf("failed to decode devices: %v", err)
	}
	if len(devicesPayload.Items) != 1 || devicesPayload.Items[0].PublicKeyFingerprint == "" {
		t.Fatalf("unexpected device DTO: %+v", devicesPayload)
	}
	if bytes.Contains(devicesResponse.Body.Bytes(), []byte(`"public_key":`)) {
		t.Fatal("devices response leaked the full public key field")
	}

	tokenRequest := httptest.NewRequest("GET", "/api/admin/v1/access/enrollment-token", nil)
	tokenRequest.AddCookie(cookie)
	tokenResponse := httptest.NewRecorder()
	mux.ServeHTTP(tokenResponse, tokenRequest)
	if tokenResponse.Code != http.StatusOK || !bytes.Contains(tokenResponse.Body.Bytes(), []byte("test-token")) {
		t.Fatalf("unexpected token response: status=%d body=%s", tokenResponse.Code, tokenResponse.Body.String())
	}

	logoutRequest := httptest.NewRequest("POST", "/api/admin/v1/auth/logout", nil)
	logoutRequest.AddCookie(cookie)
	logoutResponse := httptest.NewRecorder()
	mux.ServeHTTP(logoutResponse, logoutRequest)
	if logoutResponse.Code != http.StatusNoContent || logoutResponse.Body.Len() != 0 {
		t.Fatalf("expected empty 204 logout response, got %d", logoutResponse.Code)
	}
}

// TestAdminOverviewCountsOnlineDevices pins the overview online count driven by
// presence: a device with a live lease is counted online through the batch
// GetPresences path, not just the enrolled count.
func TestAdminOverviewCountsOnlineDevices(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	if result := server.replaceEnrollment("device-a", "key-a", "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	if _, _, err := server.cache.TakePresence(ctx, "device-a", "conn-1", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}

	overview, err := server.adminOverviewSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if overview.Devices.Enrolled != 1 || overview.Devices.Online != 1 || !overview.PresenceAvailable {
		t.Fatalf("overview should count the online device with presence available: %+v", overview.Devices)
	}
}

// TestAdminOverviewCountsActiveRelayDataPairs pins the management metric to
// the real RelayData registry instead of the legacy control-plane hub.
func TestAdminOverviewCountsActiveRelayDataPairs(t *testing.T) {
	server := NewServer(Config{})
	defer server.Close()

	initiator := testRelayDataConnForRegistry("reservation-admin", "device-a", relayDataRoleInitiator)
	responder := testRelayDataConnForRegistry("reservation-admin", "device-b", relayDataRoleResponder)
	if _, ok := server.relayData.admitEndpoint(initiator); !ok {
		t.Fatal("initiator admission failed")
	}
	if _, ok := server.relayData.admitEndpoint(responder); !ok {
		t.Fatal("responder admission failed")
	}

	overview, err := server.adminOverviewSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if overview.Relay.ActiveTransfers != 1 {
		t.Fatalf("overview should report one active RelayData pair, got %d", overview.Relay.ActiveTransfers)
	}

	server.relayData.releaseEndpoint(responder)
	overview, err = server.adminOverviewSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if overview.Relay.ActiveTransfers != 0 {
		t.Fatalf("released RelayData pair should not remain active, got %d", overview.Relay.ActiveTransfers)
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
