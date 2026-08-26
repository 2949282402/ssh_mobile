// Relay Bootstrap V2 tests: V2-only enroll/refresh,
// ProtocolVersion=2 admission invariant, and re-enroll upgrade semantics.

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
// routes are registered on an httptest server and returns its base URL and server instance.
func newBootstrapV2TestServer(t *testing.T) (string, *Server) {
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
	return httpServer.URL, server
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

// TestBootstrapV2EnrollAndRefreshWithProtocolVersion2 verifies that /v2/devices/enroll
// and /v2/devices/refresh work exclusively with ProtocolVersion=2 and V2 transcript.
func TestBootstrapV2EnrollAndRefreshWithProtocolVersion2(t *testing.T) {
	baseURL, _ := newBootstrapV2TestServer(t)
	publicKey, privateKey := bootstrapKeyPair(t)

	status, body := enrollBootstrapHTTP(t, baseURL, PathEnrollV2, "device-2", "test-token", publicKey, RelayBootstrapProtocolVersion)
	resp := decodeEnrollResponse(t, body, status)
	if resp.Credential == "" || resp.ProtocolVersion != RelayBootstrapProtocolVersion {
		t.Fatalf("v2 enroll response invalid: %+v", resp)
	}

	status, body = refreshBootstrapHTTP(t, baseURL, PathRefreshV2, "device-2", publicKey, privateKey)
	refreshed := decodeEnrollResponse(t, body, status)
	if refreshed.Credential == "" || refreshed.ProtocolVersion != RelayBootstrapProtocolVersion {
		t.Fatalf("v2 refresh response invalid: %+v", refreshed)
	}
}

// TestBootstrapV2EnrollRejectsProtocolVersionNotTwo pins the /v2 enroll
// protocol-version gate at exactly 2.
func TestBootstrapV2EnrollRejectsProtocolVersionNotTwo(t *testing.T) {
	baseURL, _ := newBootstrapV2TestServer(t)
	publicKey, _ := bootstrapKeyPair(t)

	for _, version := range []uint32{0, 1, 3} {
		status, body := enrollBootstrapHTTP(t, baseURL, PathEnrollV2, "device-2", "test-token", publicKey, version)
		errBody := decodeNetworkError(t, body, status, http.StatusBadRequest)
		if errBody.Code != relayErrorProtocolError {
			t.Fatalf("v2 enroll protocol_version=%d: expected code %d, got %d", version, relayErrorProtocolError, errBody.Code)
		}
	}
}

// TestBootstrapV2RefreshRejectsMismatchedTranscript verifies that a signature over a
// mismatched refresh transcript cannot authenticate against the V2 refresh route.
func TestBootstrapV2RefreshRejectsMismatchedTranscript(t *testing.T) {
	baseURL, _ := newBootstrapV2TestServer(t)
	publicKey, privateKey := bootstrapKeyPair(t)

	status, body := enrollBootstrapHTTP(t, baseURL, PathEnrollV2, "device-2", "test-token", publicKey, RelayBootstrapProtocolVersion)
	if status != http.StatusOK {
		t.Fatalf("v2 enroll: expected 200, got %d (body=%s)", status, body)
	}

	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x2b}, 32))
	timestamp := time.Now().Unix()
	refreshBody, err := json.Marshal(refreshRequest{
		DeviceID:  "device-2",
		PublicKey: base64.RawURLEncoding.EncodeToString(publicKey),
		Timestamp: timestamp,
		Nonce:     nonce,
		Signature: base64.RawURLEncoding.EncodeToString(
			ed25519.Sign(privateKey, []byte(refreshProofPayloadForPath("/v2/devices/mismatched", timestamp, nonce))),
		),
	})
	if err != nil {
		t.Fatal(err)
	}
	status, body = postBootstrapJSON(t, baseURL, PathRefreshV2, refreshBody)
	errBody := decodeNetworkError(t, body, status, http.StatusUnauthorized)
	if errBody.Code != relayErrorAuthenticationFailed {
		t.Fatalf("v2 refresh signed over mismatched transcript: expected code %d, got %d", relayErrorAuthenticationFailed, errBody.Code)
	}
}

// TestBootstrapV2RefreshRejectsProtocolVersion1DurableRow verifies that a legacy
// enrollment with protocol_version=1 cannot refresh on /v2/devices/refresh and returns 404.
func TestBootstrapV2RefreshRejectsProtocolVersion1DurableRow(t *testing.T) {
	baseURL, server := newBootstrapV2TestServer(t)
	publicKey, privateKey := bootstrapKeyPair(t)
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)

	// Seed a legacy ProtocolVersion=1 durable enrollment
	if result := server.replaceEnrollment("device-legacy-v1", encodedKey, "linux", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("seed legacy enrollment: %v", result)
	}

	status, body := refreshBootstrapHTTP(t, baseURL, PathRefreshV2, "device-legacy-v1", publicKey, privateKey)
	if status != http.StatusNotFound {
		t.Fatalf("v2 refresh for v1 durable row status = %d (body=%s), want 404", status, body)
	}
}

// TestBootstrapAdmissionRejectsProtocolVersion1DurableRow verifies that a credential
// issued under ProtocolVersion=1 fails /v2/control admission.
func TestBootstrapAdmissionRejectsProtocolVersion1DurableRow(t *testing.T) {
	_, server := newBootstrapV2TestServer(t)
	publicKey, privateKey := bootstrapKeyPair(t)
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)

	now := time.Now()
	if result := server.replaceEnrollment("device-legacy-v1", encodedKey, "linux", 1, now); result != enrollmentOK {
		t.Fatalf("seed legacy enrollment: %v", result)
	}

	credential, err := issueCredential(server.config.CredentialKey, "device-legacy-v1", publicKey, now.UnixMicro(), time.Hour)
	if err != nil {
		t.Fatalf("issue credential: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, PathControlV2, nil)
	req.Header.Set("Authorization", "Bearer "+credential)
	nonce := base64.RawURLEncoding.EncodeToString(randomBytes(32))
	setCurrentSignedDeviceProof(req.Header, http.MethodGet, PathControlV2, privateKey, nonce)

	if _, _, code, ok := server.authenticatedRequest(req); ok || code != relayErrorAuthenticationFailed {
		t.Fatalf("v1 durable enrollment admitted to /v2/control: ok=%v code=%d", ok, code)
	}

	// The same protocol-version gate must block /v2/relay/* data-plane admission.
	relayURL := PathRelayDataV2 + "00112233445566778899aabbccddeeff"
	relayReq := httptest.NewRequest(http.MethodGet, relayURL, nil)
	relayReq.SetPathValue("reservation_id", "00112233445566778899aabbccddeeff")
	relayReq.Header.Set("Authorization", "Bearer "+credential)
	relayReq.Header.Set("X-Relay-Token", "0102030405060708090a0b0c0d0e0f10")
	nonce = base64.RawURLEncoding.EncodeToString(randomBytes(32))
	setCurrentSignedDeviceProof(relayReq.Header, http.MethodGet, relayURL, privateKey, nonce)
	response := httptest.NewRecorder()
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	mux.ServeHTTP(response, relayReq)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("v1 durable enrollment admitted to /v2/relay: status=%d body=%s", response.Code, response.Body.String())
	}
}

// TestBootstrapUpgradeReEnrollHonorsV2 verifies that a legacy V1 enrollment
// re-enrolling as V2 is accepted (protocol upgrade), advances the enrollment generation, and
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

	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	// Seed legacy V1 enrollment directly in store
	initialTime := time.Now().Add(-time.Hour)
	if result := server.replaceEnrollment("device-upgrade", encodedKey, "test", 1, initialTime); result != enrollmentOK {
		t.Fatalf("seed initial v1 enrollment: %v", result)
	}
	generationBefore := initialTime.UnixMicro()

	enroll := func(deviceID, path string, version uint32) *httptest.ResponseRecorder {
		t.Helper()
		body, err := json.Marshal(enrollRequest{
			DeviceID:        deviceID,
			PublicKey:       encodedKey,
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

	upgrade := enroll("device-upgrade", PathEnrollV2, RelayBootstrapProtocolVersion)
	if upgrade.Code != http.StatusOK {
		t.Fatalf("v1->v2 upgrade enroll: expected 200, got %d (%s)", upgrade.Code, upgrade.Body.String())
	}
	resp := decodeEnrollResponse(t, upgrade.Body.Bytes(), upgrade.Code)
	if resp.ProtocolVersion != RelayBootstrapProtocolVersion {
		t.Fatalf("upgrade enroll response protocol_version: expected 2, got %d", resp.ProtocolVersion)
	}

	stored, err := server.store.GetEnrollment(context.Background(), "device-upgrade")
	if err != nil || stored == nil {
		t.Fatalf("load upgraded enrollment: err=%v", err)
	}
	if stored.ProtocolVersion != RelayBootstrapProtocolVersion {
		t.Fatalf("stored protocol_version after upgrade: expected 2, got %d", stored.ProtocolVersion)
	}
	generationAfter := stored.EnrolledAt.UnixMicro()
	if generationAfter <= generationBefore {
		t.Fatalf("upgrade enrollment did not advance generation: before=%d after=%d", generationBefore, generationAfter)
	}

	// Downgrade attempt: re-enroll with protocol_version 1 must be rejected
	downgradeDevice := &EnrolledDevice{
		DeviceID:        "device-upgrade",
		PublicKey:       encodedKey,
		Platform:        "test",
		ProtocolVersion: 1,
		EnrolledAt:      time.Now(),
	}
	result, err := server.store.PutEnrollment(context.Background(), downgradeDevice)
	if err != nil || result != enrollmentIdentityConflict {
		t.Fatalf("downgrade storage result = %v (err=%v), want enrollmentIdentityConflict", result, err)
	}
}
