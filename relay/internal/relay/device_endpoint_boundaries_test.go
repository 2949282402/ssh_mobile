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

func callRefreshBoundary(t *testing.T, server *Server, request any) *httptest.ResponseRecorder {
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
	makeRequest := func(nonce string, timestamp int64, key ed25519.PrivateKey) refreshRequest {
		return refreshRequest{
			DeviceID:  "device-a",
			PublicKey: encodedKey,
			Timestamp: timestamp,
			Nonce:     nonce,
			Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, []byte(refreshProofPayload(timestamp, nonce)))),
		}
	}
	validNonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	validRequest := makeRequest(validNonce, time.Now().Unix(), privateKey)
	if got := callRefreshBoundary(t, server, validRequest).Code; got != http.StatusOK {
		t.Fatalf("valid refresh status = %d, want 200", got)
	}
	if got := callRefreshBoundary(t, server, validRequest).Code; got != http.StatusUnauthorized {
		t.Fatalf("replayed refresh status = %d, want 401", got)
	}

	badKey, badPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	badKeyRequest := makeRequest(base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, 32)), time.Now().Unix(), badPrivate)
	badKeyRequest.PublicKey = base64.RawURLEncoding.EncodeToString(badKey)
	if got := callRefreshBoundary(t, server, badKeyRequest).Code; got != http.StatusUnauthorized {
		t.Fatalf("mismatched key refresh status = %d, want 401", got)
	}
	badSignature := makeRequest(base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{3}, 32)), time.Now().Unix(), privateKey)
	badSignature.Signature = "bad-signature"
	if got := callRefreshBoundary(t, server, badSignature).Code; got != http.StatusUnauthorized {
		t.Fatalf("bad signature refresh status = %d, want 401", got)
	}

	legacyNonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{5}, 32))
	legacyProof := makeRequest(legacyNonce, time.Now().Unix(), privateKey)
	legacyProof.Signature = base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, []byte("POST\n/v1/devices/refresh\n"+legacyNonce)),
	)
	if got := callRefreshBoundary(t, server, legacyProof).Code; got != http.StatusUnauthorized {
		t.Fatalf("legacy refresh transcript status = %d, want 401", got)
	}

	nowSeconds := time.Now().Unix()
	for _, tc := range []struct {
		name      string
		body      any
		code      int
		errorCode relayErrorCode
	}{
		{name: "unknown device", body: refreshRequest{DeviceID: "missing", PublicKey: encodedKey, Timestamp: nowSeconds, Nonce: validNonce}, code: http.StatusNotFound},
		{name: "empty device", body: refreshRequest{PublicKey: encodedKey, Nonce: validNonce}, code: http.StatusBadRequest},
		{name: "bad public key", body: refreshRequest{DeviceID: "device-a", PublicKey: "bad", Nonce: validNonce}, code: http.StatusBadRequest},
		{name: "bad nonce", body: refreshRequest{DeviceID: "device-a", PublicKey: encodedKey, Nonce: "bad"}, code: http.StatusBadRequest},
		{name: "missing timestamp", body: map[string]any{"device_id": "device-a", "public_key": encodedKey, "nonce": base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{6}, 32)), "signature": "unused"}, code: http.StatusBadRequest, errorCode: relayErrorInvalidArgument},
		{name: "zero timestamp", body: makeRequest(base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{11}, 32)), 0, privateKey), code: http.StatusBadRequest, errorCode: relayErrorInvalidArgument},
		{name: "negative timestamp", body: makeRequest(base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{13}, 32)), -1, privateKey), code: http.StatusBadRequest, errorCode: relayErrorInvalidArgument},
		{name: "non-integer timestamp", body: map[string]any{"device_id": "device-a", "public_key": encodedKey, "timestamp": "1700000000", "nonce": base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{12}, 32)), "signature": "unused"}, code: http.StatusBadRequest, errorCode: relayErrorInvalidArgument},
		{name: "stale timestamp", body: makeRequest(base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32)), nowSeconds-600, privateKey), code: http.StatusUnauthorized, errorCode: relayErrorAuthenticationFailed},
		{name: "future timestamp", body: makeRequest(base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{8}, 32)), nowSeconds+600, privateKey), code: http.StatusUnauthorized, errorCode: relayErrorAuthenticationFailed},
	} {
		t.Run(tc.name, func(t *testing.T) {
			response := callRefreshBoundary(t, server, tc.body)
			if response.Code != tc.code {
				t.Fatalf("refresh status = %d, want %d", response.Code, tc.code)
			}
			if tc.errorCode != 0 {
				var body networkErrorResponse
				if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
					t.Fatalf("decode refresh error: %v", err)
				}
				if body.Code != tc.errorCode {
					t.Fatalf("refresh error code = %d, want %d", body.Code, tc.errorCode)
				}
			}
		})
	}

	revokedNonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{4}, 32))
	if recorded, err := server.store.RecordRevocation(context.Background(), "device-a", time.Now().Add(time.Hour)); err != nil || !recorded {
		t.Fatalf("record revocation = %v, err=%v", recorded, err)
	}
	if got := callRefreshBoundary(t, server, makeRequest(revokedNonce, time.Now().Unix(), privateKey)).Code; got != http.StatusUnauthorized {
		t.Fatalf("revoked refresh status = %d, want 401", got)
	}

	malformed := httptest.NewRequest(http.MethodPost, "/v1/devices/refresh", strings.NewReader("{"))
	malformedResponse := httptest.NewRecorder()
	server.refresh(malformedResponse, malformed)
	if malformedResponse.Code != http.StatusBadRequest {
		t.Fatalf("malformed refresh status = %d, want 400", malformedResponse.Code)
	}
}

func TestRefreshReplayRemainsConsumedAfterSameKeyReenrollment(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := newEndpointBoundaryServer(Config{})
	defer server.Close()
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	enrollment := enrollRequest{
		DeviceID:        "device-a",
		PublicKey:       encodedKey,
		EnrollmentToken: "test-enrollment-token",
		ProtocolVersion: 1,
		Platform:        "linux",
	}
	if got := callEnrollBoundary(t, server, enrollment).Code; got != http.StatusOK {
		t.Fatalf("initial enrollment status = %d, want 200", got)
	}
	timestamp := time.Now().Unix()
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{14}, 32))
	request := refreshRequest{
		DeviceID:  "device-a",
		PublicKey: encodedKey,
		Timestamp: timestamp,
		Nonce:     nonce,
		Signature: base64.RawURLEncoding.EncodeToString(
			ed25519.Sign(privateKey, []byte(refreshProofPayload(timestamp, nonce))),
		),
	}
	if got := callRefreshBoundary(t, server, request).Code; got != http.StatusOK {
		t.Fatalf("initial refresh status = %d, want 200", got)
	}
	if got := callEnrollBoundary(t, server, enrollment).Code; got != http.StatusOK {
		t.Fatalf("same-key re-enrollment status = %d, want 200", got)
	}
	if got := callRefreshBoundary(t, server, request).Code; got != http.StatusUnauthorized {
		t.Fatalf("refresh replay after same-key re-enrollment = %d, want 401", got)
	}
}

func TestRelayProofTimestampFreshnessWindowIsInclusive(t *testing.T) {
	now := time.Unix(2_000_000_000, 999_999_999)
	for _, tc := range []struct {
		name      string
		timestamp int64
		fresh     bool
	}{
		{name: "lower boundary", timestamp: now.Unix() - 300, fresh: true},
		{name: "below lower boundary", timestamp: now.Unix() - 301, fresh: false},
		{name: "upper boundary", timestamp: now.Unix() + 300, fresh: true},
		{name: "above upper boundary", timestamp: now.Unix() + 301, fresh: false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := refreshProofTimestampIsFresh(tc.timestamp, now); got != tc.fresh {
				t.Fatalf("freshness = %v, want %v", got, tc.fresh)
			}
		})
	}
}

func TestV2WebSocketProofFreshnessAndTranscriptAreHardCut(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := newEndpointBoundaryServer(Config{})
	defer server.Close()
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	if result := server.replaceEnrollment("device-a", encodedKey, "linux", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("seed enrollment result = %v", result)
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
	now := time.Now().Unix()
	cases := []struct {
		name      string
		path      string
		timestamp int64
		mutate    func(*http.Request, string)
	}{
		{name: "missing timestamp", path: "/v2/control", timestamp: now, mutate: func(request *http.Request, _ string) {
			request.Header.Del("X-Relay-Timestamp")
		}},
		{name: "zero timestamp", path: "/v2/control", timestamp: 0},
		{name: "negative timestamp", path: "/v2/control", timestamp: -1},
		{name: "non integer timestamp", path: "/v2/control", timestamp: now, mutate: func(request *http.Request, _ string) {
			request.Header.Set("X-Relay-Timestamp", "not-an-integer")
		}},
		{name: "non canonical timestamp", path: "/v2/control", timestamp: now, mutate: func(request *http.Request, _ string) {
			request.Header.Set("X-Relay-Timestamp", "0"+request.Header.Get("X-Relay-Timestamp"))
		}},
		{name: "stale timestamp", path: "/v2/control", timestamp: now - 600},
		{name: "future timestamp", path: "/v2/control", timestamp: now + 600},
		{name: "retired transcript", path: "/v2/control", timestamp: now, mutate: func(request *http.Request, nonce string) {
			request.Header.Set("X-Relay-Signature", base64.RawURLEncoding.EncodeToString(
				ed25519.Sign(privateKey, []byte(http.MethodGet+"\n"+request.URL.Path+"\n"+nonce)),
			))
		}},
		{name: "trailing newline transcript", path: "/v2/control", timestamp: now, mutate: func(request *http.Request, nonce string) {
			payload := authenticatedProofPayload(http.MethodGet, request.URL.Path, now, nonce) + "\n"
			request.Header.Set("X-Relay-Signature", base64.RawURLEncoding.EncodeToString(
				ed25519.Sign(privateKey, []byte(payload)),
			))
		}},
		{name: "relay data missing timestamp", path: "/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d", timestamp: now, mutate: func(request *http.Request, _ string) {
			request.Header.Del("X-Relay-Timestamp")
		}},
	}
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	for index, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{byte(index + 32)}, 32))
			request := httptest.NewRequest(http.MethodGet, tc.path, nil)
			request.Header.Set("Authorization", "Bearer "+credential)
			setSignedDeviceProof(request.Header, http.MethodGet, tc.path, privateKey, nonce, tc.timestamp)
			if tc.mutate != nil {
				tc.mutate(request, nonce)
			}
			response := httptest.NewRecorder()
			mux.ServeHTTP(response, request)
			if response.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401", response.Code)
			}
			var body networkErrorResponse
			if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if body.Code != relayErrorAuthenticationFailed {
				t.Fatalf("code = %d, want %d", body.Code, relayErrorAuthenticationFailed)
			}
		})
	}
}

func TestRefreshFailsClosedWhenNonceCacheUnavailable(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := newEndpointBoundaryServer(Config{})
	defer server.Close()
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	if result := server.replaceEnrollment("device-a", encodedKey, "linux", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("seed enrollment result = %v", result)
	}
	server.cache = failingNonceCache{Cache: server.cache}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32))
	timestamp := time.Now().Unix()
	request := refreshRequest{
		DeviceID:  "device-a",
		PublicKey: encodedKey,
		Timestamp: timestamp,
		Nonce:     nonce,
		Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, []byte(refreshProofPayload(timestamp, nonce)))),
	}
	response := callRefreshBoundary(t, server, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("nonce cache outage status = %d, want 503", response.Code)
	}
	if response.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("nonce cache outage content type = %q", response.Header().Get("Content-Type"))
	}
	var body map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode nonce cache outage response: %v", err)
	}
	if _, issued := body["credential"]; issued {
		t.Fatalf("nonce cache outage issued a credential: %s", response.Body.String())
	}
	if body["code"] != float64(relayErrorRelayError) {
		t.Fatalf("nonce cache outage code = %v, want %d", body["code"], relayErrorRelayError)
	}
	if body["retry_disposition"] != float64(retryWithBackoff) {
		t.Fatalf("nonce cache outage retry disposition = %v, want %d", body["retry_disposition"], retryWithBackoff)
	}
}

type recordingNonceCache struct {
	Cache
	expiresAt time.Time
}

func (cache *recordingNonceCache) ConsumeNonce(
	ctx context.Context,
	deviceID string,
	nonce string,
	expiresAt time.Time,
) (bool, error) {
	cache.expiresAt = expiresAt
	return cache.Cache.ConsumeNonce(ctx, deviceID, nonce, expiresAt)
}

func TestRefreshNonceExpiryIsBoundToSignedTimestamp(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := newEndpointBoundaryServer(Config{})
	defer server.Close()
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	if result := server.replaceEnrollment("device-a", encodedKey, "linux", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("seed enrollment result = %v", result)
	}
	recorder := &recordingNonceCache{Cache: server.cache}
	server.cache = recorder
	timestamp := time.Now().Unix()
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{10}, 32))
	request := refreshRequest{
		DeviceID:  "device-a",
		PublicKey: encodedKey,
		Timestamp: timestamp,
		Nonce:     nonce,
		Signature: base64.RawURLEncoding.EncodeToString(
			ed25519.Sign(privateKey, []byte(refreshProofPayload(timestamp, nonce))),
		),
	}
	if got := callRefreshBoundary(t, server, request).Code; got != http.StatusOK {
		t.Fatalf("refresh status = %d, want 200", got)
	}
	want := time.Unix(timestamp, 0).Add(300 * time.Second).Add(time.Second)
	if !recorder.expiresAt.Equal(want) {
		t.Fatalf("nonce expiry = %s, want %s", recorder.expiresAt, want)
	}
}

func TestV2WebSocketNonceExpiryIsBoundToSignedTimestamp(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := newEndpointBoundaryServer(Config{})
	defer server.Close()
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	if result := server.replaceEnrollment("device-a", encodedKey, "linux", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("seed enrollment result = %v", result)
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
	recorder := &recordingNonceCache{Cache: server.cache}
	server.cache = recorder
	timestamp := time.Now().Unix() - 100
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{75}, 32))
	request := httptest.NewRequest(http.MethodGet, "/v2/control", nil)
	request.Header.Set("Authorization", "Bearer "+credential)
	setSignedDeviceProof(request.Header, http.MethodGet, request.URL.Path, privateKey, nonce, timestamp)
	if _, _, code, ok := server.authenticatedRequest(request); !ok || code != relayErrorUnspecified {
		t.Fatalf("fresh v2 proof rejected: ok=%v code=%d", ok, code)
	}
	want := time.Unix(timestamp, 0).Add(300 * time.Second).Add(time.Second)
	if !recorder.expiresAt.Equal(want) {
		t.Fatalf("nonce expiry = %s, want %s", recorder.expiresAt, want)
	}
}

func TestV2WebSocketReplayRemainsConsumedAfterSameKeyReenrollment(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := newEndpointBoundaryServer(Config{})
	defer server.Close()
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	firstEnrollment := time.Now()
	if result := server.replaceEnrollment("device-a", encodedKey, "linux", 1, firstEnrollment); result != enrollmentOK {
		t.Fatalf("seed enrollment result = %v", result)
	}
	firstCredential, err := issueCredential(
		server.config.CredentialKey,
		"device-a",
		publicKey,
		mustEnrollmentGeneration(t, server, "device-a"),
		time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}
	timestamp := time.Now().Unix()
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{76}, 32))
	request := httptest.NewRequest(http.MethodGet, "/v2/control", nil)
	request.Header.Set("Authorization", "Bearer "+firstCredential)
	setSignedDeviceProof(request.Header, http.MethodGet, request.URL.Path, privateKey, nonce, timestamp)
	if _, _, code, ok := server.authenticatedRequest(request); !ok || code != relayErrorUnspecified {
		t.Fatalf("initial v2 proof rejected: ok=%v code=%d", ok, code)
	}

	if result := server.replaceEnrollment("device-a", encodedKey, "linux", 1, firstEnrollment.Add(time.Second)); result != enrollmentOK {
		t.Fatalf("same-key re-enrollment result = %v", result)
	}
	secondCredential, err := issueCredential(
		server.config.CredentialKey,
		"device-a",
		publicKey,
		mustEnrollmentGeneration(t, server, "device-a"),
		time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+secondCredential)
	if _, _, code, ok := server.authenticatedRequest(request); ok || code != relayErrorAuthenticationFailed {
		t.Fatalf("replay reopened after same-key re-enrollment: ok=%v code=%d", ok, code)
	}
}
