// Relay 凭据签发、校验和设备证明验证。

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

// credentialClaims 是签名凭据中绑定的设备身份和过期时间。
type credentialClaims struct {
	DeviceID  string `json:"device_id"`
	PublicKey string `json:"public_key"`
	ExpiresAt int64  `json:"expires_at"`
}

// errCredentialExpired 区分“凭据已过期”与其他认证失败，使连接路径能返回
// relayErrorCredentialExpired 而不会把过期与非法凭据混为一谈。
var errCredentialExpired = errors.New("credential is expired")

// issueCredential 为指定设备签发带 HMAC 的短期凭据。
func issueCredential(key []byte, deviceID string, publicKey []byte, ttl time.Duration) (string, error) {
	claims, err := json.Marshal(credentialClaims{
		DeviceID:  deviceID,
		PublicKey: base64.RawURLEncoding.EncodeToString(publicKey),
		ExpiresAt: time.Now().Add(ttl).Unix(),
	})
	if err != nil {
		return "", err
	}
	mac := hmac.New(sha256.New, key)
	mac.Write(claims)
	return base64.RawURLEncoding.EncodeToString(claims) + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

// verifyCredential 校验凭据签名、设备标识、过期时间和公钥材料。
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
	if err := json.Unmarshal(payload, &claims); err != nil || claims.DeviceID == "" {
		return credentialClaims{}, nil, errors.New("credential is invalid")
	}
	if claims.ExpiresAt <= time.Now().Unix() {
		return credentialClaims{}, nil, errCredentialExpired
	}
	publicKey, err := base64.RawURLEncoding.DecodeString(claims.PublicKey)
	if err != nil || len(publicKey) != ed25519.PublicKeySize {
		return credentialClaims{}, nil, errors.New("credential public key is invalid")
	}
	return claims, publicKey, nil
}

// verifyDeviceProof 校验设备对请求 transcript 的 Ed25519 签名。
func verifyDeviceProof(publicKey []byte, payload, encodedSignature string) error {
	signature, err := base64.RawURLEncoding.DecodeString(encodedSignature)
	if err != nil || payload == "" || !ed25519.Verify(ed25519.PublicKey(publicKey), []byte(payload), signature) {
		return errors.New("device signature is invalid")
	}
	return nil
}
