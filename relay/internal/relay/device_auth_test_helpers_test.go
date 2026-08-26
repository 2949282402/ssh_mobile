package relay

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"strconv"
	"testing"
	"time"
)

// Shared test constants across Relay backend tests.
const (
	TestCredentialKeyHex = "01234567890123456789012345678901"
	TestEnrollmentToken  = "test-enrollment-token"
	TestInternalToken    = "0123456789abcdef0123456789abcdef"
)

// newTestKeyPair generates an Ed25519 keypair for tests.
func newTestKeyPair(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

func setSignedDeviceProof(headers http.Header, method, path string, privateKey ed25519.PrivateKey, nonce string, timestamp int64) {
	headers.Set("X-Relay-Timestamp", strconv.FormatInt(timestamp, 10))
	headers.Set("X-Relay-Nonce", nonce)
	headers.Set("X-Relay-Signature", base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, []byte(authenticatedProofPayload(method, path, timestamp, nonce))),
	))
}

func setCurrentSignedDeviceProof(headers http.Header, method, path string, privateKey ed25519.PrivateKey, nonce string) {
	setSignedDeviceProof(headers, method, path, privateKey, nonce, time.Now().Unix())
}
