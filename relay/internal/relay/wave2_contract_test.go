// Wave-2 protocol-contract tests: expired-credential connect code, identity
// conflict at enroll, retry disposition on device-plane errors, and the
// /v1/devices/refresh endpoint.

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
)

func TestConnectExpiredCredentialReturnsCode12(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey: []byte("01234567890123456789012345678901"),
		CredentialTTL: time.Hour,
	})
	defer server.Close()
	if _, err := server.store.PutEnrollment(context.Background(), &EnrolledDevice{
		DeviceID:        "device-a",
		PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
		ProtocolVersion: 1,
		EnrolledAt:      time.Now(),
	}); err != nil {
		t.Fatal(err)
	}

	// A credential whose expiry is already in the past.
	expired, err := issueCredential(server.config.CredentialKey, "device-a", publicKey, mustEnrollmentGeneration(t, server, "device-a"), -time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{4}, 32))
	request := httptest.NewRequest("GET", "/v2/control", nil)
	request.Header.Set("Authorization", "Bearer "+expired)
	setCurrentSignedDeviceProof(request.Header, http.MethodGet, "/v2/control", privateKey, nonce)

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, request)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for expired credential, got %d", rec.Code)
	}
	var body networkErrorResponse
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.Code != relayErrorCredentialExpired {
		t.Fatalf("expected code 12, got %d", body.Code)
	}
	if body.RetryDisposition != retryRefreshCredentialThenRetry {
		t.Fatalf("expected retry_disposition 4, got %d", body.RetryDisposition)
	}
}

func TestReadyReportsConfiguredPresenceTTL(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	server.config.PresenceTTL = 7 * time.Second
	credential, privateKey := enrollV2(t, httpServer.URL, "device-a")
	conn := dialControlV2NoReady(t, httpServer.URL, credential, "device-a", privateKey)
	defer conn.Close()
	ready := readV2ControlFrame(t, conn).GetReady()
	if ready == nil || ready.PresenceTtlS != 7 {
		t.Fatalf("Ready did not report configured presence TTL: %+v", ready)
	}
}

func TestShortCredentialTTLExpiresBeforeReadyAdmission(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	const shortCredentialTTL = 2 * time.Second
	server := NewServer(Config{
		CredentialKey: []byte("01234567890123456789012345678901"),
		CredentialTTL: shortCredentialTTL,
	})
	defer server.Close()
	if _, err := server.store.PutEnrollment(context.Background(), &EnrolledDevice{
		DeviceID:        "device-a",
		PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
		ProtocolVersion: 1,
		EnrolledAt:      time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	credential, err := issueCredential(server.config.CredentialKey, "device-a", publicKey, mustEnrollmentGeneration(t, server, "device-a"), shortCredentialTTL)
	if err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for {
		_, _, verifyErr := verifyCredential(server.config.CredentialKey, credential)
		if errors.Is(verifyErr, errCredentialExpired) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("short credential TTL did not expire: err=%v", verifyErr)
		}
		time.Sleep(25 * time.Millisecond)
	}

	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x43}, 32))
	request := httptest.NewRequest("GET", "/v2/control", nil)
	request.Header.Set("Authorization", "Bearer "+credential)
	setCurrentSignedDeviceProof(request.Header, http.MethodGet, "/v2/control", privateKey, nonce)
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, request)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expired short-TTL credential opened Ready admission: %d", rec.Code)
	}
	var body networkErrorResponse
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.Code != relayErrorCredentialExpired || body.RetryDisposition != retryRefreshCredentialThenRetry {
		t.Fatalf("unexpected short-TTL expiry response: %+v", body)
	}
}

func TestConnectGenericAuthFailureKeepsCode2(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey: []byte("01234567890123456789012345678901"),
		CredentialTTL: time.Hour,
	})
	defer server.Close()
	if _, err := server.store.PutEnrollment(context.Background(), &EnrolledDevice{
		DeviceID:        "device-a",
		PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
		ProtocolVersion: 1,
		EnrolledAt:      time.Now(),
	}); err != nil {
		t.Fatal(err)
	}

	credential, err := issueCredential(server.config.CredentialKey, "device-a", publicKey, mustEnrollmentGeneration(t, server, "device-a"), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{4}, 32))
	request := httptest.NewRequest("GET", "/v2/control", nil)
	request.Header.Set("Authorization", "Bearer "+credential)
	// Sign with the wrong key: a non-expired but invalid proof.
	_, wrongPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	setCurrentSignedDeviceProof(request.Header, http.MethodGet, "/v2/control", wrongPrivate, nonce)

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, request)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
	var body networkErrorResponse
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.Code != relayErrorAuthenticationFailed {
		t.Fatalf("expected code 2, got %d", body.Code)
	}
	if body.RetryDisposition != retryUnspecified {
		t.Fatalf("generic auth failure must omit retry_disposition, got %d", body.RetryDisposition)
	}
}

func TestIdentityConflictAtEnrollRejectsDifferentKey(t *testing.T) {
	key1, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	key2, _, err := ed25519.GenerateKey(rand.Reader)
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

	enroll := func(key ed25519.PublicKey) *httptest.ResponseRecorder {
		t.Helper()
		body, _ := json.Marshal(enrollRequest{
			DeviceID:        "device-a",
			PublicKey:       base64.RawURLEncoding.EncodeToString(key),
			EnrollmentToken: "test-token",
			ProtocolVersion: 1,
			Platform:        "test",
		})
		request := httptest.NewRequest("POST", "/v1/devices/enroll", bytes.NewReader(body))
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, request)
		return rec
	}

	if rec := enroll(key1); rec.Code != http.StatusOK {
		t.Fatalf("initial enroll: expected 200, got %d", rec.Code)
	}

	conflict := enroll(key2)
	if conflict.Code != http.StatusConflict {
		t.Fatalf("conflicting enroll: expected 409, got %d", conflict.Code)
	}
	var body networkErrorResponse
	if err := json.NewDecoder(conflict.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.Code != relayErrorIdentityConflict {
		t.Fatalf("expected code 13, got %d", body.Code)
	}
	if body.Message != "Relay device identity conflicts with an existing enrollment." {
		t.Fatalf("unexpected conflict message: %q", body.Message)
	}

	stored, _ := server.store.GetEnrollment(context.Background(), "device-a")
	if stored == nil || stored.PublicKey != base64.RawURLEncoding.EncodeToString(key1) {
		t.Fatal("conflicting enroll overwrote the existing enrollment")
	}

	if rec := enroll(key1); rec.Code != http.StatusOK {
		t.Fatalf("same-key re-enroll: expected 200, got %d", rec.Code)
	}
}

func TestEnrollResourceLimitSetsRetryDisposition(t *testing.T) {
	keyA, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	keyB, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey:      []byte("01234567890123456789012345678901"),
		EnrollmentToken:    "test-token",
		CredentialTTL:      time.Hour,
		MaxEnrolledDevices: 1,
	})
	defer server.Close()
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	enroll := func(deviceID string, key ed25519.PublicKey) *httptest.ResponseRecorder {
		t.Helper()
		body, _ := json.Marshal(enrollRequest{
			DeviceID:        deviceID,
			PublicKey:       base64.RawURLEncoding.EncodeToString(key),
			EnrollmentToken: "test-token",
			ProtocolVersion: 1,
			Platform:        "test",
		})
		request := httptest.NewRequest("POST", "/v1/devices/enroll", bytes.NewReader(body))
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, request)
		return rec
	}

	if rec := enroll("device-a", keyA); rec.Code != http.StatusOK {
		t.Fatalf("initial enroll: expected 200, got %d", rec.Code)
	}
	limited := enroll("device-b", keyB)
	if limited.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 at capacity, got %d", limited.Code)
	}
	if limited.Header().Get("Retry-After") != "30" {
		t.Fatalf("expected Retry-After header 30, got %q", limited.Header().Get("Retry-After"))
	}
	var body networkErrorResponse
	if err := json.NewDecoder(limited.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.RetryDisposition != retryAfter {
		t.Fatalf("expected retry_disposition 3, got %d", body.RetryDisposition)
	}
	if body.RetryAfterSeconds != enrollResourceRetryAfterSeconds {
		t.Fatalf("expected retry_after_seconds 30, got %d", body.RetryAfterSeconds)
	}
}

func TestRefreshCredentialIssuesFreshCredential(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey: []byte("01234567890123456789012345678901"),
		CredentialTTL: time.Hour,
	})
	defer server.Close()
	if server.replaceEnrollment("device-a", base64.RawURLEncoding.EncodeToString(publicKey), "test", 1, time.Now()) != enrollmentOK {
		t.Fatal("test device enrollment was rejected")
	}
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{5}, 32))
	timestamp := time.Now().Unix()
	body, _ := json.Marshal(refreshRequest{
		DeviceID:  "device-a",
		PublicKey: base64.RawURLEncoding.EncodeToString(publicKey),
		Timestamp: timestamp,
		Nonce:     nonce,
		Signature: base64.RawURLEncoding.EncodeToString(
			ed25519.Sign(privateKey, []byte(refreshProofPayload(timestamp, nonce))),
		),
	})
	request := httptest.NewRequest("POST", "/v1/devices/refresh", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, request)

	if rec.Code != http.StatusOK {
		t.Fatalf("refresh failed with status %d: %s", rec.Code, rec.Body.String())
	}
	var resp enrollResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	if resp.Credential == "" || resp.ProtocolVersion != 1 || resp.ExpiresAt <= time.Now().Unix() {
		t.Fatalf("unexpected refresh response: %+v", resp)
	}
	claims, restored, err := verifyCredential(server.config.CredentialKey, resp.Credential)
	if err != nil {
		t.Fatalf("refreshed credential did not verify: %v", err)
	}
	if claims.DeviceID != "device-a" || !bytes.Equal(restored, publicKey) {
		t.Fatalf("refreshed credential lost identity binding: %+v", claims)
	}
}

func TestRefreshCredentialUnknownDeviceReturns404(t *testing.T) {
	server := NewServer(Config{
		CredentialKey: []byte("01234567890123456789012345678901"),
		CredentialTTL: time.Hour,
	})
	defer server.Close()
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{6}, 32))
	body, _ := json.Marshal(refreshRequest{
		DeviceID:  "ghost-device",
		PublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, ed25519.PublicKeySize)),
		Timestamp: time.Now().Unix(),
		Nonce:     nonce,
		Signature: "x",
	})
	request := httptest.NewRequest("POST", "/v1/devices/refresh", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, request)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", rec.Code)
	}
	var errBody networkErrorResponse
	if err := json.NewDecoder(rec.Body).Decode(&errBody); err != nil {
		t.Fatal(err)
	}
	if errBody.Code != relayErrorInvalidArgument {
		t.Fatalf("expected code 1, got %d", errBody.Code)
	}
}

func TestRefreshCredentialBadSignatureReturns401(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	_, wrongPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey: []byte("01234567890123456789012345678901"),
		CredentialTTL: time.Hour,
	})
	defer server.Close()
	if server.replaceEnrollment("device-a", base64.RawURLEncoding.EncodeToString(publicKey), "test", 1, time.Now()) != enrollmentOK {
		t.Fatal("test device enrollment was rejected")
	}
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{8}, 32))
	timestamp := time.Now().Unix()
	body, _ := json.Marshal(refreshRequest{
		DeviceID:  "device-a",
		PublicKey: base64.RawURLEncoding.EncodeToString(publicKey),
		Timestamp: timestamp,
		Nonce:     nonce,
		Signature: base64.RawURLEncoding.EncodeToString(
			ed25519.Sign(wrongPrivate, []byte(refreshProofPayload(timestamp, nonce))),
		),
	})
	request := httptest.NewRequest("POST", "/v1/devices/refresh", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, request)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for bad signature, got %d", rec.Code)
	}
	var errBody networkErrorResponse
	if err := json.NewDecoder(rec.Body).Decode(&errBody); err != nil {
		t.Fatal(err)
	}
	if errBody.Code != relayErrorAuthenticationFailed {
		t.Fatalf("expected code 2, got %d", errBody.Code)
	}
}

func TestRefreshCredentialRejectsReplayedNonce(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey: []byte("01234567890123456789012345678901"),
		CredentialTTL: time.Hour,
	})
	defer server.Close()
	if server.replaceEnrollment("device-a", base64.RawURLEncoding.EncodeToString(publicKey), "test", 1, time.Now()) != enrollmentOK {
		t.Fatal("test device enrollment was rejected")
	}
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32))
	timestamp := time.Now().Unix()
	signature := base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, []byte(refreshProofPayload(timestamp, nonce))),
	)
	refresh := func() *httptest.ResponseRecorder {
		t.Helper()
		body, _ := json.Marshal(refreshRequest{
			DeviceID:  "device-a",
			PublicKey: base64.RawURLEncoding.EncodeToString(publicKey),
			Timestamp: timestamp,
			Nonce:     nonce,
			Signature: signature,
		})
		request := httptest.NewRequest("POST", "/v1/devices/refresh", bytes.NewReader(body))
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, request)
		return rec
	}

	if first := refresh(); first.Code != http.StatusOK {
		t.Fatalf("first refresh: expected 200, got %d", first.Code)
	}
	replayed := refresh()
	if replayed.Code != http.StatusUnauthorized {
		t.Fatalf("replayed refresh: expected 401, got %d", replayed.Code)
	}
	var errBody networkErrorResponse
	if err := json.NewDecoder(replayed.Body).Decode(&errBody); err != nil {
		t.Fatal(err)
	}
	if errBody.Code != relayErrorAuthenticationFailed {
		t.Fatalf("replayed refresh: expected code 2, got %d", errBody.Code)
	}
}
