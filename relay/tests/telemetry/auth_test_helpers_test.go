package telemetry_test

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

// testAuthSecret is a valid (>=16 char) token signing secret for tests.
const testAuthSecret = "test-telemetry-auth-secret-0123456789"

// newTestService creates a Service wired to an in-memory store and the given
// token signing secret. An empty secret yields a fail-closed service.
func newTestService(secret string) (*Service, *MemoryStore) {
	catalog := DefaultCatalog()
	store := NewMemoryStore(catalog)
	if secret == "" {
		return NewService(store, catalog, &NoopRedisCache{}), store
	}
	return NewServiceWithSecret(store, catalog, &NoopRedisCache{}, secret), store
}

// registerDevice enrolls deviceID with a generated random secret and returns the
// plaintext secret and its stored hash.
func registerDevice(t *testing.T, store *MemoryStore, deviceID string) (string, string) {
	t.Helper()
	secret := "device-secret-" + deviceID + "-0123456789"
	hash := hashSecret(secret)
	if err := store.RegisterDeviceCredential(context.Background(), deviceID, hash); err != nil {
		t.Fatalf("register device credential: %v", err)
	}
	return secret, hash
}

func hashSecret(secret string) string {
	digest := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(digest[:])
}

// deviceProof computes hex(HMAC-SHA256(key=storedHash, data="telemetry:auth:"+deviceID+":"+expEpoch)).
func deviceProof(deviceID, storedHash string, expEpoch int64) string {
	mac := hmac.New(sha256.New, []byte(storedHash))
	mac.Write([]byte("telemetry:auth:" + deviceID + ":" + strconv.FormatInt(expEpoch, 10)))
	return hex.EncodeToString(mac.Sum(nil))
}

// futureEpoch returns a unix epoch shortly in the future, safely inside the
// server's accepted 120s skew window.
func futureEpoch() int64 {
	return time.Now().UTC().Add(60 * time.Second).Unix()
}
