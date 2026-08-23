package relay

import (
	"crypto/ed25519"
	"encoding/base64"
	"net/http"
	"strconv"
	"time"
)

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
