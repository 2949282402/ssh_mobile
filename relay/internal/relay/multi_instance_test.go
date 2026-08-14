// Multi-instance validation: two Relay instances sharing one MySQL + Redis
// backend must agree on enrollment and propagate revocations across instances.
// Requires RELAY_TEST_MYSQL_DSN and RELAY_TEST_REDIS_URL; otherwise they skip.

package relay

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func multiInstanceConfig(mysqlDSN, redisURL string) Config {
	config := mysqlTestConfig(mysqlDSN)
	config.RedisURL = redisURL
	return config
}

// injectPeer places a peer in the hub without starting read/write goroutines,
// simulating a connected device whose connection the hub can later disconnect.
func injectPeer(h *hub, deviceID string) *peer {
	peer := &peer{
		deviceID: deviceID,
		outbound: make(chan outboundFrame, 8),
		done:     make(chan struct{}),
	}
	h.mutex.Lock()
	h.peers[deviceID] = peer
	h.mutex.Unlock()
	return peer
}

// TestMultiInstanceSharedAuth verifies a device enrolled through instance A can
// authenticate against instance B: enrollment is shared via MySQL and the
// credential is verified with the shared CredentialKey.
func TestMultiInstanceSharedAuth(t *testing.T) {
	mysqlDSN := requireMySQLDSN(t)
	redisURL := requireRedisURL(t)
	config := multiInstanceConfig(mysqlDSN, redisURL)

	serverA, err := OpenServer(config)
	if err != nil {
		t.Fatalf("open instance A: %v", err)
	}
	defer serverA.Close()
	serverB, err := OpenServer(config)
	if err != nil {
		t.Fatalf("open instance B: %v", err)
	}
	defer serverB.Close()
	resetMySQLTestDB(t, mysqlDSN)

	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if result := serverA.replaceEnrollment("device-a", base64.RawURLEncoding.EncodeToString(publicKey), "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}

	credential, err := issueCredential([]byte(mysqlTestCredentialKey), "device-a", publicKey, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{6}, 32))
	request := httptest.NewRequest("GET", "/v1/connect", nil)
	request.Header.Set("Authorization", "Bearer "+credential)
	request.Header.Set("X-Relay-Nonce", nonce)
	request.Header.Set("X-Relay-Signature", base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, []byte("GET\n/v1/connect\n"+nonce)),
	))
	if _, _, _, ok := serverB.authenticatedRequest(request); !ok {
		t.Fatal("device could not authenticate against a different instance sharing the same backend")
	}
}

// TestMultiInstanceCrossInstanceRevoke verifies a revocation issued on instance
// A propagates over the Redis event bus and disconnects the device connected to
// instance B.
func TestMultiInstanceCrossInstanceRevoke(t *testing.T) {
	mysqlDSN := requireMySQLDSN(t)
	redisURL := requireRedisURL(t)
	config := multiInstanceConfig(mysqlDSN, redisURL)

	serverA, err := OpenServer(config)
	if err != nil {
		t.Fatalf("open instance A: %v", err)
	}
	defer serverA.Close()
	serverB, err := OpenServer(config)
	if err != nil {
		t.Fatalf("open instance B: %v", err)
	}
	defer serverB.Close()
	resetMySQLTestDB(t, mysqlDSN)

	if result := serverA.replaceEnrollment("device-x", "key-x", "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	// The device is connected to instance B only.
	injectPeer(serverB.hub, "device-x")

	revokeRequest := httptest.NewRequest(http.MethodPost, "/api/admin/v1/devices/device-x/revoke", nil)
	revokeRequest.SetPathValue("deviceId", "device-x")
	rec := httptest.NewRecorder()
	serverA.adminRevokeDevice(rec, revokeRequest)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("revoke on instance A failed: %d", rec.Code)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		serverB.hub.mutex.Lock()
		_, present := serverB.hub.peers["device-x"]
		serverB.hub.mutex.Unlock()
		if !present {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("instance B did not disconnect the device after cross-instance revoke")
}
