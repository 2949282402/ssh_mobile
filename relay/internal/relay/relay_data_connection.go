// Relay Data connection pump, liveness, and bounded flow control.

package relay

import (
	"context"
	"crypto/hmac"
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

const (
	relayDataWriteTimeout = 10 * time.Second
	// Shutdown drains preserve queued ordering (especially RelayDataClose) but
	// use one total budget per endpoint; a full 64-frame queue must not turn
	// Server.Close into 64 sequential one-second waits.
	relayDataDrainTimeout = 2 * time.Second
	// Pair liveness is independent from reservation admission TTL once both
	// roles are ready. Every WebSocket control/data write remains serialized by
	// the same outbound writer.
	relayDataPingInterval  = 30 * time.Second
	relayDataPongTimeout   = 15 * time.Second
	relayDataPairReadyPing = "ssh-mobile-relay-paired-v1:"
	relayDataKeepalivePing = "ssh-mobile-relay-keepalive-v1"
)

// relayDataPairReadyDecision is the commit barrier shared by both PairReady
// frames. A writer may dequeue its frame immediately, but it cannot publish the
// Ping until the registry has placed the counterpart frame and commits. An
// aborted decision makes both writers discard their frame.
type relayDataPairReadyDecision struct {
	once      sync.Once
	committed bool
	done      chan struct{}
}

func newRelayDataPairReadyDecision() *relayDataPairReadyDecision {
	return &relayDataPairReadyDecision{done: make(chan struct{})}
}

func (d *relayDataPairReadyDecision) resolve(committed bool) {
	d.once.Do(func() {
		d.committed = committed
		close(d.done)
	})
}

func (d *relayDataPairReadyDecision) wait() bool {
	<-d.done
	return d.committed
}

type relayDataOutboundFrame struct {
	messageType          int
	data                 []byte
	pairReady            *relayDataPairReadyDecision
	allowedAfterTerminal bool
}

// relayDataPairOwner is the narrow one-shot pairing capability borrowed by a
// connection pump. The concrete registry retains revocation and shutdown APIs.
type relayDataPairOwner interface {
	admitEndpoint(*relayDataConn) (*relayDataConn, bool)
	releaseEndpoint(*relayDataConn)
	forwardEndpoint(*relayDataConn, relayDataOutboundFrame) bool
}

// reservationLeaseStore is the only shared-state capability needed after HTTP
// admission. It cannot read unrelated presence, enrollment, or admin state.
type reservationLeaseStore interface {
	DeleteReservation(context.Context, string) error
	RenewReservation(context.Context, string, time.Duration) (bool, error)
}

// relayDataConn 是 /v2/relay/{reservation_id} 的一个端点。它没有 presence 租约，
// 只用 reservation 校验身份；peer 是同一 reservation 的另一端点（由 registry 链接）。
// 写侧：read goroutine 阻塞读 socket，write goroutine 从 outbound 写帧并在 close 时
// 先 drain 再关 socket，保证 RelayDataClose 帧能被冲刷到对端。
type relayDataConn struct {
	reservationID        string
	res                  Reservation
	deviceID             string
	enrollmentGeneration int64
	role                 relayDataRole
	registry             relayDataPairOwner
	reservations         reservationLeaseStore
	socket               *websocket.Conn
	outbound             chan relayDataOutboundFrame
	done                 chan struct{}
	writeDone            chan struct{}
	once                 sync.Once
	terminal             atomic.Bool
	writeGate            sync.Mutex
	activation           chan struct{}
	activationOnce       sync.Once
	admissionActive      atomic.Bool
	lifecycleCtx         context.Context
	grace                time.Duration

	peerMutex sync.Mutex
	peer      *relayDataConn
	ready     atomic.Bool
	paired    atomic.Bool
	// pairReadySent becomes true only after this endpoint's writer has
	// successfully written the one-shot PairReady Ping to its socket. Registry
	// readiness alone is insufficient: a pipelined client frame must not cross
	// the data plane while its setup signal is merely queued.
	pairReadySent atomic.Bool
	lastPong      atomic.Int64
	flow          relayDataFlowBudget
}

func newRelayDataConn(registry relayDataPairOwner, res Reservation, socket *websocket.Conn, config Config, reservations reservationLeaseStore, deviceID string, role relayDataRole, generation ...int64) *relayDataConn {
	enrollmentGeneration := int64(0)
	if len(generation) > 0 {
		enrollmentGeneration = generation[0]
	}
	return &relayDataConn{
		reservationID:        res.ReservationID,
		res:                  res,
		deviceID:             deviceID,
		enrollmentGeneration: enrollmentGeneration,
		role:                 role,
		registry:             registry,
		reservations:         reservations,
		socket:               socket,
		outbound:             make(chan relayDataOutboundFrame, config.MaxPendingFramesPerDevice),
		done:                 make(chan struct{}),
		writeDone:            make(chan struct{}),
		activation:           make(chan struct{}),
		grace:                time.Duration(v2.RESERVATION_EXPIRY_GRACE_S) * time.Second,
		flow:                 newRelayDataFlowBudget(config),
	}
}

// link 把 rc 与对端互相绑定（在 registry.mutex 下调用）。
func (rc *relayDataConn) link(other *relayDataConn) {
	rc.peerMutex.Lock()
	other.peerMutex.Lock()
	rc.peer = other
	other.peer = rc
	other.peerMutex.Unlock()
	rc.peerMutex.Unlock()
}

// clearPeer 解除 rc 到对端的引用（在 registry.mutex 下调用）。
func (rc *relayDataConn) clearPeer() {
	rc.peerMutex.Lock()
	rc.peer = nil
	rc.peerMutex.Unlock()
}

// peerConn 返回对端端点；无锁读取不安全，因此走 peerMutex。
func (rc *relayDataConn) peerConn() *relayDataConn {
	rc.peerMutex.Lock()
	defer rc.peerMutex.Unlock()
	return rc.peer
}

// read 是数据面读循环：第一帧必须是 RelayDataConnect（校验 reservation_id + token），
// Relay 在两个角色都加入后发送 PairReady Ping；之后 RelayDataPayload/RelayDataAck
// 才能原样转发给对端。RelayDataClose 转发后双向关闭。任何协议违规 / 过期 / 预算
// 超限都以 RelayDataClose(reason 1/2) 收场。
func (rc *relayDataConn) read() {
	defer func() {
		rc.close()
		// 先捕获对端再 unregister：unregister(rc) 会 clearPeer 把 rc.peer 置空，若在
		// unregister 之后才读 peer，异常关闭时对端永远不会被通知（死代码）。捕获后
		// 主动向对端投递 RelayDataClose(reason 2)，让它立即关闭而不是空等到自己的
		// 滑动窗口到期定时器触发。
		other := rc.peerConn()
		rc.registry.releaseEndpoint(rc)
		if other != nil {
			other.sendCloseAndShutdown(2, "relay peer disconnected")
		}
		<-rc.writeDone
	}()
	if !rc.waitForActivation() {
		return
	}
	rc.socket.SetReadLimit(v2.MAX_RELAY_DATA_FRAME_BYTES)
	// Gorilla invokes these handlers from the single read goroutine.  Responses
	// are queued instead of calling WriteControl/WriteMessage directly, so every
	// WebSocket write (Pong, keepalive Ping, PairReady Ping, binary frames and
	// Close) has one owner.
	rc.lastPong.Store(time.Now().UnixNano())
	rc.socket.SetPingHandler(func(payload string) error {
		rc.lastPong.Store(time.Now().UnixNano())
		if !rc.enqueue(relayDataOutboundFrame{messageType: websocket.PongMessage, data: []byte(payload)}) {
			return errors.New("relay pong queue is closed")
		}
		return nil
	})
	rc.socket.SetPongHandler(func(string) error {
		rc.lastPong.Store(time.Now().UnixNano())
		return nil
	})
	// reservation 到期（含 5s 宽限）即强制关闭。到期定时器是滑动窗口：初始窗口用
	// refreshTTL()（now+lifetime+grace，与 touch 的续期语义一致）而不是名义
	// ExpiresAtMs——晚加入的端点拿到的是全新窗口；每次成功的数据面帧
	// （RelayDataConnect/Payload/Ack）都重置窗口（见 touch），流量不断则连接不被
	// 一次性定时器中断；空闲到窗口末尾仍以 reason 1 强制关闭。
	expiryTimer := time.AfterFunc(rc.refreshTTL(), func() {
		if rc.paired.Load() {
			return
		}
		rc.sendCloseAndShutdown(1, "reservation expired")
	})
	defer expiryTimer.Stop()

	connected := false
	for {
		if rc.isTerminal() {
			return
		}
		kind, data, err := rc.socket.ReadMessage()
		if err != nil {
			return
		}
		// Revocation linearizes in the registry before transport shutdown. A frame
		// that was already buffered in Gorilla or the kernel must not be decoded or
		// dispatched after that point.
		if rc.isTerminal() {
			return
		}
		if kind != websocket.BinaryMessage {
			rc.sendCloseAndShutdown(2, "only binary frames are allowed on /v2/relay")
			return
		}
		if !rc.flow.allowInbound(len(data)) {
			rc.sendCloseAndShutdown(2, "relay data rate limit exceeded")
			return
		}
		frame, err := v2.DecodeData(data)
		if err != nil {
			rc.sendCloseAndShutdown(2, v2.ErrorCodeOf(err).String())
			return
		}
		// Decode is bounded but still concurrent with revocation. Recheck before
		// every protocol dispatch so an in-flight decode cannot cross the terminal
		// boundary.
		if rc.isTerminal() {
			return
		}
		if !connected {
			connect := frame.GetConnect()
			if connect == nil {
				rc.sendCloseAndShutdown(2, "first frame must be relay_data_connect")
				return
			}
			role, ok := rc.acceptConnect(connect)
			if !ok {
				rc.sendCloseAndShutdown(2, "invalid reservation id or token")
				return
			}
			rc.role = role
			connected = true
			peer, registered := rc.registry.admitEndpoint(rc)
			if !registered {
				rc.sendCloseAndShutdown(2, "relay data admission rejected")
				// A non-nil peer means PairReady could not be queued after both
				// roles were linked. The registry rolled the whole pair back; close
				// the previously pending endpoint as well so it cannot linger.
				if peer != nil {
					peer.sendCloseAndShutdown(2, "relay data pairing ready notification failed")
				}
				return
			}
			if peer != nil && !rc.ready.Load() {
				rc.sendCloseAndShutdown(2, "relay data pairing ready notification failed")
				return
			}
			if peer != nil && rc.ready.Load() {
				// Pairing consumes admission.  The active sockets retain the
				// reservation in memory and use liveness, not reservation TTL, for
				// their lifetime.
				if rc.reservations != nil {
					ctx, cancel := rc.reservationOperationContext()
					_ = rc.reservations.DeleteReservation(ctx, rc.reservationID)
					cancel()
				}
				expiryTimer.Stop()
				rc.startKeepalive()
				if peer != nil {
					peer.startKeepalive()
				}
			}
			// Connect/PairReady 成功即活跃：续期滑动窗口。
			rc.touch(expiryTimer)
			continue
		}
		switch {
		case frame.GetPayload() != nil || frame.GetAck() != nil:
			// opaque 转发：encrypted_payload 绝不解密/解析，Ack 仅按 sequence 转发。
			if !rc.ready.Load() {
				rc.sendCloseAndShutdown(2, "relay data pairing is not ready")
				return
			}
			if !rc.forward(frame) {
				rc.sendCloseAndShutdown(2, "relay peer not ready")
				return
			}
			// 数据帧即活跃证据：续期滑动窗口，否则长会话会在 lifetime+grace 后被强关。
			rc.touch(expiryTimer)
		case frame.GetClose() != nil:
			// 正常关闭：把 Close 帧转发给对端，然后双向关闭（write goroutine 会先
			// drain 对端的 outbound 再关 socket，保证 Close 帧到达对端）。
			if other := rc.peerConn(); other != nil {
				_ = other.enqueueFrame(frame)
			}
			rc.close()
			if other := rc.peerConn(); other != nil {
				other.close()
			}
			return
		default:
			rc.sendCloseAndShutdown(2, "unexpected relay data frame")
			return
		}
	}
}

// startKeepalive begins only after both endpoints have received their queued
// PairReady frames.  It never writes to the socket directly; the existing
// outbound writer remains the sole WebSocket writer.
func (rc *relayDataConn) startKeepalive() {
	if rc.isTerminal() || !rc.paired.Load() {
		return
	}
	go func() {
		// Check at the pong deadline so a missed response closes 15s after the
		// ping that elicited it, rather than waiting for the next 30s ping tick.
		ticker := time.NewTicker(relayDataPongTimeout)
		defer ticker.Stop()
		var lastPing time.Time
		for {
			select {
			case <-rc.done:
				return
			case <-ticker.C:
				var stop bool
				lastPing, stop = rc.keepaliveTick(time.Now(), lastPing)
				if stop {
					return
				}
			}
		}
	}()
}

// keepaliveTick owns the deterministic liveness decision for one timer tick.
// The goroutine only supplies time and stops when requested; all Ping/Pong
// ordering and close policy stays independently testable here.
func (rc *relayDataConn) keepaliveTick(now, lastPing time.Time) (time.Time, bool) {
	if rc.isTerminal() {
		return lastPing, true
	}
	if !lastPing.IsZero() && now.Sub(lastPing) >= relayDataPongTimeout {
		lastPong := time.Unix(0, rc.lastPong.Load())
		if !lastPong.After(lastPing) {
			rc.sendCloseAndShutdown(2, "relay data pong timeout")
			return lastPing, true
		}
	}
	if !lastPing.IsZero() && now.Sub(lastPing) < relayDataPingInterval {
		return lastPing, false
	}
	if !rc.enqueue(relayDataOutboundFrame{
		messageType: websocket.PingMessage,
		data:        []byte(relayDataKeepalivePing),
	}) {
		rc.close()
		return lastPing, true
	}
	return now, false
}

// touch 在每次成功的数据面帧后续期滑动窗口：(a) 本地到期定时器重置到
// now+lifetime+grace；(b) 尽力续期共享存储里 reservation 的 TTL（失败静默——数据面
// 连接仍由本地定时器兜底关闭）。Stop 返回 false 表示定时器已触发（回调正在运行）、
// 连接正在关闭，此时不再续期。仅 read goroutine 调用 Stop/Reset，避免与回调并发。
func (rc *relayDataConn) touch(expiryTimer *time.Timer) {
	if rc.isTerminal() || rc.paired.Load() {
		return
	}
	if !expiryTimer.Stop() {
		return
	}
	ttl := rc.refreshTTL()
	expiryTimer.Reset(ttl)
	if rc.reservations == nil {
		return
	}
	rctx, rcancel := rc.reservationOperationContext()
	_, _ = rc.reservations.RenewReservation(rctx, rc.reservationID, ttl)
	rcancel()
}

func (rc *relayDataConn) reservationOperationContext() (context.Context, context.CancelFunc) {
	parent := rc.lifecycleCtx
	if parent == nil {
		parent = context.Background()
	}
	return context.WithTimeout(parent, presenceLeaseTimeout)
}

// refreshTTL 返回滑动窗口的存活时长：创建时夹取的 LifetimeS + grace。旧格式条目
// （LifetimeS==0，例如直接构造/升级前创建的 reservation）用 nominal 到期前剩余时间 +
// grace，保证窗口不早于原始硬到期时刻收窄。
func (rc *relayDataConn) refreshTTL() time.Duration {
	if rc.res.LifetimeS > 0 {
		return time.Duration(rc.res.LifetimeS)*time.Second + rc.grace
	}
	remaining := time.Until(time.UnixMilli(rc.res.ExpiresAtMs))
	if remaining < 0 {
		remaining = 0
	}
	return remaining + rc.grace
}

// acceptConnect 校验首帧 RelayDataConnect，并根据 token 固定端点角色。
func (rc *relayDataConn) acceptConnect(connect *v2.RelayDataConnect) (relayDataRole, bool) {
	if connect.ReservationId != rc.reservationID {
		return 0, false
	}
	var expected []byte
	switch rc.role {
	case relayDataRoleInitiator:
		if rc.deviceID != rc.res.InitiatorDeviceID {
			return 0, false
		}
		expected = rc.res.InitiatorToken
	case relayDataRoleResponder:
		if rc.deviceID != rc.res.ResponderDeviceID {
			return 0, false
		}
		expected = rc.res.ResponderToken
	default:
		return 0, false
	}
	if len(expected) == 0 || !hmac.Equal(connect.LocalToken, expected) {
		return 0, false
	}
	return rc.role, true
}

// forward 把一帧 RelayDataFrame 编码后投递给对端端点。返回 false 表示对端未连接或
// 编码/投递失败。
func (rc *relayDataConn) forward(frame *v2.RelayDataFrame) bool {
	if rc.registry == nil || rc.isTerminal() || frame == nil || (frame.GetPayload() == nil && frame.GetAck() == nil) {
		return false
	}
	outbound, ok := encodeRelayDataOutboundFrame(frame)
	if !ok {
		return false
	}
	return rc.registry.forwardEndpoint(rc, outbound)
}

func (rc *relayDataConn) enqueuePairReadyPing(decision *relayDataPairReadyDecision) bool {
	return rc.enqueue(relayDataOutboundFrame{
		messageType: websocket.PingMessage,
		data:        []byte(relayDataPairReadyPing + rc.reservationID),
		pairReady:   decision,
	})
}

// enqueueFrame 编码并投递一帧到本连接的 outbound。
func (rc *relayDataConn) enqueueFrame(frame *v2.RelayDataFrame) bool {
	outbound, ok := encodeRelayDataOutboundFrame(frame)
	if !ok {
		return false
	}
	return rc.enqueue(outbound)
}

// encodeRelayDataOutboundFrame performs protobuf marshaling and the potentially
// large frame allocation before a caller enters any registry critical section.
func encodeRelayDataOutboundFrame(frame *v2.RelayDataFrame) (relayDataOutboundFrame, bool) {
	data, err := v2.EncodeDataFrame(frame)
	if err != nil {
		return relayDataOutboundFrame{}, false
	}
	return relayDataOutboundFrame{
		messageType:          websocket.BinaryMessage,
		data:                 data,
		allowedAfterTerminal: frame.GetClose() != nil,
	}, true
}

// sendCloseAndShutdown 向本端投递 RelayDataClose 并关闭本端（write goroutine 冲刷后
// 关 socket，随后对端 read 因 socket 关闭而退出并自行关闭）。
func (rc *relayDataConn) sendCloseAndShutdown(reason uint32, detail string) {
	_ = rc.enqueueFrame(&v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayDataFrame_Close{Close: &v2.RelayDataClose{Reason: reason, Detail: detail}},
	})
	rc.close()
}

// close 幂等关闭 done 通道（不直接关 socket——socket 由 write goroutine 在 drain 后
// 关闭，保证待发帧不丢失）。
func (rc *relayDataConn) close() {
	rc.markTerminal()
	rc.once.Do(func() {
		close(rc.done)
	})
}

// markTerminal is called under registry.mutex for authorization/lifecycle
// invalidation and may also be called by local pump failures. Once set, the
// endpoint can never be admitted, paired, or used for business forwarding
// again. A queued RelayDataClose is the only frame allowed to survive it.
func (rc *relayDataConn) markTerminal() {
	rc.terminal.Store(true)
	rc.admissionActive.Store(false)
	rc.ready.Store(false)
	rc.paired.Store(false)
	rc.pairReadySent.Store(false)
}

func (rc *relayDataConn) isTerminal() bool {
	if rc == nil || rc.terminal.Load() {
		return true
	}
	select {
	case <-rc.done:
		return true
	default:
		return false
	}
}

// waitForWriteQuiescence makes lifecycle methods return only after a business
// frame whose socket write began before terminalization has completed. Every
// later queued business frame is discarded by writeOutbound.
func (rc *relayDataConn) waitForWriteQuiescence() {
	rc.writeGate.Lock()
	rc.writeGate.Unlock()
}

// forceSocketClose is the bounded-shutdown fallback after the graceful drain
// window. Closing the transport interrupts an in-flight WebSocket read/write;
// the registry lifecycle context independently interrupts lease-store I/O.
func (rc *relayDataConn) forceSocketClose() {
	rc.close()
	if rc.socket != nil {
		_ = rc.socket.Close()
	}
}

// write 从 outbound 写帧。收到 done 后先 drain 剩余帧（如 RelayDataClose）再关 socket，
// 保证关闭语义的帧能到达对端。
func (rc *relayDataConn) write() {
	defer func() {
		if rc.socket != nil {
			_ = rc.socket.Close()
		}
		close(rc.writeDone)
	}()
	if !rc.waitForActivation() {
		return
	}
	for {
		select {
		case <-rc.done:
			rc.drainOutbound()
			return
		case frame := <-rc.outbound:
			if !rc.writeOutbound(frame, relayDataWriteTimeout) {
				return
			}
		}
	}
}

func (rc *relayDataConn) waitForActivation() bool {
	if rc.activation == nil {
		return true
	}
	select {
	case <-rc.activation:
		return rc.admissionActive.Load()
	case <-rc.done:
		return false
	}
}

// drainOutbound 在 done 之后把仍在 outbound 里的帧尽力写完（非阻塞 select 读空）。
func (rc *relayDataConn) drainOutbound() {
	deadline := time.Now().Add(relayDataDrainTimeout)
	for {
		select {
		case frame := <-rc.outbound:
			remaining := time.Until(deadline)
			if remaining <= 0 {
				return
			}
			if remaining > time.Second {
				remaining = time.Second
			}
			if !rc.writeOutbound(frame, remaining) {
				return
			}
		default:
			return
		}
	}
}

// enqueue owns the non-blocking channel handoff; relayDataFlowBudget owns all
// backlog accounting and rolls back a reservation when the channel race loses.
func (rc *relayDataConn) writeOutbound(frame relayDataOutboundFrame, timeout time.Duration) bool {
	rc.flow.releaseOutbound(len(frame.data))
	if rc.isTerminal() && !frame.allowedAfterTerminal {
		return true
	}
	if frame.pairReady != nil && !frame.pairReady.wait() {
		return true
	}
	rc.writeGate.Lock()
	defer rc.writeGate.Unlock()
	if rc.isTerminal() && !frame.allowedAfterTerminal {
		return true
	}
	_ = rc.socket.SetWriteDeadline(time.Now().Add(timeout))
	if err := rc.socket.WriteMessage(frame.messageType, frame.data); err != nil {
		return false
	}
	if frame.pairReady != nil {
		rc.pairReadySent.Store(true)
	}
	return true
}

func (rc *relayDataConn) enqueue(frame relayDataOutboundFrame) bool {
	select {
	case <-rc.done:
		return false
	default:
	}
	if rc.terminal.Load() && !frame.allowedAfterTerminal {
		return false
	}
	if !rc.flow.reserveOutbound(len(frame.data)) {
		return false
	}
	select {
	case rc.outbound <- frame:
		return true
	default:
		rc.flow.releaseOutbound(len(frame.data))
		return false
	}
}
