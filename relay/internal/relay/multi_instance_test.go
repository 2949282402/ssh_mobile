// Multi-instance validation: two Relay instances sharing one MySQL + Redis
// backend must agree on enrollment and propagate revocations across instances.
// Requires RELAY_TEST_MYSQL_DSN and RELAY_TEST_REDIS_URL; otherwise they skip.

package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func multiInstanceConfig(mysqlDSN, redisURL string) Config {
	config := mysqlTestConfig(mysqlDSN)
	config.RedisURL = redisURL
	return config
}

// injectPeer places a peer in the hub without starting read/write goroutines,
// simulating a connected device whose connection the hub can later disconnect.
// The peer carries a stable connectionID so lease operations are well-formed
// (a zero owner would make every take/renew/release miss).
func injectPeer(h *hub, deviceID string) *peer {
	peer := &peer{
		deviceID:     deviceID,
		connectionID: "conn-" + deviceID,
		outbound:     make(chan outboundFrame, 8),
		done:         make(chan struct{}),
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

// enrollViaHTTP enrolls a device against the given server base URL and returns
// the issued credential plus the device keypair (for signing connect requests).
func enrollViaHTTP(t *testing.T, baseURL, deviceID, token string) (string, ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(enrollRequest{
		DeviceID:        deviceID,
		PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
		EnrollmentToken: token,
		ProtocolVersion: 1,
		Platform:        "windows",
	})
	response, err := http.Post(baseURL+"/v1/devices/enroll", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var enrollment enrollResponse
	if response.StatusCode != http.StatusOK || json.NewDecoder(response.Body).Decode(&enrollment) != nil {
		t.Fatalf("device enrollment failed with status %d", response.StatusCode)
	}
	return enrollment.Credential, publicKey, privateKey
}

// dialDevice connects a device WebSocket to baseURL using an already-issued
// credential, signing the connect transcript with a fresh nonce, and waits for
// the server's ready frame.
func dialDevice(t *testing.T, baseURL, credential, deviceID string, nonceByte byte, privateKey ed25519.PrivateKey) *websocket.Conn {
	t.Helper()
	conn := dialDeviceNoReady(t, baseURL, credential, deviceID, nonceByte, privateKey)
	var ready controlFrame
	if conn.ReadJSON(&ready) != nil || ready.Type != "ready" || ready.DeviceID != deviceID || ready.ProtocolVersion != 1 {
		t.Fatalf("invalid ready frame: %+v", ready)
	}
	return conn
}

// dialDeviceNoReady connects a device WebSocket without waiting for the ready
// frame — used when the server's admission/lease claim is expected to block
// (e.g. the admission-ordering test gates the first claim).
func dialDeviceNoReady(t *testing.T, baseURL, credential, deviceID string, nonceByte byte, privateKey ed25519.PrivateKey) *websocket.Conn {
	t.Helper()
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{nonceByte}, 32))
	headers := http.Header{}
	headers.Set("Authorization", "Bearer "+credential)
	headers.Set("X-Relay-Nonce", nonce)
	headers.Set("X-Relay-Signature", base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, []byte("GET\n/v1/connect\n"+nonce)),
	))
	relayURL, err := url.Parse(baseURL)
	if err != nil {
		t.Fatal(err)
	}
	relayURL.Scheme = "ws"
	relayURL.Path = "/v1/connect"
	conn, response, err := websocket.DefaultDialer.Dial(relayURL.String(), headers)
	if err != nil {
		status := 0
		if response != nil {
			status = response.StatusCode
		}
		t.Fatalf("websocket connect failed with status %d: %v", status, err)
	}
	return conn
}

// TestMultiInstanceConnectionReplacement verifies the Step-2 replacement path
// end to end over the shared backend: a device connected to instance A then
// reconnecting to instance B makes B the lease owner immediately (via the
// targeted connection.replaced event, not the next heartbeat), closes A's
// socket, and A's teardown does not erase B's presence.
func TestMultiInstanceConnectionReplacement(t *testing.T) {
	mysqlDSN := requireMySQLDSN(t)
	redisURL := requireRedisURL(t)
	ctx := context.Background()

	configA := multiInstanceConfig(mysqlDSN, redisURL)
	configA.InstanceID = "instance-a"
	serverA, err := OpenServer(configA)
	if err != nil {
		t.Fatalf("open instance A: %v", err)
	}
	defer serverA.Close()
	configB := multiInstanceConfig(mysqlDSN, redisURL)
	configB.InstanceID = "instance-b"
	serverB, err := OpenServer(configB)
	if err != nil {
		t.Fatalf("open instance B: %v", err)
	}
	defer serverB.Close()
	resetMySQLTestDB(t, mysqlDSN)

	muxA, muxB := http.NewServeMux(), http.NewServeMux()
	serverA.RegisterRoutes(muxA)
	serverB.RegisterRoutes(muxB)
	httpA := httptest.NewServer(muxA)
	defer httpA.Close()
	httpB := httptest.NewServer(muxB)
	defer httpB.Close()

	credential, _, privateKey := enrollViaHTTP(t, httpA.URL, "device-x", "test-token")

	connA := dialDevice(t, httpA.URL, credential, "device-x", 0x10, privateKey)
	defer connA.Close()

	// Wait until A's connection holds the lease.
	waitOwner := func(server *Server, wantInstance string) *peer {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			server.hub.mutex.Lock()
			peer := server.hub.peers["device-x"]
			server.hub.mutex.Unlock()
			if peer == nil {
				time.Sleep(20 * time.Millisecond)
				continue
			}
			presence, present, _ := server.cache.GetPresence(ctx, "device-x")
			if present && presence.ConnectionID == peer.connectionID {
				return peer
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatalf("instance %s did not claim the lease for device-x", wantInstance)
		return nil
	}
	peerA := waitOwner(serverA, "A")

	// Reconnect to B: B claims, publishes connection.replaced, A must close now.
	connB := dialDevice(t, httpB.URL, credential, "device-x", 0x11, privateKey)
	defer connB.Close()
	peerB := waitOwner(serverB, "B")

	// A's superseded socket must be closed by the targeted event (not the next
	// heartbeat), so wait for the connection to actually die.
	deadline := time.Now().Add(5 * time.Second)
	closed := false
	for time.Now().Before(deadline) {
		_ = connA.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		if _, _, err := connA.ReadMessage(); err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				time.Sleep(50 * time.Millisecond)
				continue
			}
			closed = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	_ = connA.SetReadDeadline(time.Time{})
	if !closed {
		t.Fatal("instance A did not close the superseded connection after replacement")
	}
	_ = peerA // A's peer is closed by the event; keep the reference for clarity.

	// B remains fully usable: heartbeat round-trip still answers.
	if err := connB.WriteJSON(controlFrame{Type: "heartbeat", Timestamp: time.Now().UnixMilli()}); err != nil {
		t.Fatal(err)
	}
	var ack controlFrame
	if err := connB.ReadJSON(&ack); err != nil || ack.Type != "heartbeat_ack" {
		t.Fatalf("B did not answer heartbeat after replacement: %+v (%v)", ack, err)
	}

	// A's teardown must not erase B's presence.
	time.Sleep(200 * time.Millisecond)
	presence, present, err := serverB.cache.GetPresence(ctx, "device-x")
	if err != nil || !present {
		t.Fatalf("B's presence lost after A teardown: present=%v err=%v", present, err)
	}
	if peerB == nil || presence.ConnectionID != peerB.connectionID {
		t.Fatalf("lease owner should be B's connection, got %q (want %q)", presence.ConnectionID, peerB.connectionID)
	}
}

// TestMultiInstanceAdminSnapshotShowsRemoteAddrFromLease verifies the admin
// device snapshot reports the remote address of the instance that actually holds
// the lease: a device connected to instance B appears in A's admin snapshot as
// online with B's connection address, not an empty local-hub address.
func TestMultiInstanceAdminSnapshotShowsRemoteAddrFromLease(t *testing.T) {
	mysqlDSN := requireMySQLDSN(t)
	redisURL := requireRedisURL(t)
	ctx := context.Background()

	configA := multiInstanceConfig(mysqlDSN, redisURL)
	configA.InstanceID = "instance-a"
	serverA, err := OpenServer(configA)
	if err != nil {
		t.Fatalf("open instance A: %v", err)
	}
	defer serverA.Close()
	configB := multiInstanceConfig(mysqlDSN, redisURL)
	configB.InstanceID = "instance-b"
	serverB, err := OpenServer(configB)
	if err != nil {
		t.Fatalf("open instance B: %v", err)
	}
	defer serverB.Close()
	resetMySQLTestDB(t, mysqlDSN)

	muxA, muxB := http.NewServeMux(), http.NewServeMux()
	serverA.RegisterRoutes(muxA)
	serverB.RegisterRoutes(muxB)
	httpA := httptest.NewServer(muxA)
	defer httpA.Close()
	httpB := httptest.NewServer(muxB)
	defer httpB.Close()

	credential, _, privateKey := enrollViaHTTP(t, httpA.URL, "device-x", "test-token")

	connB := dialDevice(t, httpB.URL, credential, "device-x", 0x12, privateKey)
	defer connB.Close()

	// Wait until B holds the lease for device-x.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		presence, present, _ := serverB.cache.GetPresence(ctx, "device-x")
		if present && presence.InstanceID == "instance-b" {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	// A's admin snapshot must show the device online with B's connection address.
	items, presenceAvailable, err := serverA.adminDeviceSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if !presenceAvailable {
		t.Fatal("cross-instance snapshot should have presence available")
	}
	if len(items) != 1 || !items[0].Online || items[0].RemoteAddr == "" {
		t.Fatalf("A's admin snapshot should show device-x online with B's remote address: %+v", items)
	}
	presence, present, _ := serverB.cache.GetPresence(ctx, "device-x")
	if !present || items[0].RemoteAddr != presence.RemoteAddr {
		t.Fatalf("A's snapshot address (%q) should equal the lease holder's address (%q)", items[0].RemoteAddr, presence.RemoteAddr)
	}
}
