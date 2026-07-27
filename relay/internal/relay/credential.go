package relay

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

type credentialClaims struct {
	DeviceID  string `json:"device_id"`
	PublicKey string `json:"public_key"`
	ExpiresAt int64  `json:"expires_at"`
}

func issueCredential(key []byte, deviceID string, publicKey []byte, ttl time.Duration) (string, error) {
	claims, err := json.Marshal(credentialClaims{deviceID, base64.RawURLEncoding.EncodeToString(publicKey), time.Now().Add(ttl).Unix()})
	if err != nil {
		return "", err
	}
	mac := hmac.New(sha256.New, key)
	mac.Write(claims)
	return base64.RawURLEncoding.EncodeToString(claims) + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

func verifyCredential(key []byte, token string) (credentialClaims, []byte, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return credentialClaims{}, nil, errors.New("malformed credential")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return credentialClaims{}, nil, err
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return credentialClaims{}, nil, err
	}
	mac := hmac.New(sha256.New, key)
	mac.Write(payload)
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return credentialClaims{}, nil, errors.New("credential signature is invalid")
	}
	var claims credentialClaims
	if err := json.Unmarshal(payload, &claims); err != nil || claims.DeviceID == "" || time.Now().Unix() >= claims.ExpiresAt {
		return credentialClaims{}, nil, errors.New("credential is invalid or expired")
	}
	publicKey, err := base64.RawURLEncoding.DecodeString(claims.PublicKey)
	if err != nil || len(publicKey) != ed25519.PublicKeySize {
		return credentialClaims{}, nil, errors.New("credential public key is invalid")
	}
	return claims, publicKey, nil
}

func verifyDeviceProof(publicKey []byte, nonce, encodedSignature string) error {
	signature, err := base64.RawURLEncoding.DecodeString(encodedSignature)
	if err != nil || nonce == "" || !ed25519.Verify(ed25519.PublicKey(publicKey), []byte(nonce), signature) {
		return errors.New("device signature is invalid")
	}
	return nil
}
