package relay

import (
	"context"
	"hash/fnv"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

type outboundFrame struct {
	messageType int
	data        []byte
}

type peer struct {
	deviceID     string
	connectionID string
	socket       *websocket.Conn
	outbound     chan outboundFrame
	done         chan struct{}
	once         sync.Once
	// writeMutex 串行化对 socket 的写：正常路径只有 hub.write 写，但 /v2/control 的
	// 协议违规路径需要先同步冲刷一帧 ProtocolError 再关连接，两者不能并发写 WebSocket。
	writeMutex         sync.Mutex
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
	// lastHeartbeat 是服务端最后一次收到该连接 heartbeat 帧的时间（服务端心跳监视器
	// monitorHeartbeats 以此判定僵尸）。区别于 lastSeen（任何帧都更新），它只被
	// heartbeat 帧刷新，与 presence 租约的续期语义一致。
	lastHeartbeat time.Time
	// relayHost 是 /v2/control 升级请求的 Host 头，用于构造自包含的
	// relay_data_endpoint（wss://<host>/v2/relay/<reservation_id>）。
	relayHost string
	// lastResolveTarget 是 v2 控制面最近一次 ResolvePeerRequest 的目标设备；由于冻结
	// 契约的 ConnectivityOffer 不携带 target_device_id，服务端据它决定 offer 转发到
	// 哪条 peer（设计 §14：A Resolve B → ConnectivityOffer(A→B)）。stateMutex 保护。
	lastResolveTarget string
}

// 推送发现控制面的帧类型（v2 控制面由 broadcastPeerHintV2 转成 protobuf hint）。
const (
	// framePeerOnline 在设备首次发布 discovery 后广播：表示该设备上线。
	framePeerOnline = "peer_online"
	// framePeerUpdated 在设备 discovery revision 变化时广播：表示该设备的 discovery 已更新。
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
	// CreateReservation 原子存储一条 relay-data reservation（设计 §25），TTL 到
	// expires_at_ms。
	CreateReservation(ctx context.Context, r Reservation) error
	// GetReservation 返回 reservation；不存在或已过期返回 (zero, false, nil)。
	GetReservation(ctx context.Context, reservationID string) (Reservation, bool, error)
	// DeleteReservation 删除 reservation（双方关闭后清理）。
	DeleteReservation(ctx context.Context, reservationID string) error
	Publish(ctx context.Context, event RelayEvent) error
}

type hub struct {
	config      Config
	mutex       sync.Mutex
	peers       map[string]*peer
	presence    presenceStore
	instanceID  string
	presenceTTL time.Duration
	// v2Attempts 是 v2 异步 attempt（attempt_id → 发起设备）的路由注册表：服务端在
	// 转发 ConnectivityOffer 时登记，ConnectivityAnswer/ProtocolError 据此回路由到
	// 发起方。条目带过期时间，由 hub.prune 惰性清理。
	v2Attempts map[string]v2Attempt
	admission  [admissionStripeCount]sync.Mutex
	stop       chan struct{}
	closeOnce  sync.Once
	waitGroup  sync.WaitGroup
	closed     bool
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
		config:      config,
		peers:       map[string]*peer{},
		v2Attempts:  map[string]v2Attempt{},
		instanceID:  config.InstanceID,
		presenceTTL: config.PresenceTTL,
		stop:        make(chan struct{}),
	}
	h.waitGroup.Add(1)
	go func() {
		defer h.waitGroup.Done()
		h.prune()
	}()
	h.waitGroup.Add(1)
	go func() {
		defer h.waitGroup.Done()
		h.monitorHeartbeats()
	}()
	return h
}

// monitorHeartbeats 是服务端心跳租约定时器（在客户端驱动的续期之外）：每
// ServerHeartbeatInterval 扫描一次本地 peer，超过
// ServerHeartbeatMisses×ServerHeartbeatInterval 未收到 heartbeat 帧的连接视为僵尸，
// 定向关闭。关闭会解除 read goroutine 对 socket 的阻塞，其 deferred remove() 随后
// 释放 presence/discovery 租约并广播 peer_offline——与 sweeper 收敛路径一致。
func (h *hub) monitorHeartbeats() {
	interval := h.config.ServerHeartbeatInterval
	if interval <= 0 {
		interval = defaultServerHeartbeatInterval
	}
	misses := h.config.ServerHeartbeatMisses
	if misses <= 0 {
		misses = defaultServerHeartbeatMisses
	}
	threshold := time.Duration(misses) * interval
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-h.stop:
			return
		case now := <-ticker.C:
			h.mutex.Lock()
			stale := make([]*peer, 0)
			for _, p := range h.peers {
				if now.Sub(p.lastHeartbeat) > threshold {
					stale = append(stale, p)
				}
			}
			h.mutex.Unlock()
			for _, p := range stale {
				closePeer(p)
			}
		}
	}
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
	// 服务端心跳监视器从连接建立开始计时，给新连接最多 2 个心跳周期（40s）发送首个
	// heartbeat；尚未上传首个 heartbeat 的连接不会被误杀。
	peer.lastHeartbeat = time.Now()
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
		// revision（>0）+ owner 一致（明确版 §13 收紧版）。连接建立后、设备真正
		// 发布 discovery 之前，该设备不被 resolve 视为可连接——§8「上传 discovery
		// 后才广播为 online」由此自然成立。discovery 只在设备发布 DiscoveryPublish
		// 时由 publishDiscoveryV2 写入（CAS 要求当前 presence owner）。
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
			h.broadcastPeerEvent(framePeerOffline, peer.deviceID, Discovery{})
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
			h.broadcastPeerEvent(framePeerOffline, deviceID, Discovery{})
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
			peer.writeMutex.Lock()
			_ = peer.socket.SetWriteDeadline(time.Now().Add(15 * time.Second))
			err := peer.socket.WriteMessage(frame.messageType, frame.data)
			peer.writeMutex.Unlock()
			if err != nil {
				return
			}
		}
	}
}

func (h *hub) read(peer *peer) {
	defer h.waitGroup.Done()
	defer h.remove(peer)
	// /v2/control 每帧最大为冻结契约的 MAX_RELAY_FRAME_BYTES（4+512KiB）。
	peer.socket.SetReadLimit(v2.MAX_RELAY_FRAME_BYTES)
	for {
		kind, data, err := peer.socket.ReadMessage()
		if err != nil {
			return
		}
		h.mutex.Lock()
		peer.lastSeen = time.Now()
		h.mutex.Unlock()
		// /v2/control 只接受 protobuf 二进制控制帧：一个 [4B BE 长度][RelayFrame]。
		// Text 帧或 RelayDataFrame 都是协议违规 → 关闭连接。违规路径用同步写冲刷
		// ProtocolError 再关闭（避免 closePeer 抢先丢帧）。
		if kind != websocket.BinaryMessage {
			h.sendV2ProtocolErrorSync(peer, 0, v2.ErrorCode_ERROR_CODE_PROTOCOL, "only binary control frames are allowed on /v2/control")
			return
		}
		if !h.routeControlV2(peer, data) {
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
			for id, attempt := range h.v2Attempts {
				if now.After(attempt.expiresAt) {
					delete(h.v2Attempts, id)
				}
			}
			h.mutex.Unlock()
		}
	}
}
