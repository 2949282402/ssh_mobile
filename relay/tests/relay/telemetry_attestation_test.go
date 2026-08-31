package relay_test

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/ssh-mobile/relay/internal/relay"
)

const (
	testEnrollmentToken = "test-enrollment-token-0123456789"
	testInternalToken   = "test-internal-token-0123456789"
	testCredentialKey   = "01234567890123456789012345678901"
)

func TestInternalTelemetryAttestationValidatesCurrentRelayEnrollment(t *testing.T) {
	_, mux := newRelayTestServer(t)
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	credential := enrollRelayDevice(t, mux, "device-a", publicKey)

	nonce := encodedNonce(0x31)
	timestamp := time.Now().Unix()
	request := attestationRequest("device-a", credential, publicKey, privateKey, timestamp, nonce, relay.PathPublicTelemetryEnroll)
	rec := serveAttestation(mux, request, testInternalToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var response struct {
		DeviceID             string `json:"device_id"`
		EnrollmentGeneration int64  `json:"enrollment_generation"`
		ProtocolVersion      uint32 `json:"protocol_version"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.DeviceID != "device-a" || response.ProtocolVersion != relay.RelayBootstrapProtocolVersion || response.EnrollmentGeneration <= 0 {
		t.Fatalf("unexpected attestation response: %+v", response)
	}

	// Explicit rotation binds the proof to a distinct transcript target, so an
	// enrollment proof cannot be repurposed for rotation and vice versa.
	rotateNonce := encodedNonce(0x34)
	rotateTimestamp := time.Now().Unix()
	rotateRequest := attestationRequest("device-a", credential, publicKey, privateKey, rotateTimestamp, rotateNonce, relay.PathPublicTelemetryRotate)
	rotateRec := serveAttestation(mux, rotateRequest, testInternalToken)
	if rotateRec.Code != http.StatusOK {
		t.Fatalf("explicit rotation attestation status=%d: %s", rotateRec.Code, rotateRec.Body.String())
	}
}

func TestInternalTelemetryAttestationRejectsWrongDeviceAndReplay(t *testing.T) {
	_, mux := newRelayTestServer(t)
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	credential := enrollRelayDevice(t, mux, "device-a", publicKey)
	nonce := encodedNonce(0x32)
	timestamp := time.Now().Unix()

	wrongDevice := attestationRequest("device-b", credential, publicKey, privateKey, timestamp, nonce, relay.PathPublicTelemetryEnroll)
	if rec := serveAttestation(mux, wrongDevice, testInternalToken); rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong device status = %d, want 401", rec.Code)
	}
	valid := attestationRequest("device-a", credential, publicKey, privateKey, timestamp, nonce, relay.PathPublicTelemetryEnroll)
	if rec := serveAttestation(mux, valid, testInternalToken); rec.Code != http.StatusOK {
		t.Fatalf("valid attestation status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	replayed := attestationRequest("device-a", credential, publicKey, privateKey, timestamp, nonce, relay.PathPublicTelemetryEnroll)
	if rec := serveAttestation(mux, replayed, testInternalToken); rec.Code != http.StatusUnauthorized {
		t.Fatalf("replayed attestation status = %d, want 401", rec.Code)
	}
}

func TestInternalTelemetryAttestationRejectsUnregisteredWrongCredentialAndMissingProof(t *testing.T) {
	_, mux := newRelayTestServer(t)
	publicKeyA, privateKeyA, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	publicKeyB, privateKeyB, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	credentialA := enrollRelayDevice(t, mux, "device-a", publicKeyA)
	credentialB := enrollRelayDevice(t, mux, "device-b", publicKeyB)

	cases := []struct {
		name string
		req  *http.Request
	}{
		{
			name: "unregistered device",
			// Credential A is cryptographically valid but its claims are bound to
			// device-a, so it cannot attest an unregistered identity.
			req: attestationRequest("device-unregistered", credentialA, publicKeyA, privateKeyA, time.Now().Unix(), encodedNonce(0x41), relay.PathPublicTelemetryEnroll),
		},
		{
			name: "credential bound to another device",
			req:  attestationRequest("device-a", credentialB, publicKeyB, privateKeyB, time.Now().Unix(), encodedNonce(0x42), relay.PathPublicTelemetryEnroll),
		},
		{
			name: "missing proof",
			req:  httptest.NewRequest(http.MethodPost, relay.PathInternalTelemetryAttest, bytes.NewBufferString(`{"device_id":"device-a"}`)),
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tc.req.Header.Set("Authorization", "Bearer "+testInternalToken)
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, tc.req)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status=%d body=%s, want 401", rec.Code, rec.Body.String())
			}
		})
	}
}

func newRelayTestServer(t *testing.T) (*relay.Server, *http.ServeMux) {
	t.Helper()
	server := relay.NewServer(relay.Config{
		CredentialKey:   []byte(testCredentialKey),
		EnrollmentToken: testEnrollmentToken,
		InternalToken:   testInternalToken,
		CredentialTTL:   time.Hour,
		ProtocolVersion: relay.RelayBootstrapProtocolVersion,
	})
	t.Cleanup(server.Close)
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	return server, mux
}

func enrollRelayDevice(t *testing.T, mux *http.ServeMux, deviceID string, publicKey ed25519.PublicKey) string {
	t.Helper()
	body, err := json.Marshal(map[string]any{
		"device_id":        deviceID,
		"public_key":       base64.RawURLEncoding.EncodeToString(publicKey),
		"enrollment_token": testEnrollmentToken,
		"protocol_version": relay.RelayBootstrapProtocolVersion,
		"platform":         "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, relay.PathEnrollV2, bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("enrollment status=%d body=%s", rec.Code, rec.Body.String())
	}
	var response struct {
		Credential string `json:"credential"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.Credential == "" {
		t.Fatal("enrollment returned an empty credential")
	}
	return response.Credential
}

func attestationRequest(deviceID, credential string, publicKey ed25519.PublicKey, privateKey ed25519.PrivateKey, timestamp int64, nonce, transcriptPath string) *http.Request {
	payload := proofPayload(http.MethodPost, transcriptPath, timestamp, nonce)
	signature := ed25519.Sign(privateKey, []byte(payload))
	body, _ := json.Marshal(map[string]any{
		"device_id":        deviceID,
		"relay_credential": credential,
		"public_key":       base64.RawURLEncoding.EncodeToString(publicKey),
		"timestamp":        timestamp,
		"nonce":            nonce,
		"signature":        base64.RawURLEncoding.EncodeToString(signature),
		"transcript_path":  transcriptPath,
	})
	return httptest.NewRequest(http.MethodPost, relay.PathInternalTelemetryAttest, bytes.NewReader(body))
}

func serveAttestation(mux *http.ServeMux, request *http.Request, internalToken string) *httptest.ResponseRecorder {
	request.Header.Set("Authorization", "Bearer "+internalToken)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, request)
	return rec
}

func encodedNonce(value byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, 32))
}

func proofPayload(method, path string, timestamp int64, nonce string) string {
	return method + "\n" + path + "\n" + strconv.FormatInt(timestamp, 10) + "\n" + nonce
}
