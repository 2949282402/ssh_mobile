package relay

import (
	"context"
	"encoding/hex"
	"hash/fnv"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type outboundFrame struct {
	messageType int
	data        []byte
}

type peer struct {
	deviceID           string
	connectionID       string
	socket             *websocket.Conn
	outbound           chan outboundFrame
	done               chan struct{}
	once               sync.Once
	stateMutex         sync.Mutex
	pendingFrames      int
	pendingBytes       int64
	maxPendingFrames   int
	maxPendingBytes    int64
	maxFramesPerSecond int
	maxBytesPerSecond  int64
	windowStartedAt    time.Time
	framesInWindow     int
	bytesInWindow      int64
	lastSeen           time.Time
}

type session struct {
	sender    string
	receiver  string
	expiresAt time.Time
	accepted  bool
	completed bool
}

type controlFrame struct {
	Type            string        `json:"type"`
	SessionID       string        `json:"session_id,omitempty"`
	TargetID        string        `json:"target_id,omitempty"`
	SenderID        string        `json:"sender_id,omitempty"`
	DeviceID        string        `json:"device_id,omitempty"`
	Payload         string        `json:"payload,omitempty"`
	Timestamp       int64         `json:"timestamp,omitempty"`
	ProtocolVersion uint32        `json:"protocol_version,omitempty"`
	Online          *bool         `json:"online,omitempty"`
	Generation      uint64        `json:"generation,omitempty"`
	Peers           []peerSummary `json:"peers,omitempty"`
	Capabilities    []string      `json:"capabilities,omitempty"`
	Candidates      []string      `json:"candidates,omitempty"`
}

// peerSummary 是 presence_snapshot 的条目：在线设备的 device_id 与其当前
// discovery generation。客户端据此重建本地设备列表并决定是否拉取最新 discovery。
type peerSummary struct {
	DeviceID   string `json:"device_id"`
	Generation uint64 `json:"generation"`
}

// 推送发现控制面的帧类型（均经 peer.enqueue 以 TextMessage 下发，同 ready 帧）。
const (
	// framePresenceSnapshot 在设备首次上传 discovery_update 后回发：包含当前全部
	// 在线设备的 {device_id, generation} 快照，作为该设备本地设备列表基线。
	framePresenceSnapshot = "presence_snapshot"
	// framePeerOnline 在设备首次上传 discovery_update 后广播：表示该设备上线。
	framePeerOnline = "peer_online"
	// framePeerUpdated 在设备 generation 变化时广播：表示该设备的 discovery 已更新。
	framePeerUpdated = "peer_updated"
	// framePeerOffline 在设备离线（sweeper 清理僵尸连接）时广播。
	framePeerOffline = "peer_offline"
)

// presenceStore reports device connection state to the shared presence layer as
// a per-connection lease. Every take/renew/release carries the owning
// connection's ConnectionID so a superseded connection can never erase or renew
// a newer one. Publish broadcasts a cross-instance lifecycle event (used for
// the targeted connection.replaced disconnect).
//
// Discovery 与 presence 同生命周期（TTL 相同、心跳同时续期、断开同时释放），
// 所以 hub 侧的取/续/释放走同一契约；GetPresence/GetDiscovery 供 lookup 用
// Redis 作为唯一事实来源（明确版 §13）。
type presenceStore interface {
	TakePresence(ctx context.Context, deviceID, connID string, p Presence, ttl time.Duration) (Presence, bool, error)
	RenewPresence(ctx context.Context, deviceID, connID string, p Presence, ttl time.Duration) (bool, error)
	ReleasePresence(ctx context.Context, deviceID, connID string) (bool, error)
	GetPresence(ctx context.Context, deviceID string) (Presence, bool, error)
	GetDiscovery(ctx context.Context, deviceID string) (Discovery, bool, error)
	TakeDiscovery(ctx context.Context, deviceID, connID string, d Discovery, ttl time.Duration) error
	RenewDiscovery(ctx context.Context, deviceID, connID string, ttl time.Duration) (bool, error)
	ReleaseDiscovery(ctx context.Context, deviceID, connID string) (bool, error)
	// ListOnlinePeers 返回 presence 与 discovery 均有效的设备（明确版 §13），
	// presence_snapshot 构建与 sweeper 判活复用同一在线判定。
	ListOnlinePeers(ctx context.Context) (map[string]Discovery, error)
	Publish(ctx context.Context, event RelayEvent) error
}

type hub struct {
	config           Config
	mutex            sync.Mutex
	peers            map[string]*peer
	transferSessions map[string]session
	presence         presenceStore
	instanceID       string
	presenceTTL      time.Duration
	admission        [admissionStripeCount]sync.Mutex
	stop             chan struct{}
	closeOnce        sync.Once
	waitGroup        sync.WaitGroup
	closed           bool
}

// admissionStripeCount is the number of per-device admission lock stripes.
// Connections for the same device are serialized on the same stripe so their
// Redis lease claim (TakePresence) lands in connection-establishment order — a
// stale, slower claim can never overwrite a newer one and kick the valid
// connection. Different devices rarely collide on a stripe and only wait briefly.
const admissionStripeCount = 128

// deviceLockStripe maps a deviceID to a lock stripe via fnv-1a, so per-device
// lock arrays (the hub's admission stripes and the Server's device stripes)
// stay balanced and same-device operations always hit the same stripe.
func deviceLockStripe(deviceID string) uint64 {
	hasher := fnv.New64a()
	_, _ = hasher.Write([]byte(deviceID))
	return hasher.Sum64()
}

// lockAdmission serializes connection admission for deviceID (via a hash stripe)
// so the lease claim for a newer connection runs after any in-flight claim for
// the same device has fully landed.
func (h *hub) lockAdmission(deviceID string) func() {
	stripe := deviceLockStripe(deviceID) % admissionStripeCount
	h.admission[stripe].Lock()
	return h.admission[stripe].Unlock
}

func newHub(config Config) *hub {
	config = withConfigDefaults(config)
	h := &hub{
		config:           config,
		peers:            map[string]*peer{},
		transferSessions: map[string]session{},
		instanceID:       config.InstanceID,
		presenceTTL:      config.PresenceTTL,
		stop:             make(chan struct{}),
	}
	h.waitGroup.Add(1)
	go func() {
		defer h.waitGroup.Done()
		h.prune()
	}()
	return h
}

// presenceFor builds the shared presence value for a connected peer. The
// ConnectionID is this connection's lease-ownership identity; every
// take/renew/release for the device must carry it. Writing it is mandatory: an
// empty owner in the stored lease would make the peer's first heartbeat renew
// fail (empty != real connID) and self-close every connection.
func (h *hub) presenceFor(peer *peer) Presence {
	value := Presence{InstanceID: h.instanceID, ConnectionID: peer.connectionID, LastSeen: time.Now()}
	if peer.socket != nil && peer.socket.RemoteAddr() != nil {
		value.RemoteAddr = peer.socket.RemoteAddr().String()
	}
	return value
}

// hubCloseTimeout bounds the peer/pruner convergence wait during close. Peer
// sockets are closed before waiting, so this normally returns immediately; the
// bound exists so a wedged goroutine cannot stall the whole shutdown path
// beyond the Compose stop_grace_period.
const hubCloseTimeout = 5 * time.Second

// presenceLeaseTimeout bounds each heartbeat's presence lease I/O so a slow or
// hung Redis cannot stall the WebSocket read goroutine (which also routes data
// frames). On timeout the ownership is unknown and the connection is kept
// (fail-open); the next heartbeat retries.
const presenceLeaseTimeout = 500 * time.Millisecond

func (h *hub) close() {
	h.closeOnce.Do(func() {
		h.mutex.Lock()
		h.closed = true
		close(h.stop)
		peers := make([]*peer, 0, len(h.peers))
		for _, value := range h.peers {
			peers = append(peers, value)
		}
		h.peers = map[string]*peer{}
		h.transferSessions = map[string]session{}
		h.mutex.Unlock()
		for _, peer := range peers {
			closePeer(peer)
		}
		if h.presence != nil && len(peers) > 0 {
			// Bound the presence sweep: a wedged Redis must not blow the
			// shutdown budget (one blocking release per peer), so run all
			// releases concurrently under a 2s context deadline. Each release is
			// CAS'd to the peer's own connection, so a lease already taken over
			// by another instance is left untouched.
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			var sweep sync.WaitGroup
			for _, p := range peers {
				sweep.Add(1)
				go func(peer *peer) {
					defer sweep.Done()
					_, _ = h.presence.ReleasePresence(ctx, peer.deviceID, peer.connectionID)
					_, _ = h.presence.ReleaseDiscovery(ctx, peer.deviceID, peer.connectionID)
				}(p)
			}
			sweep.Wait()
			cancel()
		}
		done := make(chan struct{})
		go func() {
			h.waitGroup.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(hubCloseTimeout):
			// Sockets were already closed above; proceed even if a goroutine
			// is stuck, keeping the process exit path bounded.
		}
	})
}
func (h *hub) add(peer *peer) bool {
	peer.lastSeen = time.Now()
	// Serialize admission per device so the Redis lease claim lands in
	// connection-establishment order: a newer connection's TakePresence runs only
	// after any in-flight claim for the same device completed, so a stale claim
	// can never overwrite it and kick the valid connection.
	unlockAdmission := h.lockAdmission(peer.deviceID)
	defer unlockAdmission()

	h.mutex.Lock()
	if h.closed {
		h.mutex.Unlock()
		return false
	}
	previous := h.peers[peer.deviceID]
	if previous == nil && len(h.peers) >= h.config.MaxConnections {
		h.mutex.Unlock()
		return false
	}
	h.peers[peer.deviceID] = peer
	h.mutex.Unlock()
	if previous != nil {
		closePeer(previous)
	}
	// Take the presence lease before starting the read/write goroutines: if the
	// socket fails immediately, remove() releases it after this point, so no
	// phantom online entry can be left behind by a delayed TakePresence. The new
	// connection takes over any existing lease (newest connect wins).
	leaseTaken := false
	if h.presence != nil {
		old, replaced, err := h.presence.TakePresence(context.Background(), peer.deviceID, peer.connectionID, h.presenceFor(peer), h.presenceTTL)
		if err == nil {
			leaseTaken = true
		}
		if err == nil && replaced && old.ConnectionID != "" && old.InstanceID != "" && old.InstanceID != h.instanceID {
			// Cross-instance takeover: tell the superseded connection's instance
			// to close it now, so the dual-connection window collapses
			// immediately instead of waiting up to a heartbeat cycle. A lost
			// event is covered by the heartbeat CAS renew fallback.
			_ = h.presence.Publish(context.Background(), RelayEvent{
				Type:            eventConnectionReplaced,
				DeviceID:        peer.deviceID,
				OldInstanceID:   old.InstanceID,
				OldConnectionID: old.ConnectionID,
				NewConnectionID: peer.connectionID,
				Time:            time.Now().UnixMilli(),
			})
		}
		// 不再写占位 discovery：在线判定要求 presence 与 discovery 双有效 + 真实
		// generation（>0）+ owner 一致（明确版 §13 收紧版）。连接建立后、设备真正
		// 上传 discovery_update 之前，该设备不被 lookup/snapshot 视为可连接——§8
		// 「上传 discovery 后才广播为 online」由此自然成立。discovery 只在设备上传
		// discovery_update 时由 handleDiscoveryUpdate 写入（CAS 要求当前 presence
		// owner）。
	}
	// Atomically re-check currency/closed and register the worker goroutines in
	// the same h.mutex critical section that close() uses, so shutdown cannot
	// race: if close() won the mutex first, isCurrent is false and no workers are
	// registered (close()'s Wait() has nothing to wait for); if this wins first,
	// the Add(2) happens-before close()'s Wait(), which must then see both
	// workers' Done. The peer may also have been kicked (revoke/disconnect)
	// while the lease claim was in flight.
	h.mutex.Lock()
	isCurrent := !h.closed && h.peers[peer.deviceID] == peer
	if isCurrent {
		h.waitGroup.Add(2)
	}
	h.mutex.Unlock()
	if !isCurrent {
		// The lease was just taken but this admission was rejected (the hub closed
		// or the peer was kicked while the claim was in flight): release the lease
		// we wrote so a rejected connection cannot leave a phantom "online" entry.
		// The release is CAS'd to this connection, so if a newer connection has
		// since taken the lease over it is left untouched — the same lifecycle
		// rule the heartbeat path applies after a post-renew currency re-check.
		if leaseTaken && h.presence != nil {
			_, _ = h.presence.ReleasePresence(context.Background(), peer.deviceID, peer.connectionID)
		}
		closePeer(peer)
		return false
	}
	go h.write(peer)
	go h.read(peer)
	return true
}

// disconnectConnection closes only the connection whose connectionID matches — a
// directed disconnect for a connection.replaced event. A delayed event must not
// kick a newer connection that has since taken the device, so the current peer's
// connectionID must match exactly; otherwise this is a no-op. Returns true only
// when a matching connection was actually found and closed; a no-op (the device
// was replaced or already gone) returns false so callers can avoid acting on a
// disconnect that did not happen.
func (h *hub) disconnectConnection(deviceID, connectionID string) bool {
	if connectionID == "" {
		return false
	}
	h.mutex.Lock()
	current := h.peers[deviceID]
	if current == nil || current.connectionID != connectionID {
		h.mutex.Unlock()
		return false
	}
	delete(h.peers, deviceID)
	for sessionID, s := range h.transferSessions {
		if s.sender == deviceID || s.receiver == deviceID {
			delete(h.transferSessions, sessionID)
		}
	}
	h.mutex.Unlock()
	if h.presence != nil {
		_, _ = h.presence.ReleasePresence(context.Background(), deviceID, connectionID)
		_, _ = h.presence.ReleaseDiscovery(context.Background(), deviceID, connectionID)
	}
	closePeer(current)
	return true
}

func (h *hub) remove(peer *peer) {
	h.mutex.Lock()
	// Only the current peer releases the lease: a replaced peer's read goroutine
	// may still exit after a duplicate connect, and must not erase the new
	// peer's presence. The CAS ReleasePresence additionally guards the
	// cross-instance case where a foreign connection now owns the lease.
	isCurrent := h.peers[peer.deviceID] == peer
	if isCurrent {
		delete(h.peers, peer.deviceID)
	}
	h.mutex.Unlock()
	if isCurrent && h.presence != nil {
		released, _ := h.presence.ReleasePresence(context.Background(), peer.deviceID, peer.connectionID)
		_, _ = h.presence.ReleaseDiscovery(context.Background(), peer.deviceID, peer.connectionID)
		// 仅当租约真被释放（released=true）才广播 peer_offline：若 CAS 返回 false，
		// 说明租约已被同设备的另一条连接接管（如本实例 socket 断开后设备在其它实例
		// 重连，TakePresence 已接管），设备实际仍在线上，广播 offline 会误报。
		// 被取代连接的 teardown（isCurrent==false）或 revoke/kick 路径
		// （disconnectDevice 已广播）也不在此重复。
		if released {
			h.broadcastPeerEvent(framePeerOffline, peer.deviceID, 0)
		}
	}
	closePeer(peer)
}

func closePeer(peer *peer) {
	peer.stateMutex.Lock()
	defer peer.stateMutex.Unlock()
	peer.once.Do(func() {
		close(peer.done)
		if peer.socket != nil {
			_ = peer.socket.Close()
		}
	})
}

func (h *hub) disconnectDevice(deviceID string) {
	h.mutex.Lock()
	peer := h.peers[deviceID]
	if peer != nil {
		delete(h.peers, deviceID)
	}
	for sessionID, current := range h.transferSessions {
		if current.sender == deviceID || current.receiver == deviceID {
			delete(h.transferSessions, sessionID)
		}
	}
	h.mutex.Unlock()
	if peer != nil {
		// Release only this instance's current lease (CAS): the peer's deferred
		// remove() would see isCurrent==false and never release it, so do it
		// here. If a newer connection replaced this peer or took over the lease
		// from another instance, the release is a no-op instead of wiping the
		// live presence. A device connected on another instance is released
		// there when it receives the revoke/kick event, or by reconcileRevocations.
		released := false
		if h.presence != nil {
			released, _ = h.presence.ReleasePresence(context.Background(), deviceID, peer.connectionID)
			_, _ = h.presence.ReleaseDiscovery(context.Background(), deviceID, peer.connectionID)
		}
		// 设备被整机断开（revoke/kick/对账/重新 enroll 抢占）：广播 peer_offline。
		// 关闭触发的 remove() 此时 isCurrent==false 不会重复广播。被新连接替换的
		// 定向断开走 disconnectConnection（新连接已接管，不广播 offline）。仅当租约
		// 真被释放（released=true）才广播——CAS 返回 false 说明设备已在别处重连，
		// 广播 offline 会误报仍在线的设备。
		if released {
			h.broadcastPeerEvent(framePeerOffline, deviceID, 0)
		}
		closePeer(peer)
	}
}

func (h *hub) write(peer *peer) {
	defer h.waitGroup.Done()
	defer h.remove(peer)
	for {
		select {
		case <-peer.done:
			return
		case frame := <-peer.outbound:
			peer.dequeue(frame)
			_ = peer.socket.SetWriteDeadline(time.Now().Add(15 * time.Second))
			if err := peer.socket.WriteMessage(frame.messageType, frame.data); err != nil {
				return
			}
		}
	}
}

func (h *hub) read(peer *peer) {
	defer h.waitGroup.Done()
	defer h.remove(peer)
	peer.socket.SetReadLimit(maxBinaryFrameBytes)
	for {
		kind, data, err := peer.socket.ReadMessage()
		if err != nil {
			return
		}
		h.mutex.Lock()
		peer.lastSeen = time.Now()
		h.mutex.Unlock()
		if kind == websocket.TextMessage {
			h.routeControl(peer, data)
		} else if kind == websocket.BinaryMessage {
			h.routeBinary(peer, data)
		} else {
			return
		}
	}
}

func (p *peer) enqueue(frame outboundFrame) bool {
	p.stateMutex.Lock()
	defer p.stateMutex.Unlock()
	select {
	case <-p.done:
		return false
	default:
	}
	if p.maxPendingFrames > 0 && p.pendingFrames >= p.maxPendingFrames {
		return false
	}
	frameBytes := int64(len(frame.data))
	if p.maxPendingBytes > 0 && frameBytes > p.maxPendingBytes-p.pendingBytes {
		return false
	}
	select {
	case p.outbound <- frame:
		p.pendingFrames++
		p.pendingBytes += frameBytes
		return true
	default:
		return false
	}
}

func (p *peer) dequeue(frame outboundFrame) {
	p.stateMutex.Lock()
	if p.pendingFrames > 0 {
		p.pendingFrames--
	}
	frameBytes := int64(len(frame.data))
	if frameBytes >= p.pendingBytes {
		p.pendingBytes = 0
	} else {
		p.pendingBytes -= frameBytes
	}
	p.stateMutex.Unlock()
}

func (h *hub) routeBinary(sender *peer, data []byte) {
	if !sender.allowFrame(len(data)) || len(data) < 25 || len(data) > maxBinaryFrameBytes || data[0] != 0x10 {
		return
	}
	h.mutex.Lock()
	isCurrent := h.peers[sender.deviceID] == sender
	h.mutex.Unlock()
	if !isCurrent {
		return
	}
	sessionID := hex.EncodeToString(data[1:17])
	h.mutex.Lock()
	current, ok := h.transferSessions[sessionID]
	if !ok || current.sender != sender.deviceID || !current.accepted || current.completed || time.Now().After(current.expiresAt) {
		if ok && time.Now().After(current.expiresAt) {
			delete(h.transferSessions, sessionID)
		}
		h.mutex.Unlock()
		return
	}
	current.expiresAt = time.Now().Add(h.config.SessionTTL)
	h.transferSessions[sessionID] = current
	target := h.peers[current.receiver]
	h.mutex.Unlock()
	if target == nil {
		return
	}
	copyData := append([]byte(nil), data...)
	if !target.enqueue(outboundFrame{websocket.BinaryMessage, copyData}) {
		go target.socket.Close()
	}
}

// broadcast 把 frame 推给除 exceptDeviceID 外的所有本地 peer。按 routeBinary 的
// 「锁内快照、锁外 enqueue」模式：快照在 h.mutex 下完成、enqueue 在锁外逐个执行，
// 避免长持有互斥锁阻塞 read goroutine。enqueue 失败（对端积压或已关闭）则定向关闭，
// 与现有转发路径的处置一致。推送发现帧（presence_snapshot/peer_online/peer_updated/
// peer_offline）与跨实例事件都在此聚合，供本地实例与 handleRelayEvent 复用。
func (h *hub) broadcast(exceptDeviceID string, frame outboundFrame) {
	h.mutex.Lock()
	peers := make([]*peer, 0, len(h.peers))
	for deviceID, p := range h.peers {
		if deviceID != exceptDeviceID {
			peers = append(peers, p)
		}
	}
	h.mutex.Unlock()
	for _, p := range peers {
		if !p.enqueue(frame) {
			go p.socket.Close()
		}
	}
}

func (p *peer) allowFrame(size int) bool {
	p.stateMutex.Lock()
	defer p.stateMutex.Unlock()
	now := time.Now()
	if now.Sub(p.windowStartedAt) >= time.Second {
		p.windowStartedAt = now
		p.framesInWindow = 0
		p.bytesInWindow = 0
	}
	maxFrames := p.maxFramesPerSecond
	if maxFrames <= 0 {
		maxFrames = defaultMaxFramesPerSecondPerDevice
	}
	maxBytes := p.maxBytesPerSecond
	if maxBytes <= 0 {
		maxBytes = defaultMaxBytesPerSecondPerDevice
	}
	if p.framesInWindow >= maxFrames || int64(size) > maxBytes-p.bytesInWindow {
		return false
	}
	p.framesInWindow++
	p.bytesInWindow += int64(size)
	return true
}

func (h *hub) prune() {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-h.stop:
			return
		case now := <-ticker.C:
			h.mutex.Lock()
			for id, value := range h.transferSessions {
				if now.After(value.expiresAt) {
					delete(h.transferSessions, id)
				}
			}
			h.mutex.Unlock()
		}
	}
}
