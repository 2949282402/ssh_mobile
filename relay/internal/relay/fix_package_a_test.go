// Regression tests for code-review package A fixes: revocation integrity,
// glob-injection-safe nonce clearing, and presence lifecycle.

package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// TestRefreshRejectsRevokedButStillEnrolledDevice verifies a device whose
// enrollment survived a revocation (e.g. the DELETE failed) cannot refresh a
// fresh credential: the tombstone alone must block it.
func TestRefreshRejectsRevokedButStillEnrolledDevice(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
		CredentialTTL:   time.Hour,
	})
	defer server.Close()

	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	if result := server.replaceEnrollment("device-a", encodedKey, "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	server.devicesMutex.Lock()
	recorded, err := server.store.RecordRevocation(context.Background(), "device-a", time.Now().Add(time.Hour))
	server.devicesMutex.Unlock()
	if err != nil || !recorded {
		t.Fatalf("revoke failed: recorded=%v err=%v", recorded, err)
	}
	server.devicesMutex.Lock()
	device, _ := server.store.GetEnrollment(context.Background(), "device-a")
	server.devicesMutex.Unlock()
	if device == nil {
		t.Fatal("enrollment unexpectedly missing")
	}

	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{8}, 32))
	body, _ := json.Marshal(refreshRequest{
		DeviceID:  "device-a",
		PublicKey: encodedKey,
		Nonce:     nonce,
		Signature: base64.RawURLEncoding.EncodeToString(
			ed25519.Sign(privateKey, []byte("POST\n/v1/devices/refresh\n"+nonce)),
		),
	})
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	request := httptest.NewRequest(http.MethodPost, "/v1/devices/refresh", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, request)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("revoked-but-enrolled device refresh: expected 401, got %d", rec.Code)
	}
}

// failingRemoveStore wraps a working store whose enrollment deletion fails,
// modeling a transient MySQL DELETE failure during revocation.
type failingRemoveStore struct {
	Storage
}

func (failingRemoveStore) RemoveEnrollment(context.Context, string) error {
	return errors.New("injected delete failure")
}

// TestAdminRevokeReturnsErrorWhenEnrollmentDeleteFails verifies the revoke
// handler reports 500 instead of a false 204 when the enrollment row cannot be
// removed, so the operator knows the revocation did not fully land.
func TestAdminRevokeReturnsErrorWhenEnrollmentDeleteFails(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
		CredentialTTL:   time.Hour,
	})
	defer server.Close()
	if result := server.replaceEnrollment("device-a", "key-a", "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	server.store = failingRemoveStore{Storage: server.store}

	request := httptest.NewRequest(http.MethodPost, "/api/admin/v1/devices/device-a/revoke", nil)
	request.SetPathValue("deviceId", "device-a")
	rec := httptest.NewRecorder()
	server.adminRevokeDevice(rec, request)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500 when enrollment delete fails, got %d", rec.Code)
	}
}

// TestDisconnectDeviceClearsPresence verifies the revoke/kick disconnect path
// removes the device's presence instead of leaving a stale online entry.
func TestDisconnectDeviceClearsPresence(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()

	ctx := context.Background()
	if err := server.cache.SetPresence(ctx, "device-a", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	injectPeer(server.hub, "device-a")
	server.hub.disconnectDevice("device-a")

	if _, present, _ := server.cache.GetPresence(ctx, "device-a"); present {
		t.Fatal("presence retained after disconnectDevice")
	}
}

// TestRedisStoreClearNoncesIgnoresGlobDeviceID verifies a device ID containing
// Redis glob metacharacters cannot wipe another device's nonce keys.
func TestRedisStoreClearNoncesIgnoresGlobDeviceID(t *testing.T) {
	ctx := context.Background()
	store, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_ = store.ClearDeviceNonces(ctx, "device-a")
	_ = store.ClearDeviceNonces(ctx, "x*y")

	expiry := time.Now().Add(time.Hour)
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "nonce-a1", expiry); replayed {
		t.Fatal("fresh nonce reported replay")
	}
	// A glob-bearing device ID clearing its own keys must not touch device-a.
	if err := store.ClearDeviceNonces(ctx, "x*y"); err != nil {
		t.Fatal(err)
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "nonce-a1", expiry); !replayed {
		t.Fatal("glob device ID cleared another device's nonce")
	}
	_ = store.ClearDeviceNonces(ctx, "device-a")
}

// TestRedisStoreNonceCap verifies the per-device active-nonce cap is enforced
// in Redis, matching the in-memory 128-entry bound.
func TestRedisStoreNonceCap(t *testing.T) {
	ctx := context.Background()
	store, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_ = store.ClearDeviceNonces(ctx, "cap-device")

	expiry := time.Now().Add(time.Hour)
	for i := 0; i < maxProofNoncesPerDevice; i++ {
		if replayed, _ := store.ConsumeNonce(ctx, "cap-device", fmt.Sprintf("n-%d", i), expiry); replayed {
			t.Fatalf("nonce %d unexpectedly rejected before the cap", i)
		}
	}
	if replayed, _ := store.ConsumeNonce(ctx, "cap-device", "n-over", expiry); !replayed {
		t.Fatal("nonce beyond the cap was accepted")
	}
	_ = store.ClearDeviceNonces(ctx, "cap-device")
}
