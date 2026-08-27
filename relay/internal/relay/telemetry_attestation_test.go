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
)

func TestInternalTelemetryAttestationValidatesCurrentRelayEnrollment(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey:   []byte(TestCredentialKeyHex),
		EnrollmentToken: TestEnrollmentToken,
		InternalToken:   TestInternalToken,
		CredentialTTL:   time.Hour,
	})
	defer server.Close()
	if result := server.replaceEnrollment(
		"device-a",
		base64.RawURLEncoding.EncodeToString(publicKey),
		"test",
		RelayBootstrapProtocolVersion,
		time.Now(),
	); result != enrollmentOK {
		t.Fatalf("replaceEnrollment=%v", result)
	}
	generation := mustEnrollmentGeneration(t, server, "device-a")
	credential, err := issueCredential(
		server.config.CredentialKey,
		"device-a",
		publicKey,
		generation,
		time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x31}, 32))
	timestamp := time.Now().Unix()
	signature := ed25519.Sign(
		privateKey,
		[]byte(authenticatedProofPayload("POST", PathPublicTelemetryEnroll, timestamp, nonce)),
	)
	body, err := json.Marshal(internalTelemetryAttestationRequest{
		DeviceID:        "device-a",
		RelayCredential: credential,
		PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
		Timestamp:       timestamp,
		Nonce:           nonce,
		Signature:       base64.RawURLEncoding.EncodeToString(signature),
	})
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	req := httptest.NewRequest(http.MethodPost, PathInternalTelemetryAttest, bytes.NewReader(body))
	req.SetPathValue("deviceId", "device-a")
	req.Header.Set("Authorization", "Bearer "+TestInternalToken)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var response internalTelemetryAttestationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.DeviceID != "device-a" || response.ProtocolVersion != RelayBootstrapProtocolVersion {
		t.Fatalf("unexpected attestation response: %+v", response)
	}

	// Explicit rotation uses a distinct transcript target, so an enrollment
	// proof cannot be repurposed for rotation and vice versa.
	rotateNonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x34}, 32))
	rotateTimestamp := time.Now().Unix()
	rotateSignature := ed25519.Sign(
		privateKey,
		[]byte(authenticatedProofPayload("POST", PathPublicTelemetryRotate, rotateTimestamp, rotateNonce)),
	)
	rotateBody, err := json.Marshal(internalTelemetryAttestationRequest{
		DeviceID:        "device-a",
		RelayCredential: credential,
		PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
		Timestamp:       rotateTimestamp,
		Nonce:           rotateNonce,
		Signature:       base64.RawURLEncoding.EncodeToString(rotateSignature),
		TranscriptPath:  PathPublicTelemetryRotate,
	})
	if err != nil {
		t.Fatal(err)
	}
	rotateReq := httptest.NewRequest(http.MethodPost, PathInternalTelemetryAttest, bytes.NewReader(rotateBody))
	rotateReq.Header.Set("Authorization", "Bearer "+TestInternalToken)
	rotateRec := httptest.NewRecorder()
	mux.ServeHTTP(rotateRec, rotateReq)
	if rotateRec.Code != http.StatusOK {
		t.Fatalf("explicit rotation attestation status=%d: %s", rotateRec.Code, rotateRec.Body.String())
	}
}

func TestInternalTelemetryAttestationRejectsWrongDeviceAndReplay(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey:   []byte(TestCredentialKeyHex),
		EnrollmentToken: TestEnrollmentToken,
		InternalToken:   TestInternalToken,
		CredentialTTL:   time.Hour,
	})
	defer server.Close()
	if result := server.replaceEnrollment(
		"device-a",
		base64.RawURLEncoding.EncodeToString(publicKey),
		"test",
		RelayBootstrapProtocolVersion,
		time.Now(),
	); result != enrollmentOK {
		t.Fatalf("replaceEnrollment=%v", result)
	}
	generation := mustEnrollmentGeneration(t, server, "device-a")
	credential, err := issueCredential(server.config.CredentialKey, "device-a", publicKey, generation, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x32}, 32))
	timestamp := time.Now().Unix()
	body := func(deviceID string) []byte {
		signature := ed25519.Sign(
			privateKey,
			[]byte(authenticatedProofPayload("POST", PathPublicTelemetryEnroll, timestamp, nonce)),
		)
		encoded, _ := json.Marshal(internalTelemetryAttestationRequest{
			DeviceID:        deviceID,
			RelayCredential: credential,
			PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
			Timestamp:       timestamp,
			Nonce:           nonce,
			Signature:       base64.RawURLEncoding.EncodeToString(signature),
		})
		return encoded
	}
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	wrongDevice := httptest.NewRequest(http.MethodPost, PathInternalTelemetryAttest, bytes.NewReader(body("device-b")))
	wrongDevice.SetPathValue("deviceId", "device-b")
	wrongDevice.Header.Set("Authorization", "Bearer "+TestInternalToken)
	wrongRec := httptest.NewRecorder()
	mux.ServeHTTP(wrongRec, wrongDevice)
	if wrongRec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for wrong device, got %d", wrongRec.Code)
	}

	valid := httptest.NewRequest(http.MethodPost, PathInternalTelemetryAttest, bytes.NewReader(body("device-a")))
	valid.SetPathValue("deviceId", "device-a")
	valid.Header.Set("Authorization", "Bearer "+TestInternalToken)
	validRec := httptest.NewRecorder()
	mux.ServeHTTP(validRec, valid)
	if validRec.Code != http.StatusOK {
		t.Fatalf("expected valid attestation, got %d: %s", validRec.Code, validRec.Body.String())
	}

	replay := httptest.NewRequest(http.MethodPost, PathInternalTelemetryAttest, bytes.NewReader(body("device-a")))
	replay.SetPathValue("deviceId", "device-a")
	replay.Header.Set("Authorization", "Bearer "+TestInternalToken)
	replayRec := httptest.NewRecorder()
	mux.ServeHTTP(replayRec, replay)
	if replayRec.Code != http.StatusUnauthorized {
		t.Fatalf("expected replayed attestation to fail closed, got %d", replayRec.Code)
	}
}

func TestInternalTelemetryAttestationRejectsUnregisteredWrongCredentialAndMissingProof(t *testing.T) {
	publicKeyA, privateKeyA, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	publicKeyB, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey:   []byte(TestCredentialKeyHex),
		EnrollmentToken: TestEnrollmentToken,
		InternalToken:   TestInternalToken,
		CredentialTTL:   time.Hour,
	})
	defer server.Close()
	encodedA := base64.RawURLEncoding.EncodeToString(publicKeyA)
	encodedB := base64.RawURLEncoding.EncodeToString(publicKeyB)
	if result := server.replaceEnrollment("device-a", encodedA, "test", RelayBootstrapProtocolVersion, time.Now()); result != enrollmentOK {
		t.Fatalf("replaceEnrollment device-a=%v", result)
	}
	if result := server.replaceEnrollment("device-b", encodedB, "test", RelayBootstrapProtocolVersion, time.Now()); result != enrollmentOK {
		t.Fatalf("replaceEnrollment device-b=%v", result)
	}
	credentialB, err := issueCredential(server.config.CredentialKey, "device-b", publicKeyB, mustEnrollmentGeneration(t, server, "device-b"), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	credentialUnregistered, err := issueCredential(server.config.CredentialKey, "device-unregistered", publicKeyA, 1, time.Hour)
	if err != nil {
		t.Fatal(err)
	}

	request := func(deviceID, credential, publicKey, nonce string, privateKey ed25519.PrivateKey) *http.Request {
		timestamp := time.Now().Unix()
		signature := ed25519.Sign(privateKey, []byte(authenticatedProofPayload("POST", PathPublicTelemetryEnroll, timestamp, nonce)))
		body, err := json.Marshal(internalTelemetryAttestationRequest{
			DeviceID:        deviceID,
			RelayCredential: credential,
			PublicKey:       publicKey,
			Timestamp:       timestamp,
			Nonce:           nonce,
			Signature:       base64.RawURLEncoding.EncodeToString(signature),
		})
		if err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest(http.MethodPost, PathInternalTelemetryAttest, bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+TestInternalToken)
		return req
	}

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	cases := []struct {
		name string
		req  *http.Request
	}{
		{
			name: "unregistered device",
			// This credential is cryptographically valid but has no durable enrollment.
			req: request("device-unregistered", credentialUnregistered, encodedA, base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x41}, 32)), privateKeyA),
		},
		{
			name: "credential bound to another device",
			req:  request("device-a", credentialB, encodedB, base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x42}, 32)), privateKeyA),
		},
		{
			name: "missing proof",
			req: httptest.NewRequest(http.MethodPost, PathInternalTelemetryAttest,
				bytes.NewBufferString(`{"device_id":"device-a"}`)),
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if tc.name == "missing proof" {
				tc.req.Header.Set("Authorization", "Bearer "+TestInternalToken)
			}
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, tc.req)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status=%d body=%s, want 401", rec.Code, rec.Body.String())
			}
		})
	}
}

var _ = context.Background
