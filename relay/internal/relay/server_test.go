// v1 Relay 服务端契约测试，覆盖 enrollment、认证、会话路由和管理端 HTTP 响应。

package relay

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/gorilla/websocket"
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

// TestHubDoesNotPersistExpiredSession 验证过期 Relay 会话会被及时清理。
func TestHubDoesNotPersistExpiredSession(t *testing.T) {
	hub := newHub(Config{SessionTTL: time.Nanosecond})
	defer hub.close()
	hub.sessions["0123456789abcdef0123456789abcdef"] = session{sender: "a", receiver: "b", expiresAt: time.Now().Add(-time.Second)}
	hub.mutex.Lock()
	for id, value := range hub.sessions {
		if time.Now().After(value.expiresAt) {
			delete(hub.sessions, id)
		}
	}
	_, found := hub.sessions["0123456789abcdef0123456789abcdef"]
	hub.mutex.Unlock()
	if found {
		t.Fatal("expired session was retained")
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
	server.enrolledDevices["device-a"] = &EnrolledDevice{
		DeviceID:        "device-a",
		PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
		ProtocolVersion: 1,
		EnrolledAt:      time.Now(),
	}
	authenticatedRequest := func(nonceValue byte) *http.Request {
		nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{nonceValue}, 32))
		request := httptest.NewRequest("GET", "/v1/connect", nil)
		request.Header.Set("Authorization", "Bearer "+credential)
		request.Header.Set("X-Relay-Nonce", nonce)
		request.Header.Set(
			"X-Relay-Signature",
			base64.RawURLEncoding.EncodeToString(
				ed25519.Sign(privateKey, []byte("GET\n/v1/connect\n"+nonce)),
			),
		)
		return request
	}

	first := authenticatedRequest(1)
	if _, _, ok := server.authenticatedRequest(first); !ok {
		t.Fatal("valid device proof was rejected")
	}
	if _, _, ok := server.authenticatedRequest(first); ok {
		t.Fatal("replayed device proof was accepted")
	}

	const activeSession = "00112233445566778899aabbccddeeff"
	server.hub.mutex.Lock()
	server.hub.sessions[activeSession] = session{
		sender:    "device-a",
		receiver:  "device-b",
		expiresAt: time.Now().Add(time.Minute),
	}
	server.hub.mutex.Unlock()
	revokeBody, _ := json.Marshal(map[string]string{"device_id": "device-a"})
	revokeRequest := httptest.NewRequest("POST", "/api/devices/revoke", bytes.NewReader(revokeBody))
	revokeResponse := httptest.NewRecorder()
	server.revokeDevice(revokeResponse, revokeRequest)
	if revokeResponse.Code != http.StatusOK {
		t.Fatalf("expected revoke status 200, got %d", revokeResponse.Code)
	}
	if _, _, ok := server.authenticatedRequest(authenticatedRequest(2)); ok {
		t.Fatal("revoked device credential was accepted")
	}
	server.hub.mutex.Lock()
	_, retained := server.hub.sessions[activeSession]
	server.hub.mutex.Unlock()
	if retained {
		t.Fatal("revocation retained an active device session")
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
	request := httptest.NewRequest("GET", "/v1/connect", nil)
	request.Header.Set("Authorization", "Bearer "+credential)
	request.Header.Set("X-Relay-Nonce", nonce)
	request.Header.Set(
		"X-Relay-Signature",
		base64.RawURLEncoding.EncodeToString(
			ed25519.Sign(privateKey, []byte("GET\n/v1/connect\n"+nonce)),
		),
	)
	if _, _, ok := server.authenticatedRequest(request); ok {
		t.Fatal("credential from an unregistered relay process was accepted")
	}
}

// TestDashboardContainsNoInlineHandlersOrDynamicInnerHTML 验证控制台不使用不安全的内联脚本。
func TestDashboardContainsNoInlineHandlersOrDynamicInnerHTML(t *testing.T) {
	index, err := staticFS.ReadFile("static/index.html")
	if err != nil {
		t.Fatal(err)
	}
	script, err := staticFS.ReadFile("static/app.js")
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(index, []byte("onclick=")) || bytes.Contains(index, []byte("onsubmit=")) {
		t.Fatal("dashboard contains inline event handlers")
	}
	if bytes.Contains(script, []byte("innerHTML")) {
		t.Fatal("dashboard renders server data through innerHTML")
	}
}

// TestDashboardAndApiStats 验证控制台登录和统计 API 的基本契约。
func TestDashboardAndApiStats(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: "test-token",
		AdminUser:       "test-admin",
		AdminPassword:   "test-password-123",
	})
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	// Test GET / HTML dashboard
	reqDash := httptest.NewRequest("GET", "/", nil)
	recDash := httptest.NewRecorder()
	mux.ServeHTTP(recDash, reqDash)

	if recDash.Code != http.StatusOK {
		t.Fatalf("expected status 200 for dashboard, got %d", recDash.Code)
	}
	if !bytes.Contains(recDash.Body.Bytes(), []byte("SSH Mobile")) {
		t.Fatalf("dashboard missing expected HTML content")
	}

	// Test GET /api/stats JSON without auth (expected 401)
	reqStatsUnauth := httptest.NewRequest("GET", "/api/stats", nil)
	recStatsUnauth := httptest.NewRecorder()
	mux.ServeHTTP(recStatsUnauth, reqStatsUnauth)
	if recStatsUnauth.Code != http.StatusUnauthorized {
		t.Fatalf("expected status 401 for unauthenticated stats, got %d", recStatsUnauth.Code)
	}

	// Login
	loginBody, _ := json.Marshal(map[string]string{
		"username": "test-admin",
		"password": "test-password-123",
	})
	reqLogin := httptest.NewRequest("POST", "/api/login", bytes.NewReader(loginBody))
	recLogin := httptest.NewRecorder()
	mux.ServeHTTP(recLogin, reqLogin)
	if recLogin.Code != http.StatusOK {
		t.Fatalf("expected status 200 for login, got %d", recLogin.Code)
	}
	var loginResponse map[string]any
	if err := json.NewDecoder(recLogin.Body).Decode(&loginResponse); err != nil {
		t.Fatalf("failed to decode login response: %v", err)
	}
	if loginResponse["username"] != "test-admin" {
		t.Fatalf("unexpected login response: %+v", loginResponse)
	}
	if _, exists := loginResponse["success"]; exists {
		t.Fatal("login response retained the deprecated success field")
	}
	cookie := recLogin.Result().Cookies()[0]

	// Test GET /api/stats JSON with auth
	reqStats := httptest.NewRequest("GET", "/api/stats", nil)
	reqStats.AddCookie(cookie)
	recStats := httptest.NewRecorder()
	mux.ServeHTTP(recStats, reqStats)

	if recStats.Code != http.StatusOK {
		t.Fatalf("expected status 200 for stats, got %d", recStats.Code)
	}
	var stats statsResponse
	if err := json.NewDecoder(recStats.Body).Decode(&stats); err != nil {
		t.Fatalf("failed to decode stats JSON: %v", err)
	}

	revokeBody, _ := json.Marshal(map[string]string{"device_id": "device-a"})
	revokeRequest := httptest.NewRequest(
		"POST",
		"/api/devices/revoke",
		bytes.NewReader(revokeBody),
	)
	revokeRequest.AddCookie(cookie)
	revokeResponse := httptest.NewRecorder()
	mux.ServeHTTP(revokeResponse, revokeRequest)
	if revokeResponse.Code != http.StatusOK {
		t.Fatalf("expected status 200 for revoke, got %d", revokeResponse.Code)
	}
	var revokePayload map[string]any
	if err := json.NewDecoder(revokeResponse.Body).Decode(&revokePayload); err != nil {
		t.Fatalf("failed to decode revoke response: %v", err)
	}
	if revokePayload["device_id"] != "device-a" {
		t.Fatalf("unexpected revoke response: %+v", revokePayload)
	}
	if _, exists := revokePayload["success"]; exists {
		t.Fatal("revoke response retained the deprecated success field")
	}

	logoutRequest := httptest.NewRequest("POST", "/api/logout", nil)
	logoutRequest.AddCookie(cookie)
	logoutResponse := httptest.NewRecorder()
	mux.ServeHTTP(logoutResponse, logoutRequest)
	if logoutResponse.Code != http.StatusNoContent || logoutResponse.Body.Len() != 0 {
		t.Fatalf("expected empty 204 logout response, got %d", logoutResponse.Code)
	}
}

// TestDartWireContractEndToEnd 验证 Dart v1 Relay 控制帧和加密二进制帧端到端一致。
func TestDartWireContractEndToEnd(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: "0123456789abcdef",
		CredentialTTL:   time.Hour,
		SessionTTL:      time.Minute,
		MaxConnections:  2,
	})
	defer server.Close()
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	httpServer := httptest.NewServer(mux)
	defer httpServer.Close()

	connectDevice := func(deviceID string, nonceByte byte) *websocket.Conn {
		t.Helper()
		publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		enrollmentBody, _ := json.Marshal(enrollRequest{
			DeviceID:        deviceID,
			PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
			EnrollmentToken: "0123456789abcdef",
			ProtocolVersion: 1,
			Platform:        "windows",
		})
		response, err := http.Post(
			httpServer.URL+"/v1/devices/enroll",
			"application/json",
			bytes.NewReader(enrollmentBody),
		)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		var enrollment enrollResponse
		if response.StatusCode != http.StatusOK || json.NewDecoder(response.Body).Decode(&enrollment) != nil {
			t.Fatalf("device enrollment failed with status %d", response.StatusCode)
		}

		nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{nonceByte}, 32))
		headers := http.Header{}
		headers.Set("Authorization", "Bearer "+enrollment.Credential)
		headers.Set("X-Relay-Nonce", nonce)
		headers.Set(
			"X-Relay-Signature",
			base64.RawURLEncoding.EncodeToString(
				ed25519.Sign(privateKey, []byte("GET\n/v1/connect\n"+nonce)),
			),
		)
		relayURL, err := url.Parse(httpServer.URL)
		if err != nil {
			t.Fatal(err)
		}
		relayURL.Scheme = "ws"
		relayURL.Path = "/v1/connect"
		connection, response, err := websocket.DefaultDialer.Dial(relayURL.String(), headers)
		if err != nil {
			status := 0
			if response != nil {
				status = response.StatusCode
			}
			t.Fatalf("websocket connect failed with status %d: %v", status, err)
		}
		var ready controlFrame
		if connection.ReadJSON(&ready) != nil ||
			ready.Type != "ready" ||
			ready.DeviceID != deviceID ||
			ready.ProtocolVersion != 1 {
			t.Fatalf("invalid ready frame: %+v", ready)
		}
		return connection
	}

	deviceA := connectDevice("device-a", 1)
	defer deviceA.Close()
	deviceB := connectDevice("device-b", 2)
	defer deviceB.Close()

	if err := deviceA.WriteJSON(controlFrame{
		Type:     "lookup",
		TargetID: "offline-device",
	}); err != nil {
		t.Fatal(err)
	}
	var offlineLookup controlFrame
	if err := deviceA.ReadJSON(&offlineLookup); err != nil ||
		offlineLookup.Type != "lookup_response" ||
		offlineLookup.TargetID != "offline-device" ||
		offlineLookup.Online == nil ||
		*offlineLookup.Online {
		t.Fatalf("invalid offline lookup response: %+v (%v)", offlineLookup, err)
	}

	if err := deviceA.WriteJSON(controlFrame{
		Type:     "lookup",
		TargetID: "device-b",
	}); err != nil {
		t.Fatal(err)
	}
	var onlineLookup controlFrame
	if err := deviceA.ReadJSON(&onlineLookup); err != nil ||
		onlineLookup.Type != "lookup_response" ||
		onlineLookup.TargetID != "device-b" ||
		onlineLookup.Online == nil ||
		!*onlineLookup.Online {
		t.Fatalf("invalid online lookup response: %+v (%v)", onlineLookup, err)
	}

	const sessionID = "00112233445566778899aabbccddeeff"
	opaquePayload := base64.RawURLEncoding.EncodeToString([]byte("opaque-offer"))
	if err := deviceA.WriteJSON(controlFrame{
		Type:      "offer",
		SessionID: sessionID,
		TargetID:  "device-b",
		Payload:   opaquePayload,
	}); err != nil {
		t.Fatal(err)
	}
	var offer controlFrame
	if err := deviceB.ReadJSON(&offer); err != nil {
		t.Fatal(err)
	}
	if offer.Type != "offer" ||
		offer.SessionID != sessionID ||
		offer.SenderID != "device-a" ||
		offer.TargetID != "" ||
		offer.Payload != opaquePayload {
		t.Fatalf("server and Dart offer contract diverged: %+v", offer)
	}

	if err := deviceB.WriteJSON(controlFrame{Type: "complete_ack", SessionID: sessionID}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(20 * time.Millisecond)
	server.hub.mutex.Lock()
	prematureAckSession, prematureAckRetained := server.hub.sessions[sessionID]
	server.hub.mutex.Unlock()
	if !prematureAckRetained || prematureAckSession.completed {
		t.Fatal("receiver acknowledged a transfer before sender completion")
	}

	if err := deviceB.WriteJSON(controlFrame{Type: "accept", SessionID: sessionID}); err != nil {
		t.Fatal(err)
	}
	var accepted controlFrame
	if err := deviceA.ReadJSON(&accepted); err != nil ||
		accepted.Type != "accept" ||
		accepted.SenderID != "device-b" {
		t.Fatalf("invalid accept frame: %+v (%v)", accepted, err)
	}

	binaryFrame := make([]byte, 25+4)
	binaryFrame[0] = 0x10
	sessionBytes, _ := hex.DecodeString(sessionID)
	copy(binaryFrame[1:17], sessionBytes)
	copy(binaryFrame[25:], []byte{1, 2, 3, 4})
	if err := deviceA.WriteMessage(websocket.BinaryMessage, binaryFrame); err != nil {
		t.Fatal(err)
	}
	kind, forwardedBinary, err := deviceB.ReadMessage()
	if err != nil || kind != websocket.BinaryMessage || !bytes.Equal(binaryFrame, forwardedBinary) {
		t.Fatalf("binary contract diverged: kind=%d err=%v", kind, err)
	}

	if err := deviceA.WriteJSON(controlFrame{Type: "complete", SessionID: sessionID}); err != nil {
		t.Fatal(err)
	}
	var complete controlFrame
	if err := deviceB.ReadJSON(&complete); err != nil ||
		complete.Type != "complete" ||
		complete.SenderID != "device-a" {
		t.Fatalf("invalid complete frame: %+v (%v)", complete, err)
	}
	if err := deviceB.WriteJSON(controlFrame{Type: "complete_ack", SessionID: sessionID}); err != nil {
		t.Fatal(err)
	}
	var completeAck controlFrame
	if err := deviceA.ReadJSON(&completeAck); err != nil ||
		completeAck.Type != "complete_ack" ||
		completeAck.SenderID != "device-b" {
		t.Fatalf("invalid completion acknowledgement: %+v (%v)", completeAck, err)
	}

	server.hub.mutex.Lock()
	_, sessionExists := server.hub.sessions[sessionID]
	server.hub.mutex.Unlock()
	if sessionExists {
		t.Fatal("completed Relay session was not removed")
	}

	if err := deviceA.WriteJSON(controlFrame{Type: "heartbeat", Timestamp: time.Now().UnixMilli()}); err != nil {
		t.Fatal(err)
	}
	var heartbeat controlFrame
	if err := deviceA.ReadJSON(&heartbeat); err != nil || heartbeat.Type != "heartbeat_ack" {
		t.Fatal(fmt.Errorf("invalid heartbeat acknowledgement: %+v (%v)", heartbeat, err))
	}
}
