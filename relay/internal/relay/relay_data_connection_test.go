package relay

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

type cancellationIgnoringReservationStore struct {
	started chan struct{}
	release chan struct{}
}

type relayDataBlockingWriteConn struct {
	net.Conn
	armed       chan struct{}
	started     chan struct{}
	release     chan struct{}
	armOnce     sync.Once
	startedOnce sync.Once
	releaseOnce sync.Once
}

func newRelayDataBlockingWriteConn(conn net.Conn) *relayDataBlockingWriteConn {
	return &relayDataBlockingWriteConn{
		Conn:    conn,
		armed:   make(chan struct{}),
		started: make(chan struct{}),
		release: make(chan struct{}),
	}
}

func (conn *relayDataBlockingWriteConn) Write(data []byte) (int, error) {
	select {
	case <-conn.armed:
		conn.startedOnce.Do(func() { close(conn.started) })
		<-conn.release
	default:
	}
	return conn.Conn.Write(data)
}

func (conn *relayDataBlockingWriteConn) armWrites() {
	conn.armOnce.Do(func() { close(conn.armed) })
}

func (conn *relayDataBlockingWriteConn) releaseWrites() {
	conn.releaseOnce.Do(func() { close(conn.release) })
}

type relayDataBlockingWriteListener struct {
	net.Listener
	accepted chan *relayDataBlockingWriteConn
}

func (listener *relayDataBlockingWriteListener) Accept() (net.Conn, error) {
	conn, err := listener.Listener.Accept()
	if err != nil {
		return nil, err
	}
	blocking := newRelayDataBlockingWriteConn(conn)
	select {
	case listener.accepted <- blocking:
	default:
	}
	return blocking, nil
}

func (store *cancellationIgnoringReservationStore) DeleteReservation(context.Context, string) error {
	return nil
}

func (store *cancellationIgnoringReservationStore) RenewReservation(context.Context, string, time.Duration) (bool, error) {
	select {
	case store.started <- struct{}{}:
	default:
	}
	<-store.release
	return true, nil
}

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

func relayDataBlockingSocketPair(t *testing.T) (*websocket.Conn, *websocket.Conn, *relayDataBlockingWriteConn) {
	t.Helper()
	upgraded := make(chan *websocket.Conn, 1)
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
		connection, err := upgrader.Upgrade(w, r, nil)
		if err == nil {
			upgraded <- connection
		}
	}))
	listener := &relayDataBlockingWriteListener{
		Listener: server.Listener,
		accepted: make(chan *relayDataBlockingWriteConn, 1),
	}
	server.Listener = listener
	server.Start()
	t.Cleanup(server.Close)

	client, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatalf("dial blocking test WebSocket: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	blocking := <-listener.accepted
	t.Cleanup(blocking.releaseWrites)
	return <-upgraded, client, blocking
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
	registry := newRelayDataRegistry(8)
	t.Cleanup(registry.closeAll)
	endpoint := newRelayDataConn(registry, res, serverSocket, config, nil, "device-a", relayDataRoleInitiator)
	lease, status := registry.beginUpgrade("device-a")
	if status != relayDataUpgradeAccepted || !registry.startEndpoint(lease, endpoint) {
		t.Fatal("start Relay Data test pump")
	}
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

func TestRelayDataRegistryCloseAllWaitsForOwnedPumps(t *testing.T) {
	serverSocket, clientSocket := relayDataSocketPair(t)
	registry := newRelayDataRegistry(1)
	config := withConfigDefaults(Config{})
	endpoint := newRelayDataConn(registry, Reservation{
		ReservationID:     "shutdown-reservation",
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		InitiatorToken:    []byte{1},
		ResponderToken:    []byte{2},
		LifetimeS:         reservationLifetimeMinS,
	}, serverSocket, config, nil, "device-a", relayDataRoleInitiator)
	lease, status := registry.beginUpgrade("device-a")
	if status != relayDataUpgradeAccepted || !registry.startEndpoint(lease, endpoint) {
		t.Fatalf("start endpoint: status=%v", status)
	}

	closed := make(chan struct{})
	go func() {
		registry.closeAll()
		close(closed)
	}()
	select {
	case <-closed:
	case <-time.After(2 * time.Second):
		t.Fatal("registry shutdown did not wait for pumps to converge")
	}
	select {
	case <-endpoint.writeDone:
	default:
		t.Fatal("closeAll returned before the writer pump completed")
	}
	_ = clientSocket.Close()

	// Both the permanent gate and repeated Close behavior are part of the
	// lifecycle contract.
	registry.closeAll()
	if _, status := registry.beginUpgrade("device-b"); status != relayDataUpgradeClosed {
		t.Fatalf("post-close upgrade status=%v want closed", status)
	}
}

func TestRelayDataRegistryCloseIsBoundedWhenReservationStoreIgnoresContext(t *testing.T) {
	serverSocket, clientSocket := relayDataSocketPair(t)
	registry := newRelayDataRegistry(1)
	store := &cancellationIgnoringReservationStore{
		started: make(chan struct{}, 1),
		release: make(chan struct{}),
	}
	config := withConfigDefaults(Config{})
	reservation := Reservation{
		ReservationID:     strings.Repeat("a", 32),
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		InitiatorToken:    []byte(strings.Repeat("i", 32)),
		ResponderToken:    []byte(strings.Repeat("r", 32)),
		LifetimeS:         reservationLifetimeMinS,
	}
	endpoint := newRelayDataConn(registry, reservation, serverSocket, config, store, "device-a", relayDataRoleInitiator)
	lease, status := registry.beginUpgrade("device-a")
	if status != relayDataUpgradeAccepted || !registry.startEndpoint(lease, endpoint) {
		t.Fatalf("start endpoint: status=%v", status)
	}
	connect, err := v2.EncodeDataFrame(&v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
			ReservationId: reservation.ReservationID,
			LocalToken:    reservation.InitiatorToken,
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := clientSocket.WriteMessage(websocket.BinaryMessage, connect); err != nil {
		t.Fatalf("write RelayDataConnect: %v", err)
	}
	select {
	case <-store.started:
	case <-time.After(time.Second):
		t.Fatal("RelayData pump did not enter the blocking reservation renewal")
	}

	closeCtx, closeCancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	startedAt := time.Now()
	registry.closeAllWithContext(closeCtx)
	closeCancel()
	if elapsed := time.Since(startedAt); elapsed > 500*time.Millisecond {
		t.Fatalf("bounded RelayData close took %s", elapsed)
	}
	if _, status := registry.beginUpgrade("device-b"); status != relayDataUpgradeClosed {
		t.Fatalf("post-close upgrade status=%v want closed", status)
	}

	// Let the deliberately non-compliant fake return so the owned pump can
	// converge and the test leaves no goroutine behind.
	close(store.release)
	select {
	case <-endpoint.writeDone:
	case <-time.After(time.Second):
		t.Fatal("forced socket close did not converge the writer")
	}
	_ = clientSocket.Close()
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
	if closed.enqueue(relayDataOutboundFrame{messageType: websocket.BinaryMessage, data: []byte{1}}) {
		t.Fatal("closed endpoint cannot enqueue")
	}
	frameLimited := testRelayDataConnForRegistry("frames", "device-a", relayDataRoleInitiator)
	frameLimited.flow.pendingFrames = frameLimited.flow.maxPendingFrames
	if frameLimited.enqueue(relayDataOutboundFrame{data: []byte{1}}) {
		t.Fatal("frame budget must fail closed")
	}
	byteLimited := testRelayDataConnForRegistry("bytes", "device-a", relayDataRoleInitiator)
	byteLimited.flow.pendingBytes = byteLimited.flow.maxPendingBytes
	if byteLimited.enqueue(relayDataOutboundFrame{data: []byte{1}}) {
		t.Fatal("byte budget must fail closed")
	}
	queueLimited := testRelayDataConnForRegistry("queue", "device-a", relayDataRoleInitiator)
	queueLimited.outbound = make(chan relayDataOutboundFrame)
	if queueLimited.enqueue(relayDataOutboundFrame{data: []byte{1}}) {
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

func TestRelayDataForwardWaitsForPairReadyWrite(t *testing.T) {
	serverSocket, _ := relayDataSocketPair(t)
	registry := newRelayDataRegistry(1)
	sender := testRelayDataConnForRegistry("pair-ready-sent", "device-a", relayDataRoleInitiator)
	receiver := testRelayDataConnForRegistry("pair-ready-sent", "device-b", relayDataRoleResponder)
	sender.registry = registry
	receiver.registry = registry
	sender.socket = serverSocket
	if _, ok := registry.admitEndpoint(sender); !ok {
		t.Fatal("sender admission failed")
	}
	if peer, ok := registry.admitEndpoint(receiver); !ok || peer != sender {
		t.Fatalf("receiver admission: peer=%p ok=%v", peer, ok)
	}

	payload := &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Payload{Payload: &v2.RelayDataPayload{
			Sequence:         1,
			EncryptedPayload: []byte("opaque"),
		}},
	}
	if sender.forward(payload) {
		t.Fatal("pipelined payload crossed before PairReady was written")
	}

	senderMarker := <-sender.outbound
	receiverMarker := <-receiver.outbound
	receiver.flow.releaseOutbound(len(receiverMarker.data))
	if !sender.writeOutbound(senderMarker, time.Second) {
		t.Fatal("PairReady write failed")
	}
	if !sender.pairReadySent.Load() {
		t.Fatal("successful PairReady write did not open the sender barrier")
	}
	if !sender.forward(payload) {
		t.Fatal("payload remained blocked after PairReady was written")
	}
	if frame := <-receiver.outbound; frame.messageType != websocket.BinaryMessage {
		t.Fatalf("forwarded frame type=%d want binary", frame.messageType)
	}
}

func TestRelayDataRevocationLinearizesBeforeBufferedFrameDispatch(t *testing.T) {
	serverSocket, clientSocket := relayDataSocketPair(t)
	registry := newRelayDataRegistry(1)
	sender := testRelayDataConnForRegistry("revocation-linearization", "device-a", relayDataRoleInitiator)
	receiver := testRelayDataConnForRegistry("revocation-linearization", "device-b", relayDataRoleResponder)
	sender.registry = registry
	receiver.registry = registry
	receiver.socket = serverSocket
	if _, ok := registry.admitEndpoint(sender); !ok {
		t.Fatal("sender admission failed")
	}
	if peer, ok := registry.admitEndpoint(receiver); !ok || peer != sender {
		t.Fatalf("receiver admission: peer=%p ok=%v", peer, ok)
	}
	for _, endpoint := range []*relayDataConn{sender, receiver} {
		marker := <-endpoint.outbound
		if marker.pairReady == nil || !marker.pairReady.wait() {
			t.Fatal("pair-ready decision was not committed")
		}
		endpoint.flow.releaseOutbound(len(marker.data))
	}
	// Simulate the sender writer having published its PairReady marker. The
	// receiver queue now contains one business frame that has not reached the
	// socket when revocation begins.
	sender.pairReadySent.Store(true)
	payload := &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Payload{Payload: &v2.RelayDataPayload{
			Sequence:         7,
			EncryptedPayload: []byte("buffered-before-revoke"),
		}},
	}
	if !sender.forward(payload) {
		t.Fatal("active pair did not queue the pre-revocation frame")
	}

	registry.closeDevice("device-a")
	if !sender.isTerminal() || !receiver.isTerminal() {
		t.Fatal("revocation did not terminalize both active endpoints")
	}
	if registry.activePairCount() != 0 {
		t.Fatal("revoked pair remained active")
	}
	if _, ok := registry.retryReservation(sender.reservationID); ok {
		t.Fatal("revoked pair remained eligible for retry admission")
	}
	if _, ok := registry.admitEndpoint(sender); ok {
		t.Fatal("terminal endpoint was admitted again")
	}
	if sender.forward(payload) {
		t.Fatal("post-linearization frame crossed the revoked pair")
	}

	// Shutdown draining must discard the queued business frame and preserve only
	// the terminal RelayDataClose. This models a frame already buffered between
	// read dispatch and the single writer when revocation linearizes.
	receiver.drainOutbound()
	if err := clientSocket.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	kind, data, err := clientSocket.ReadMessage()
	if err != nil {
		t.Fatalf("read terminal frame: %v", err)
	}
	if kind != websocket.BinaryMessage {
		t.Fatalf("terminal frame type=%d want binary", kind)
	}
	frame, err := v2.DecodeData(data)
	if err != nil {
		t.Fatalf("decode terminal frame: %v", err)
	}
	if frame.GetClose() == nil || frame.GetPayload() != nil {
		t.Fatalf("buffered payload crossed revocation: %+v", frame)
	}
}

func TestRelayDataRevocationWaitsForInFlightForwardWrite(t *testing.T) {
	serverSocket, clientSocket, blocking := relayDataBlockingSocketPair(t)
	registry := newRelayDataRegistry(1)
	sender := testRelayDataConnForRegistry("revocation-in-flight", "device-a", relayDataRoleInitiator)
	receiver := testRelayDataConnForRegistry("revocation-in-flight", "device-b", relayDataRoleResponder)
	sender.registry = registry
	receiver.registry = registry
	receiver.socket = serverSocket
	if _, ok := registry.admitEndpoint(sender); !ok {
		t.Fatal("sender admission failed")
	}
	if peer, ok := registry.admitEndpoint(receiver); !ok || peer != sender {
		t.Fatalf("receiver admission: peer=%p ok=%v", peer, ok)
	}
	for _, endpoint := range []*relayDataConn{sender, receiver} {
		marker := <-endpoint.outbound
		if marker.pairReady == nil || !marker.pairReady.wait() {
			t.Fatal("pair-ready decision was not committed")
		}
		endpoint.flow.releaseOutbound(len(marker.data))
	}
	sender.pairReadySent.Store(true)
	payload := &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Payload{Payload: &v2.RelayDataPayload{
			Sequence:         11,
			EncryptedPayload: []byte("in-flight-before-revoke"),
		}},
	}
	if !sender.forward(payload) {
		t.Fatal("active pair did not queue the forwarded frame")
	}
	outbound := <-receiver.outbound

	blocking.armWrites()
	writeResult := make(chan bool, 1)
	go func() {
		writeResult <- receiver.writeOutbound(outbound, time.Second)
	}()
	select {
	case <-blocking.started:
	case <-time.After(time.Second):
		t.Fatal("forwarded frame did not enter the socket write")
	}
	if receiver.writeGate.TryLock() {
		receiver.writeGate.Unlock()
		t.Fatal("real socket write was not protected by writeGate")
	}

	revoked := make(chan struct{})
	go func() {
		registry.closeDevice("device-a")
		close(revoked)
	}()
	terminalDeadline := time.NewTimer(time.Second)
	terminalPoll := time.NewTicker(time.Millisecond)
	defer terminalDeadline.Stop()
	defer terminalPoll.Stop()
	for !sender.isTerminal() || !receiver.isTerminal() {
		select {
		case <-terminalDeadline.C:
			t.Fatal("revocation did not reach its terminal linearization point")
		case <-terminalPoll.C:
		}
	}
	select {
	case <-revoked:
		t.Fatal("revocation returned while a pre-linearization write was in flight")
	case <-time.After(20 * time.Millisecond):
	}

	blocking.releaseWrites()
	select {
	case ok := <-writeResult:
		if !ok {
			t.Fatal("in-flight WebSocket write failed after release")
		}
	case <-time.After(time.Second):
		t.Fatal("in-flight WebSocket write did not quiesce")
	}
	select {
	case <-revoked:
	case <-time.After(time.Second):
		t.Fatal("revocation did not return after the write quiesced")
	}

	if err := clientSocket.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	kind, data, err := clientSocket.ReadMessage()
	if err != nil {
		t.Fatalf("read in-flight frame: %v", err)
	}
	if kind != websocket.BinaryMessage {
		t.Fatalf("in-flight frame type=%d want binary", kind)
	}
	frame, err := v2.DecodeData(data)
	if err != nil {
		t.Fatalf("decode in-flight frame: %v", err)
	}
	if forwarded := frame.GetPayload(); forwarded == nil || forwarded.Sequence != 11 {
		t.Fatalf("unexpected in-flight frame: %+v", frame)
	}
	if sender.forward(payload) {
		t.Fatal("post-revocation frame crossed the terminal pair")
	}
}

func TestRelayDataKeepaliveTickOwnsPingPongAndQueueFailure(t *testing.T) {
	now := time.Now()
	endpoint := testRelayDataConnForRegistry("keepalive", "device-a", relayDataRoleInitiator)
	next, stop := endpoint.keepaliveTick(now, time.Time{})
	if stop || !next.Equal(now) {
		t.Fatalf("first tick should queue ping: next=%v stop=%v", next, stop)
	}
	if frame := <-endpoint.outbound; frame.messageType != websocket.PingMessage || string(frame.data) != relayDataKeepalivePing || frame.pairReady != nil {
		t.Fatalf("keepalive must use its distinct Ping marker, got type=%d payload=%q pair_ready=%v",
			frame.messageType, frame.data, frame.pairReady != nil)
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
	queueFailure.outbound = make(chan relayDataOutboundFrame)
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
