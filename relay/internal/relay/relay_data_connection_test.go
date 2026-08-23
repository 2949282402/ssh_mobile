package relay

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

func relayDataSocketPair(t *testing.T) (*websocket.Conn, *websocket.Conn) {
	t.Helper()
	upgraded := make(chan *websocket.Conn, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
		connection, err := upgrader.Upgrade(w, r, nil)
		if err == nil {
			upgraded <- connection
		}
	}))
	t.Cleanup(server.Close)
	client, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatalf("dial test WebSocket: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	return <-upgraded, client
}

func testRelayDataPump(t *testing.T) (*relayDataConn, *websocket.Conn) {
	t.Helper()
	serverSocket, clientSocket := relayDataSocketPair(t)
	res := Reservation{
		ReservationID:     "pump-reservation",
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		InitiatorToken:    []byte{1},
		ResponderToken:    []byte{2},
		LifetimeS:         reservationLifetimeMinS,
	}
	config := Config{
		MaxPendingFramesPerDevice:   8,
		MaxPendingBytesPerDevice:    4096,
		MaxFramesPerSecondPerDevice: 8,
		MaxBytesPerSecondPerDevice:  4096,
	}
	endpoint := newRelayDataConn(newRelayDataRegistry(), res, serverSocket, config, nil, "device-a", relayDataRoleInitiator)
	go endpoint.write()
	go endpoint.read()
	return endpoint, clientSocket
}

func waitRelayDataPumpClosed(t *testing.T, endpoint *relayDataConn) {
	t.Helper()
	select {
	case <-endpoint.writeDone:
	case <-time.After(2 * time.Second):
		t.Fatal("Relay Data pump did not close")
	}
}

func TestRelayDataConnectionPoliciesFailClosedAtEachBoundary(t *testing.T) {
	res := Reservation{
		ReservationID:     "reservation-policy",
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		InitiatorToken:    []byte{1, 2, 3},
		ResponderToken:    []byte{4, 5, 6},
	}
	connect := &v2.RelayDataConnect{ReservationId: res.ReservationID, LocalToken: res.InitiatorToken}

	wrongDevice := testRelayDataConnForRegistry(res.ReservationID, "other", relayDataRoleInitiator)
	wrongDevice.res = res
	if _, ok := wrongDevice.acceptConnect(connect); ok {
		t.Fatal("initiator role must bind the exact device")
	}
	wrongResponder := testRelayDataConnForRegistry(res.ReservationID, "other", relayDataRoleResponder)
	wrongResponder.res = res
	if _, ok := wrongResponder.acceptConnect(&v2.RelayDataConnect{ReservationId: res.ReservationID, LocalToken: res.ResponderToken}); ok {
		t.Fatal("responder role must bind the exact device")
	}
	unknownRole := testRelayDataConnForRegistry(res.ReservationID, "device-a", 0)
	unknownRole.res = res
	if _, ok := unknownRole.acceptConnect(connect); ok {
		t.Fatal("unknown role must fail closed")
	}

	endpoint := testRelayDataConnForRegistry(res.ReservationID, "device-a", relayDataRoleInitiator)
	endpoint.res = res
	endpoint.startKeepalive() // unpaired endpoints never start liveness work
	if endpoint.forward(&v2.RelayDataFrame{}) {
		t.Fatal("unpaired endpoint cannot forward")
	}
	if endpoint.enqueueFrame(nil) {
		t.Fatal("invalid frame cannot enter the writer queue")
	}

	closed := testRelayDataConnForRegistry("closed", "device-a", relayDataRoleInitiator)
	closed.close()
	if closed.enqueue(outboundFrame{messageType: websocket.BinaryMessage, data: []byte{1}}) {
		t.Fatal("closed endpoint cannot enqueue")
	}
	frameLimited := testRelayDataConnForRegistry("frames", "device-a", relayDataRoleInitiator)
	frameLimited.flow.pendingFrames = frameLimited.flow.maxPendingFrames
	if frameLimited.enqueue(outboundFrame{data: []byte{1}}) {
		t.Fatal("frame budget must fail closed")
	}
	byteLimited := testRelayDataConnForRegistry("bytes", "device-a", relayDataRoleInitiator)
	byteLimited.flow.pendingBytes = byteLimited.flow.maxPendingBytes
	if byteLimited.enqueue(outboundFrame{data: []byte{1}}) {
		t.Fatal("byte budget must fail closed")
	}
	queueLimited := testRelayDataConnForRegistry("queue", "device-a", relayDataRoleInitiator)
	queueLimited.outbound = make(chan outboundFrame)
	if queueLimited.enqueue(outboundFrame{data: []byte{1}}) {
		t.Fatal("full writer queue must fail closed")
	}

	accounting := testRelayDataConnForRegistry("accounting", "device-a", relayDataRoleInitiator)
	accounting.flow.pendingBytes = 10
	accounting.flow.releaseOutbound(1)
	if accounting.flow.pendingBytes != 9 {
		t.Fatalf("remaining bytes=%d want=9", accounting.flow.pendingBytes)
	}
	accounting.flow.maxFramesPerSecond = 0
	accounting.flow.maxBytesPerSecond = 0
	if !accounting.flow.allowInbound(1) {
		t.Fatal("default positive rate budgets should admit one frame")
	}
	accounting.flow.maxFramesPerSecond = 1
	accounting.flow.framesInWindow = 1
	accounting.flow.windowStartedAt = time.Now()
	if accounting.flow.allowInbound(1) {
		t.Fatal("exhausted rate budget must fail closed")
	}
}

func TestRelayDataKeepaliveTickOwnsPingPongAndQueueFailure(t *testing.T) {
	now := time.Now()
	endpoint := testRelayDataConnForRegistry("keepalive", "device-a", relayDataRoleInitiator)
	next, stop := endpoint.keepaliveTick(now, time.Time{})
	if stop || !next.Equal(now) {
		t.Fatalf("first tick should queue ping: next=%v stop=%v", next, stop)
	}
	if frame := <-endpoint.outbound; frame.messageType != websocket.PingMessage {
		t.Fatalf("keepalive must queue a Ping, got %d", frame.messageType)
	}
	if next, stop = endpoint.keepaliveTick(now.Add(time.Second), next); stop || !next.Equal(now) {
		t.Fatal("tick inside ping interval must wait")
	}

	timedOut := testRelayDataConnForRegistry("timeout", "device-a", relayDataRoleInitiator)
	lastPing := now.Add(-relayDataPongTimeout)
	timedOut.lastPong.Store(lastPing.Add(-time.Second).UnixNano())
	if _, stop = timedOut.keepaliveTick(now, lastPing); !stop {
		t.Fatal("missing Pong must stop the endpoint")
	}
	select {
	case <-timedOut.done:
	default:
		t.Fatal("Pong timeout must close the endpoint")
	}

	queueFailure := testRelayDataConnForRegistry("queue-failure", "device-a", relayDataRoleInitiator)
	queueFailure.outbound = make(chan outboundFrame)
	if _, stop = queueFailure.keepaliveTick(now, time.Time{}); !stop {
		t.Fatal("Ping queue failure must stop the endpoint")
	}
}

func TestRelayDataPumpRejectsTransportCodecAndRateViolations(t *testing.T) {
	t.Run("control liveness", func(t *testing.T) {
		endpoint, client := testRelayDataPump(t)
		deadline := time.Now().Add(time.Second)
		if err := client.WriteControl(websocket.PingMessage, []byte("ping"), deadline); err != nil {
			t.Fatalf("write Ping: %v", err)
		}
		if err := client.WriteControl(websocket.PongMessage, []byte("pong"), deadline); err != nil {
			t.Fatalf("write Pong: %v", err)
		}
		_ = client.Close()
		waitRelayDataPumpClosed(t, endpoint)
		if endpoint.lastPong.Load() == 0 {
			t.Fatal("control liveness frames must update the Pong timestamp")
		}
	})

	t.Run("non binary", func(t *testing.T) {
		endpoint, client := testRelayDataPump(t)
		if err := client.WriteMessage(websocket.TextMessage, []byte("not binary")); err != nil {
			t.Fatalf("write text frame: %v", err)
		}
		waitRelayDataPumpClosed(t, endpoint)
	})

	t.Run("rate limit", func(t *testing.T) {
		endpoint, client := testRelayDataPump(t)
		endpoint.flow.mutex.Lock()
		endpoint.flow.framesInWindow = endpoint.flow.maxFramesPerSecond
		endpoint.flow.windowStartedAt = time.Now()
		endpoint.flow.mutex.Unlock()
		if err := client.WriteMessage(websocket.BinaryMessage, []byte{0}); err != nil {
			t.Fatalf("write rate-limited frame: %v", err)
		}
		waitRelayDataPumpClosed(t, endpoint)
	})

	t.Run("invalid codec", func(t *testing.T) {
		endpoint, client := testRelayDataPump(t)
		if err := client.WriteMessage(websocket.BinaryMessage, []byte{0}); err != nil {
			t.Fatalf("write malformed frame: %v", err)
		}
		waitRelayDataPumpClosed(t, endpoint)
	})
}

func TestRelayDataTouchStopsAtPairedExpiredAndStorelessBoundaries(t *testing.T) {
	paired := testRelayDataConnForRegistry("paired", "device-a", relayDataRoleInitiator)
	paired.paired.Store(true)
	pairedTimer := time.NewTimer(time.Hour)
	defer pairedTimer.Stop()
	paired.touch(pairedTimer)

	expired := testRelayDataConnForRegistry("expired", "device-a", relayDataRoleInitiator)
	expiredTimer := time.NewTimer(0)
	<-expiredTimer.C
	expired.touch(expiredTimer)

	storeless := testRelayDataConnForRegistry("storeless", "device-a", relayDataRoleInitiator)
	storeless.res.LifetimeS = reservationLifetimeMinS
	storelessTimer := time.NewTimer(time.Hour)
	defer storelessTimer.Stop()
	storeless.touch(storelessTimer)
}
