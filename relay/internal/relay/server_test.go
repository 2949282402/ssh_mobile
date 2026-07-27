package relay

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"testing"
	"time"
)

func TestCredentialBindsDeviceAndKey(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	credential, err := issueCredential([]byte("01234567890123456789012345678901"), "device-a", publicKey, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	claims, restored, err := verifyCredential([]byte("01234567890123456789012345678901"), credential)
	if err != nil {
		t.Fatal(err)
	}
	if claims.DeviceID != "device-a" || base64.RawURLEncoding.EncodeToString(restored) != base64.RawURLEncoding.EncodeToString(publicKey) {
		t.Fatal("credential lost identity binding")
	}
}

func TestHubDoesNotPersistExpiredSession(t *testing.T) {
	hub := newHub(Config{SessionTTL: time.Nanosecond})
	defer hub.close()
	hub.sessions["0123456789abcdef0123456789abcdef"] = session{sender: "a", receiver: "b", expiresAt: time.Now().Add(-time.Second)}
	hub.mutex.Lock()
	for id, value := range hub.sessions {
		if time.Now().After(value.expiresAt) {
			delete(hub.sessions, id)
		}
	}
	_, found := hub.sessions["0123456789abcdef0123456789abcdef"]
	hub.mutex.Unlock()
	if found {
		t.Fatal("expired session was retained")
	}
}
