package relay_test

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

	"github.com/ssh-mobile/relay/internal/relay"
)

func TestRelayRefreshRejectsMalformedAndStaleProofs(t *testing.T) {
	_, mux := newRelayTestServer(t)
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().Unix()
	validNonce := encodedNonce(0x61)
	cases := []struct {
		name string
		body string
		want int
	}{
		{"malformed JSON", "{", http.StatusBadRequest},
		{"missing device", `{"public_key":"x"}`, http.StatusBadRequest},
		{"invalid public key", string(refreshRequestBody([]byte("bad"), privateKey, "refresh-device", now, validNonce, "")), http.StatusBadRequest},
		{"invalid nonce", string(refreshRequestBody(publicKey, privateKey, "refresh-device", now, "bad", "")), http.StatusBadRequest},
		{"zero timestamp", string(refreshRequestBody(publicKey, privateKey, "refresh-device", 0, validNonce, "")), http.StatusBadRequest},
		{"stale timestamp", string(refreshRequestBody(publicKey, privateKey, "refresh-device", now-601, validNonce, "")), http.StatusUnauthorized},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := serveRefresh(mux, []byte(tc.body))
			if rec.Code != tc.want {
				t.Fatalf("refresh status = %d, want %d: %s", rec.Code, tc.want, rec.Body.String())
			}
		})
	}
}

func TestRelayRefreshBindsEnrollmentIdentityAndConsumesNonce(t *testing.T) {
	_, mux := newRelayTestServer(t)
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	otherPublicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	enrollRelayDevice(t, mux, "refresh-device", publicKey)
	now := time.Now().Unix()

	mismatchedIdentity := refreshRequestBody(otherPublicKey, privateKey, "refresh-device", now, encodedNonce(0x62), "")
	if rec := serveRefresh(mux, mismatchedIdentity); rec.Code != http.StatusUnauthorized {
		t.Fatalf("mismatched public key status = %d, want 401", rec.Code)
	}

	badSignature := refreshRequestBody(publicKey, privateKey, "refresh-device", now, encodedNonce(0x63), "invalid")
	if rec := serveRefresh(mux, badSignature); rec.Code != http.StatusUnauthorized {
		t.Fatalf("invalid signature status = %d, want 401", rec.Code)
	}

	nonce := encodedNonce(0x64)
	valid := refreshRequestBody(publicKey, privateKey, "refresh-device", now, nonce, "")
	rec := serveRefresh(mux, valid)
	if rec.Code != http.StatusOK {
		t.Fatalf("valid refresh status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	var response struct {
		Credential string `json:"credential"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil || response.Credential == "" {
		t.Fatalf("refresh response credential = %q, err=%v", response.Credential, err)
	}
	if rec := serveRefresh(mux, valid); rec.Code != http.StatusUnauthorized {
		t.Fatalf("replayed refresh status = %d, want 401", rec.Code)
	}

	unknown := refreshRequestBody(publicKey, privateKey, "unknown-refresh-device", now, encodedNonce(0x65), "")
	if rec := serveRefresh(mux, unknown); rec.Code != http.StatusNotFound {
		t.Fatalf("unknown device status = %d, want 404", rec.Code)
	}
}

func TestRelayRefreshRejectsCorruptStoredIdentity(t *testing.T) {
	server, mux := newRelayTestServer(t)
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := server.SeedEnrollments(context.Background(), []relay.EnrolledDevice{{
		DeviceID:        "corrupt-refresh-device",
		PublicKey:       "!",
		Platform:        "test",
		ProtocolVersion: relay.RelayBootstrapProtocolVersion,
		EnrolledAt:      time.Now(),
	}}); err != nil {
		t.Fatalf("seed corrupt identity: %v", err)
	}
	request := refreshRequestBody(publicKey, privateKey, "corrupt-refresh-device", time.Now().Unix(), encodedNonce(0x66), "")
	if rec := serveRefresh(mux, request); rec.Code != http.StatusInternalServerError {
		t.Fatalf("corrupt stored identity status = %d, want 500: %s", rec.Code, rec.Body.String())
	}
}

func refreshRequestBody(publicKey ed25519.PublicKey, privateKey ed25519.PrivateKey, deviceID string, timestamp int64, nonce, signatureOverride string) []byte {
	signature := signatureOverride
	if signature == "" {
		payload := proofPayload(http.MethodPost, relay.PathRefreshV2, timestamp, nonce)
		signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, []byte(payload)))
	}
	body, _ := json.Marshal(map[string]any{
		"device_id":  deviceID,
		"public_key": base64.RawURLEncoding.EncodeToString(publicKey),
		"timestamp":  timestamp,
		"nonce":      nonce,
		"signature":  signature,
	})
	return body
}

func serveRefresh(mux *http.ServeMux, body []byte) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, relay.PathRefreshV2, bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}
