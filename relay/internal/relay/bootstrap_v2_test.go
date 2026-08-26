// Relay Bootstrap V2 endpoints: dual /v1 and /v2 enroll/refresh support with
// protocol-version pinning at enroll, transcript binding at refresh, and
// downgrade protection during re-enrollment.

package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// newBootstrapV2TestServer constructs a memory-only Relay test server whose
// routes are registered on an httptest server and returns its base URL.
func newBootstrapV2TestServer(t *testing.T) string {
	t.Helper()
	server := NewServer(Config{
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: "test-token",
		CredentialTTL:   time.Hour,
	})
	t.Cleanup(server.Close)
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	httpServer := httptest.NewServer(mux)
	t.Cleanup(httpServer.Close)
	return httpServer.URL
}

// bootstrapKeyPair generates an Ed25519 keypair for enrollment tests.
func bootstrapKeyPair(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return publicKey, privateKey
}

// postBootstrapJSON posts a raw JSON body to the given path on the test server
// and returns the HTTP status plus the response body.
func postBootstrapJSON(t *testing.T, baseURL, path string, body []byte) (int, []byte) {
	t.Helper()
	response, err := http.Post(baseURL+path, "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	return response.StatusCode, responseBody
}

// enrollBootstrapHTTP posts an enroll request to the given path and returns the
// HTTP status and raw response body.
func enrollBootstrapHTTP(t *testing.T, baseURL, path, deviceID, token string, publicKey ed25519.PublicKey, protocolVersion uint32) (int, []byte) {
	t.Helper()
	body, err := json.Marshal(enrollRequest{
		DeviceID:        deviceID,
		PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
		EnrollmentToken: token,
		ProtocolVersion: protocolVersion,
		Platform:        "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	return postBootstrapJSON(t, baseURL, path, body)
}

// refreshBootstrapHTTP signs a refresh request over the exact transcript for
// the given path and returns the HTTP status and raw response body.
func refreshBootstrapHTTP(t *testing.T, baseURL, path, deviceID string, publicKey ed25519.PublicKey, privateKey ed25519.PrivateKey) (int, []byte) {
	t.Helper()
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x2a}, 32))
	timestamp := time.Now().Unix()
	payload := refreshProofPayloadForPath(path, timestamp, nonce)
	body, err := json.Marshal(refreshRequest{
		DeviceID:  deviceID,
		PublicKey: base64.RawURLEncoding.EncodeToString(publicKey),
		Timestamp: timestamp,
		Nonce:     nonce,
		Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, []byte(payload))),
	})
	if err != nil {
		t.Fatal(err)
	}
	return postBootstrapJSON(t, baseURL, path, body)
}

// decodeEnrollResponse decodes an enroll/refresh HTTP response envelope.
func decodeEnrollResponse(t *testing.T, body []byte, status int) enrollResponse {
	t.Helper()
	if status != http.StatusOK {
		t.Fatalf("expected 200, got %d (body=%s)", status, body)
	}
	var resp enrollResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("decode enroll response: %v (body=%s)", err, body)
	}
	return resp
}

// decodeNetworkError decodes a device-plane network error response envelope.
func decodeNetworkError(t *testing.T, body []byte, status int, wantStatus int) networkErrorResponse {
	t.Helper()
	if status != wantStatus {
		t.Fatalf("expected %d, got %d (body=%s)", wantStatus, status, body)
	}
	var errBody networkErrorResponse
	if err := json.Unmarshal(body, &errBody); err != nil {
		t.Fatalf("decode network error: %v (body=%s)", err, body)
	}
	return errBody
}

// TestBootstrapV1EnrollAndRefreshWithProtocolVersion1 locks the legacy /v1
// enroll and refresh behavior against the shared bootstrap handlers.
func TestBootstrapV1EnrollAndRefreshWithProtocolVersion1(t *testing.T) {
	baseURL := newBootstrapV2TestServer(t)
	publicKey, privateKey := bootstrapKeyPair(t)

	status, body := enrollBootstrapHTTP(t, baseURL, "/v1/devices/enroll", "device-1", "test-token", publicKey, 1)
	resp := decodeEnrollResponse(t, body, status)
	if resp.Credential == "" || resp.ProtocolVersion != 1 {
		t.Fatalf("v1 enroll response invalid: %+v", resp)
	}

	status, body = refreshBootstrapHTTP(t, baseURL, "/v1/devices/refresh", "device-1", publicKey, privateKey)
	refreshed := decodeEnrollResponse(t, body, status)
	if refreshed.Credential == "" || refreshed.ProtocolVersion != 1 {
		t.Fatalf("v1 refresh response invalid: %+v", refreshed)
	}
}

// TestBootstrapV2EnrollAndRefreshWithProtocolVersion2 locks the new /v2
// enroll and refresh against the shared bootstrap handlers.
func TestBootstrapV2EnrollAndRefreshWithProtocolVersion2(t *testing.T) {
	baseURL := newBootstrapV2TestServer(t)
	publicKey, privateKey := bootstrapKeyPair(t)

	status, body := enrollBootstrapHTTP(t, baseURL, "/v2/devices/enroll", "device-2", "test-token", publicKey, 2)
	resp := decodeEnrollResponse(t, body, status)
	if resp.Credential == "" || resp.ProtocolVersion != 2 {
		t.Fatalf("v2 enroll response invalid: %+v", resp)
	}

	status, body = refreshBootstrapHTTP(t, baseURL, "/v2/devices/refresh", "device-2", publicKey, privateKey)
	refreshed := decodeEnrollResponse(t, body, status)
	if refreshed.Credential == "" || refreshed.ProtocolVersion != 2 {
		t.Fatalf("v2 refresh response invalid: %+v", refreshed)
	}
}

// TestBootstrapV1EnrollRejectsProtocolVersionNotOne pins the /v1 enroll
// protocol-version gate at exactly 1.
func TestBootstrapV1EnrollRejectsProtocolVersionNotOne(t *testing.T) {
	baseURL := newBootstrapV2TestServer(t)
	publicKey, _ := bootstrapKeyPair(t)

	for _, version := range []uint32{0, 2, 3} {
		status, body := enrollBootstrapHTTP(t, baseURL, "/v1/devices/enroll", "device-1", "test-token", publicKey, version)
		errBody := decodeNetworkError(t, body, status, http.StatusBadRequest)
		if errBody.Code != relayErrorProtocolError {
			t.Fatalf("v1 enroll protocol_version=%d: expected code %d, got %d", version, relayErrorProtocolError, errBody.Code)
		}
	}
}

// TestBootstrapV2EnrollRejectsProtocolVersionNotTwo pins the /v2 enroll
// protocol-version gate at exactly 2.
func TestBootstrapV2EnrollRejectsProtocolVersionNotTwo(t *testing.T) {
	baseURL := newBootstrapV2TestServer(t)
	publicKey, _ := bootstrapKeyPair(t)

	for _, version := range []uint32{0, 1, 3} {
		status, body := enrollBootstrapHTTP(t, baseURL, "/v2/devices/enroll", "device-2", "test-token", publicKey, version)
		errBody := decodeNetworkError(t, body, status, http.StatusBadRequest)
		if errBody.Code != relayErrorProtocolError {
			t.Fatalf("v2 enroll protocol_version=%d: expected code %d, got %d", version, relayErrorProtocolError, errBody.Code)
		}
	}
}

// TestBootstrapV2RefreshRejectsV1Transcript verifies that a signature over the
// V1 refresh transcript cannot authenticate against the V2 refresh route.
func TestBootstrapV2RefreshRejectsV1Transcript(t *testing.T) {
	baseURL := newBootstrapV2TestServer(t)
	publicKey, privateKey := bootstrapKeyPair(t)

	status, body := enrollBootstrapHTTP(t, baseURL, "/v2/devices/enroll", "device-2", "test-token", publicKey, 2)
	if status != http.StatusOK {
		t.Fatalf("v2 enroll: expected 200, got %d (body=%s)", status, body)
	}

	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x2b}, 32))
	timestamp := time.Now().Unix()
	// Sign over the V1 transcript while presenting the request at the V2 route.
	refreshBody, err := json.Marshal(refreshRequest{
		DeviceID:  "device-2",
		PublicKey: base64.RawURLEncoding.EncodeToString(publicKey),
		Timestamp: timestamp,
		Nonce:     nonce,
		Signature: base64.RawURLEncoding.EncodeToString(
			ed25519.Sign(privateKey, []byte(refreshProofPayload(timestamp, nonce))),
		),
	})
	if err != nil {
		t.Fatal(err)
	}
	status, body = postBootstrapJSON(t, baseURL, "/v2/devices/refresh", refreshBody)
	errBody := decodeNetworkError(t, body, status, http.StatusUnauthorized)
	if errBody.Code != relayErrorAuthenticationFailed {
		t.Fatalf("v2 refresh signed over v1 transcript: expected code %d, got %d", relayErrorAuthenticationFailed, errBody.Code)
	}
}

// TestBootstrapV1RefreshRejectsV2Transcript verifies that a signature over the
// V2 refresh transcript cannot authenticate against the V1 refresh route.
func TestBootstrapV1RefreshRejectsV2Transcript(t *testing.T) {
	baseURL := newBootstrapV2TestServer(t)
	publicKey, privateKey := bootstrapKeyPair(t)

	status, body := enrollBootstrapHTTP(t, baseURL, "/v1/devices/enroll", "device-1", "test-token", publicKey, 1)
	if status != http.StatusOK {
		t.Fatalf("v1 enroll: expected 200, got %d (body=%s)", status, body)
	}

	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x2c}, 32))
	timestamp := time.Now().Unix()
	// Sign over the V2 transcript while presenting the request at the V1 route.
	refreshBody, err := json.Marshal(refreshRequest{
		DeviceID:  "device-1",
		PublicKey: base64.RawURLEncoding.EncodeToString(publicKey),
		Timestamp: timestamp,
		Nonce:     nonce,
		Signature: base64.RawURLEncoding.EncodeToString(
			ed25519.Sign(privateKey, []byte(refreshProofPayloadForPath("/v2/devices/refresh", timestamp, nonce))),
		),
	})
	if err != nil {
		t.Fatal(err)
	}
	status, body = postBootstrapJSON(t, baseURL, "/v1/devices/refresh", refreshBody)
	errBody := decodeNetworkError(t, body, status, http.StatusUnauthorized)
	if errBody.Code != relayErrorAuthenticationFailed {
		t.Fatalf("v1 refresh signed over v2 transcript: expected code %d, got %d", relayErrorAuthenticationFailed, errBody.Code)
	}
}

// TestBootstrapDowngradeProtectionRejectsV2ToV1Enroll verifies that re-enrolling
// a V2 device over the V1 route is rejected as a protocol downgrade.
func TestBootstrapDowngradeProtectionRejectsV2ToV1Enroll(t *testing.T) {
	baseURL := newBootstrapV2TestServer(t)
	publicKey, _ := bootstrapKeyPair(t)

	status, body := enrollBootstrapHTTP(t, baseURL, "/v2/devices/enroll", "device-2", "test-token", publicKey, 2)
	if status != http.StatusOK {
		t.Fatalf("v2 enroll: expected 200, got %d (body=%s)", status, body)
	}

	status, body = enrollBootstrapHTTP(t, baseURL, "/v1/devices/enroll", "device-2", "test-token", publicKey, 1)
	errBody := decodeNetworkError(t, body, status, http.StatusConflict)
	if errBody.Code != relayErrorIdentityConflict {
		t.Fatalf("v2->v1 downgrade enroll: expected code %d, got %d", relayErrorIdentityConflict, errBody.Code)
	}
}

// TestBootstrapUpgradeReEnrollHonorsV2 verifies that a V1 device re-enrolling as
// V2 is accepted (protocol upgrade), advances the enrollment generation, and
// persists protocol_version=2.
func TestBootstrapUpgradeReEnrollHonorsV2(t *testing.T) {
	publicKey, _ := bootstrapKeyPair(t)
	server := NewServer(Config{
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: "test-token",
		CredentialTTL:   time.Hour,
	})
	defer server.Close()
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	enroll := func(deviceID, path string, version uint32) *httptest.ResponseRecorder {
		t.Helper()
		body, err := json.Marshal(enrollRequest{
			DeviceID:        deviceID,
			PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
			EnrollmentToken: "test-token",
			ProtocolVersion: version,
			Platform:        "test",
		})
		if err != nil {
			t.Fatal(err)
		}
		request, err := http.NewRequest(http.MethodPost, path, bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, request)
		return rec
	}

	first := enroll("device-upgrade", "/v1/devices/enroll", 1)
	if first.Code != http.StatusOK {
		t.Fatalf("v1 initial enroll: expected 200, got %d", first.Code)
	}
	generationBefore := mustEnrollmentGeneration(t, server, "device-upgrade")

	upgrade := enroll("device-upgrade", "/v2/devices/enroll", 2)
	if upgrade.Code != http.StatusOK {
		t.Fatalf("v1->v2 upgrade enroll: expected 200, got %d (%s)", upgrade.Code, upgrade.Body.String())
	}
	resp := decodeEnrollResponse(t, upgrade.Body.Bytes(), upgrade.Code)
	if resp.ProtocolVersion != 2 {
		t.Fatalf("upgrade enroll response protocol_version: expected 2, got %d", resp.ProtocolVersion)
	}

	stored, err := server.store.GetEnrollment(context.Background(), "device-upgrade")
	if err != nil || stored == nil {
		t.Fatalf("load upgraded enrollment: err=%v", err)
	}
	if stored.ProtocolVersion != 2 {
		t.Fatalf("stored protocol_version after upgrade: expected 2, got %d", stored.ProtocolVersion)
	}
	generationAfter := stored.EnrolledAt.UnixMicro()
	if generationAfter <= generationBefore {
		t.Fatalf("upgrade enrollment did not advance generation: before=%d after=%d", generationBefore, generationAfter)
	}
}
