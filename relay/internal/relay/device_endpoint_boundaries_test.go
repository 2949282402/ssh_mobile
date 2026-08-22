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
	"strings"
	"testing"
	"time"
)

const endpointBoundaryCredentialKey = "01234567890123456789012345678901"

func newEndpointBoundaryServer(config Config) *Server {
	if len(config.CredentialKey) == 0 {
		config.CredentialKey = []byte(endpointBoundaryCredentialKey)
	}
	if config.EnrollmentToken == "" {
		config.EnrollmentToken = "test-enrollment-token"
	}
	if config.CredentialTTL == 0 {
		config.CredentialTTL = time.Hour
	}
	return NewServer(config)
}

func callEnrollBoundary(t *testing.T, server *Server, body any) *httptest.ResponseRecorder {
	t.Helper()
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/v1/devices/enroll", bytes.NewReader(data))
	response := httptest.NewRecorder()
	server.enroll(response, request)
	return response
}

func TestEnrollEndpointValidationBoundaries(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	valid := enrollRequest{
		DeviceID:        "device-a",
		PublicKey:       encodedKey,
		EnrollmentToken: "test-enrollment-token",
		ProtocolVersion: 1,
		Platform:        "linux",
	}
	cases := []struct {
		name   string
		body   any
		status int
	}{
		{name: "invalid token", body: func() enrollRequest { value := valid; value.EnrollmentToken = "wrong"; return value }(), status: http.StatusUnauthorized},
		{name: "empty device id", body: func() enrollRequest { value := valid; value.DeviceID = ""; return value }(), status: http.StatusBadRequest},
		{name: "oversized device id", body: func() enrollRequest { value := valid; value.DeviceID = strings.Repeat("d", 129); return value }(), status: http.StatusBadRequest},
		{name: "unsupported protocol", body: func() enrollRequest { value := valid; value.ProtocolVersion = 2; return value }(), status: http.StatusBadRequest},
		{name: "oversized platform", body: func() enrollRequest { value := valid; value.Platform = strings.Repeat("p", 65); return value }(), status: http.StatusBadRequest},
		{name: "invalid public key", body: func() enrollRequest { value := valid; value.PublicKey = "not-base64"; return value }(), status: http.StatusBadRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			server := newEndpointBoundaryServer(Config{})
			defer server.Close()
			if got := callEnrollBoundary(t, server, tc.body).Code; got != tc.status {
				t.Fatalf("enroll status = %d, want %d", got, tc.status)
			}
		})
	}

	server := newEndpointBoundaryServer(Config{})
	defer server.Close()
	if got := callEnrollBoundary(t, server, valid).Code; got != http.StatusOK {
		t.Fatalf("valid enrollment status = %d, want 200", got)
	}
	if got := callEnrollBoundary(t, server, valid).Code; got != http.StatusOK {
		t.Fatalf("same-key enrollment refresh status = %d, want 200", got)
	}
	conflict := valid
	otherPublic, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	conflict.PublicKey = base64.RawURLEncoding.EncodeToString(otherPublic)
	if got := callEnrollBoundary(t, server, conflict).Code; got != http.StatusConflict {
		t.Fatalf("identity conflict status = %d, want 409", got)
	}

	limited := newEndpointBoundaryServer(Config{MaxEnrolledDevices: 1})
	defer limited.Close()
	if got := callEnrollBoundary(t, limited, valid).Code; got != http.StatusOK {
		t.Fatalf("capacity seed enrollment status = %d, want 200", got)
	}
	second := valid
	second.DeviceID = "device-b"
	if got := callEnrollBoundary(t, limited, second).Code; got != http.StatusTooManyRequests {
		t.Fatalf("capacity enrollment status = %d, want 429", got)
	}

	malformed := httptest.NewRequest(http.MethodPost, "/v1/devices/enroll", strings.NewReader("{"))
	malformedResponse := httptest.NewRecorder()
	server.enroll(malformedResponse, malformed)
	if malformedResponse.Code != http.StatusBadRequest {
		t.Fatalf("malformed enrollment status = %d, want 400", malformedResponse.Code)
	}
}

func callRefreshBoundary(t *testing.T, server *Server, request refreshRequest) *httptest.ResponseRecorder {
	t.Helper()
	data, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	httpRequest := httptest.NewRequest(http.MethodPost, "/v1/devices/refresh", bytes.NewReader(data))
	response := httptest.NewRecorder()
	server.refresh(response, httpRequest)
	return response
}

func TestRefreshEndpointValidationBoundaries(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	server := newEndpointBoundaryServer(Config{})
	defer server.Close()
	if result := server.replaceEnrollment("device-a", encodedKey, "linux", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("seed enrollment result = %v", result)
	}
	makeRequest := func(nonce string, key ed25519.PrivateKey) refreshRequest {
		return refreshRequest{
			DeviceID:  "device-a",
			PublicKey: encodedKey,
			Nonce:     nonce,
			Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, []byte("POST\n/v1/devices/refresh\n"+nonce))),
		}
	}
	validNonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	if got := callRefreshBoundary(t, server, makeRequest(validNonce, privateKey)).Code; got != http.StatusOK {
		t.Fatalf("valid refresh status = %d, want 200", got)
	}
	if got := callRefreshBoundary(t, server, makeRequest(validNonce, privateKey)).Code; got != http.StatusUnauthorized {
		t.Fatalf("replayed refresh status = %d, want 401", got)
	}

	badKey, badPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	badKeyRequest := makeRequest(base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, 32)), badPrivate)
	badKeyRequest.PublicKey = base64.RawURLEncoding.EncodeToString(badKey)
	if got := callRefreshBoundary(t, server, badKeyRequest).Code; got != http.StatusUnauthorized {
		t.Fatalf("mismatched key refresh status = %d, want 401", got)
	}
	badSignature := makeRequest(base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{3}, 32)), privateKey)
	badSignature.Signature = "bad-signature"
	if got := callRefreshBoundary(t, server, badSignature).Code; got != http.StatusUnauthorized {
		t.Fatalf("bad signature refresh status = %d, want 401", got)
	}

	for _, tc := range []struct {
		name string
		body refreshRequest
		code int
	}{
		{name: "unknown device", body: refreshRequest{DeviceID: "missing", PublicKey: encodedKey, Nonce: validNonce}, code: http.StatusNotFound},
		{name: "empty device", body: refreshRequest{PublicKey: encodedKey, Nonce: validNonce}, code: http.StatusBadRequest},
		{name: "bad public key", body: refreshRequest{DeviceID: "device-a", PublicKey: "bad", Nonce: validNonce}, code: http.StatusBadRequest},
		{name: "bad nonce", body: refreshRequest{DeviceID: "device-a", PublicKey: encodedKey, Nonce: "bad"}, code: http.StatusBadRequest},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := callRefreshBoundary(t, server, tc.body).Code; got != tc.code {
				t.Fatalf("refresh status = %d, want %d", got, tc.code)
			}
		})
	}

	revokedNonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{4}, 32))
	if recorded, err := server.store.RecordRevocation(context.Background(), "device-a", time.Now().Add(time.Hour)); err != nil || !recorded {
		t.Fatalf("record revocation = %v, err=%v", recorded, err)
	}
	if got := callRefreshBoundary(t, server, makeRequest(revokedNonce, privateKey)).Code; got != http.StatusUnauthorized {
		t.Fatalf("revoked refresh status = %d, want 401", got)
	}

	malformed := httptest.NewRequest(http.MethodPost, "/v1/devices/refresh", strings.NewReader("{"))
	malformedResponse := httptest.NewRecorder()
	server.refresh(malformedResponse, malformed)
	if malformedResponse.Code != http.StatusBadRequest {
		t.Fatalf("malformed refresh status = %d, want 400", malformedResponse.Code)
	}
}
