package relay

import (
	"container/heap"
	"context"
	"hash/fnv"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

type outboundFrame struct {
	messageType int
	data        []byte
}

// expiryIndex keeps one removable min-heap entry per live key. Unlike a lazy
// heap, deleting or consuming state also removes its heap node, so a later
// capacity check never has to walk an unbounded chain of stale expiries.
type expiryIndexEntry[K comparable] struct {
	key       K
	expiresAt time.Time
	index     int
}

type expiryIndexHeap[K comparable] []*expiryIndexEntry[K]

func (h expiryIndexHeap[K]) Len() int { return len(h) }

func (h expiryIndexHeap[K]) Less(i, j int) bool {
	return h[i].expiresAt.Before(h[j].expiresAt)
}

func (h expiryIndexHeap[K]) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
	h[i].index = i
	h[j].index = j
}

func (h *expiryIndexHeap[K]) Push(value any) {
	entry := value.(*expiryIndexEntry[K])
	entry.index = len(*h)
	*h = append(*h, entry)
}

func (h *expiryIndexHeap[K]) Pop() any {
	old := *h
	last := len(old) - 1
	entry := old[last]
	old[last] = nil
	entry.index = -1
	*h = old[:last]
	return entry
}

type expiryIndex[K comparable] struct {
	heap  expiryIndexHeap[K]
	byKey map[K]*expiryIndexEntry[K]
}

func (i *expiryIndex[K]) add(key K, expiresAt time.Time) bool {
	if i.byKey == nil {
		i.byKey = make(map[K]*expiryIndexEntry[K])
	}
	if _, exists := i.byKey[key]; exists {
		return false
	}
	entry := &expiryIndexEntry[K]{key: key, expiresAt: expiresAt}
	i.byKey[key] = entry
	heap.Push(&i.heap, entry)
	return true
}

func (i *expiryIndex[K]) remove(key K) bool {
	entry := i.byKey[key]
	if entry == nil {
		return false
	}
	heap.Remove(&i.heap, entry.index)
	delete(i.byKey, key)
	return true
}

func (i *expiryIndex[K]) oldestExpired(now time.Time) (K, bool) {
	if len(i.heap) > 0 && !now.Before(i.heap[0].expiresAt) {
		return i.heap[0].key, true
	}
	var zero K
	return zero, false
}

func (i *expiryIndex[K]) reset() {
	i.heap = nil
	i.byKey = make(map[K]*expiryIndexEntry[K])
}

type peer struct {
	deviceID             string
	connectionID         string
	enrollmentGeneration int64
	socket               *websocket.Conn
	outbound             chan outboundFrame
	done                 chan struct{}
	once                 sync.Once
	activation           chan struct{}
	activationOnce       sync.Once
	admissionActive      atomic.Bool
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
	mutex                   sync.Mutex
	peers                   map[string]*peer
	presence                presenceStore
	instanceID              string
	presenceTTL             time.Duration
	maxConnections          int
	serverHeartbeatInterval time.Duration
	serverHeartbeatMisses   int
	relayDataOrigin         string
	maxDiscoveryDevices     int
	// v2Attempts 是 v2 异步 attempt（attempt_id → 发起设备）的路由注册表：服务端在
	// 转发 ConnectivityOffer 时登记，ConnectivityAnswer/ProtocolError 据此回路由到
	// 发起方。条目带过期时间，由 hub.prune 惰性清理。
	v2Attempts map[string]v2Attempt
	// v2AttemptExpiries is an exact, removable expiry index. The heap and map
	// contain one entry per attempt, including while an Answer consumes routing
	// independently from the reservation fallback gate.
	v2AttemptExpiries expiryIndex[string]
	// attemptsByConnection is the reverse index for immediate disconnect and
	// replacement cleanup. Each attempt is indexed by both endpoint connection
	// IDs, so stale correlation state cannot accumulate until the minute sweep.
	attemptsByConnection map[string]map[string]struct{}
	maxV2Attempts        int
	maxV2AttemptsPerConn int
	// reservationGates independently authorize one RelayReserveRequest
	// after a ConnectivityOffer has actually been queued to its resolved target.
	// The key includes the authenticated initiator connection, so another peer
	// cannot guess an attempt_id and consume the authorization. Keeping this
	// separate from v2Attempts lets Answer/ProtocolError retain their own
	// one-shot return-routing lifetime.
	reservationGates relayReservationGateRegistry
	// The frozen ConnectivityOffer has no target field.  Keep a one-shot
	// Resolve -> Offer ticket per authenticated control connection instead.
	coordinationTargets map[string]coordinationTarget
	// discoveryLimiter is a separate device-scoped admission collaborator: it
	// protects fleet-wide hint fan-out without coupling token accounting to the
	// peer-routing mutex.
	discoveryLimiter *discoveryFanoutLimiter
	// pendingAdmissions contains authenticated control sockets while their
	// authoritative presence claim is in flight. They count toward capacity but
	// are never routable through peers until the lease succeeds.
	pendingAdmissions map[string]*peer
	admission         [admissionStripeCount]deviceStripeLock
	stop              chan struct{}
	closeOnce         sync.Once
	waitGroup         sync.WaitGroup
	closed            bool
	logger            *slog.Logger
}

type coordinationTarget struct {
	deviceID  string
	expiresAt time.Time
}

// admissionStripeCount is the number of per-device admission lock stripes.
// Connections for the same device are serialized on the same stripe so their
// Redis lease claim (TakePresence) lands in connection-establishment order — a
// stale, slower claim can never overwrite a newer one and kick the valid
// connection. Different devices rarely collide on a stripe and only wait briefly.
const admissionStripeCount = 128

const (
	defaultMaxV2Attempts        = 65536
	defaultMaxV2AttemptsPerConn = 64
	maxV2StatePrunesPerSweep    = 256
)

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
	unlock, _ := h.lockAdmissionContext(context.Background(), deviceID)
	return unlock
}

// lockAdmissionContext keeps queueing on the per-device Hub stripe inside the
// caller's total admission budget. A plain mutex here would let a request wait
// past its WebSocket security deadline before it even starts the presence
// claim, especially when unrelated device IDs collide on the same stripe.
func (h *hub) lockAdmissionContext(ctx context.Context, deviceID string) (func(), bool) {
	stripe := deviceLockStripe(deviceID) % admissionStripeCount
	return h.admission[stripe].acquire(ctx)
}

func newHub(config Config) *hub {
	config = withConfigDefaults(config)
	h := &hub{
		peers:                   map[string]*peer{},
		v2Attempts:              map[string]v2Attempt{},
		attemptsByConnection:    map[string]map[string]struct{}{},
		maxV2Attempts:           defaultMaxV2Attempts,
		maxV2AttemptsPerConn:    defaultMaxV2AttemptsPerConn,
		reservationGates:        newRelayReservationGateRegistry(0, 0),
		coordinationTargets:     map[string]coordinationTarget{},
		discoveryLimiter:        newDiscoveryFanoutLimiter(config.MaxEnrolledDevices),
		pendingAdmissions:       map[string]*peer{},
		instanceID:              config.InstanceID,
		presenceTTL:             config.PresenceTTL,
		maxConnections:          config.MaxConnections,
		serverHeartbeatInterval: config.ServerHeartbeatInterval,
		serverHeartbeatMisses:   config.ServerHeartbeatMisses,
		relayDataOrigin:         relayDataEndpointOrigin(config),
		maxDiscoveryDevices:     config.MaxEnrolledDevices,
		logger:                  slog.Default(),
		stop:                    make(chan struct{}),
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

func (h *hub) removeV2AttemptLocked(attemptID string) {
	attempt, present := h.v2Attempts[attemptID]
	if present {
		delete(h.v2Attempts, attemptID)
		for _, connectionID := range []string{attempt.initiatorConnectionID, attempt.targetConnectionID} {
			refs := h.attemptsByConnection[connectionID]
			delete(refs, attemptID)
			if len(refs) == 0 {
				delete(h.attemptsByConnection, connectionID)
			}
		}
	}
	h.v2AttemptExpiries.remove(attemptID)
}

func (h *hub) pruneExpiredV2AttemptsLocked(now time.Time, limit int) int {
	pruned := 0
	for pruned < limit {
		attemptID, expired := h.v2AttemptExpiries.oldestExpired(now)
		if !expired {
			break
		}
		h.removeV2AttemptLocked(attemptID)
		pruned++
	}
	return pruned
}

func (h *hub) addV2AttemptLocked(attemptID string, attempt v2Attempt, now time.Time) bool {
	if attemptID == "" || !now.Before(attempt.expiresAt) {
		return false
	}
	if h.v2Attempts == nil {
		h.v2Attempts = make(map[string]v2Attempt)
	}
	if h.attemptsByConnection == nil {
		h.attemptsByConnection = make(map[string]map[string]struct{})
	}
	globalLimit := h.maxV2Attempts
	if globalLimit <= 0 {
		globalLimit = defaultMaxV2Attempts
	}
	perConnectionLimit := h.maxV2AttemptsPerConn
	if perConnectionLimit <= 0 {
		perConnectionLimit = defaultMaxV2AttemptsPerConn
	}
	if _, exists := h.v2Attempts[attemptID]; exists {
		return false
	}
	if len(h.v2Attempts) >= globalLimit {
		// The exact heap makes capacity recovery one directed O(log n) removal.
		// Do not drain all expired attempts on this Offer hot path.
		h.pruneExpiredV2AttemptsLocked(now, 1)
		if len(h.v2Attempts) >= globalLimit {
			return false
		}
	}
	connectionIDs := []string{attempt.initiatorConnectionID}
	if attempt.targetConnectionID != attempt.initiatorConnectionID {
		connectionIDs = append(connectionIDs, attempt.targetConnectionID)
	}
	for _, connectionID := range connectionIDs {
		if connectionID == "" {
			continue
		}
		if len(h.attemptsByConnection[connectionID]) >= perConnectionLimit &&
			!h.releaseExpiredV2AttemptSlotForConnectionLocked(connectionID, now, perConnectionLimit) {
			return false
		}
	}
	h.v2Attempts[attemptID] = attempt
	if !h.v2AttemptExpiries.add(attemptID, attempt.expiresAt) {
		delete(h.v2Attempts, attemptID)
		return false
	}
	for _, connectionID := range connectionIDs {
		if connectionID == "" {
			continue
		}
		refs := h.attemptsByConnection[connectionID]
		if refs == nil {
			refs = make(map[string]struct{})
			h.attemptsByConnection[connectionID] = refs
		}
		refs[attemptID] = struct{}{}
	}
	return true
}

// releaseExpiredV2AttemptSlotForConnectionLocked checks only the connection's
// reverse-index bucket. That bucket is capped at maxChecks (64 in production),
// so per-connection capacity recovery is independent of global attempt count.
func (h *hub) releaseExpiredV2AttemptSlotForConnectionLocked(connectionID string, now time.Time, maxChecks int) bool {
	refs := h.attemptsByConnection[connectionID]
	checked := 0
	for attemptID := range refs {
		if checked >= maxChecks {
			break
		}
		checked++
		attempt, present := h.v2Attempts[attemptID]
		if !present || !now.Before(attempt.expiresAt) {
			h.removeV2AttemptLocked(attemptID)
			break
		}
	}
	return len(h.attemptsByConnection[connectionID]) < maxChecks
}

func (h *hub) removeV2AttemptsForConnectionLocked(connectionID string) {
	refs := h.attemptsByConnection[connectionID]
	if len(refs) == 0 {
		return
	}
	ids := make([]string, 0, len(refs))
	for attemptID := range refs {
		ids = append(ids, attemptID)
	}
	for _, attemptID := range ids {
		h.removeV2AttemptLocked(attemptID)
	}
}

func peerControlOpen(peer *peer) bool {
	if !peerIsRoutable(peer) {
		return false
	}
	if peer.done == nil {
		return true
	}
	select {
	case <-peer.done:
		return false
	default:
		return true
	}
}

// consumeRelayReservationGate atomically consumes an authorization regardless
// of whether its target matches. A malformed/replayed request cannot probe or
// retain a live gate. The returned target connection is the exact connection
// that received the offer; a reconnect must start a fresh Resolve -> Offer.
func (h *hub) consumeRelayReservationGate(sender *peer, attemptID, targetDeviceID string) (relayReservationGate, bool) {
	if sender == nil || attemptID == "" {
		return relayReservationGate{}, false
	}
	h.mutex.Lock()
	defer h.mutex.Unlock()
	key := relayReservationGateKey{initiatorConnectionID: sender.connectionID, attemptID: attemptID}
	gate, present := h.reservationGates.take(key, time.Now())
	if !present || gate.initiatorDeviceID != sender.deviceID || gate.targetDeviceID != targetDeviceID {
		return relayReservationGate{}, false
	}
	if h.peers[sender.deviceID] != sender || !peerControlOpen(sender) {
		return relayReservationGate{}, false
	}
	target := h.peers[gate.targetDeviceID]
	if !peerControlOpen(target) || target.connectionID != gate.targetConnectionID {
		return relayReservationGate{}, false
	}
	return gate, true
}

func newPendingAdmissionMap() map[string]*peer {
	return make(map[string]*peer)
}

func (h *hub) rememberCoordinationTarget(peer *peer, deviceID string) {
	if peer == nil || deviceID == "" {
		return
	}
	h.mutex.Lock()
	h.coordinationTargets[peer.connectionID] = coordinationTarget{
		deviceID:  deviceID,
		expiresAt: time.Now().Add(v2AttemptLifetime),
	}
	h.mutex.Unlock()
}

func (h *hub) consumeCoordinationTarget(peer *peer) (string, bool) {
	if peer == nil {
		return "", false
	}
	h.mutex.Lock()
	ticket, ok := h.coordinationTargets[peer.connectionID]
	if ok {
		delete(h.coordinationTargets, peer.connectionID)
	}
	h.mutex.Unlock()
	if !ok || !time.Now().Before(ticket.expiresAt) {
		return "", false
	}
	return ticket.deviceID, true
}

// monitorHeartbeats 是服务端心跳租约定时器（在客户端驱动的续期之外）：每
// ServerHeartbeatInterval 扫描一次本地 peer，超过
// ServerHeartbeatMisses×ServerHeartbeatInterval 未收到 heartbeat 帧的连接视为僵尸，
// 定向关闭。关闭会解除 read goroutine 对 socket 的阻塞，其 deferred remove() 随后
// 释放 presence/discovery 租约并广播 peer_offline——与 sweeper 收敛路径一致。
func (h *hub) monitorHeartbeats() {
	interval := h.serverHeartbeatInterval
	if interval <= 0 {
		interval = defaultServerHeartbeatInterval
	}
	misses := h.serverHeartbeatMisses
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
				if peerIsRoutable(p) && now.Sub(p.lastHeartbeat) > threshold {
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

// hubCloseTimeout bounds the complete Hub close transaction, including shared
// presence cleanup and peer/pruner convergence. Peer sockets are closed before
// waiting, so this normally returns immediately; the bound exists so a wedged
// dependency or goroutine cannot exceed the Compose stop_grace_period.
const hubCloseTimeout = 5 * time.Second

// hubPresenceSweepTimeout bounds both the cleanup calls and the wait for their
// workers. A store implementation is expected to honor context cancellation,
// but shutdown must still return if a buggy dependency ignores it.
const hubPresenceSweepTimeout = 2 * time.Second

// presenceLeaseTimeout bounds each heartbeat's presence lease I/O so a slow or
// hung Redis cannot stall the WebSocket read goroutine (which also routes data
// frames). On timeout the ownership is unknown and the connection is kept
// (fail-open); the next heartbeat retries.
const presenceLeaseTimeout = 500 * time.Millisecond

func (h *hub) close() {
	h.closeOnce.Do(func() {
		closeDeadline := time.Now().Add(hubCloseTimeout)
		h.mutex.Lock()
		h.closed = true
		close(h.stop)
		peers := make([]*peer, 0, len(h.peers)+len(h.pendingAdmissions))
		for _, value := range h.peers {
			peers = append(peers, value)
		}
		for _, value := range h.pendingAdmissions {
			peers = append(peers, value)
		}
		h.peers = map[string]*peer{}
		h.pendingAdmissions = map[string]*peer{}
		h.coordinationTargets = map[string]coordinationTarget{}
		h.v2Attempts = map[string]v2Attempt{}
		h.attemptsByConnection = map[string]map[string]struct{}{}
		h.v2AttemptExpiries.reset()
		h.reservationGates.reset()
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
			ctx, cancel := context.WithTimeout(context.Background(), hubPresenceSweepTimeout)
			var sweep sync.WaitGroup
			for _, p := range peers {
				sweep.Add(1)
				go func(peer *peer) {
					defer sweep.Done()
					_, _ = h.presence.ReleasePresence(ctx, peer.deviceID, peer.connectionID)
					_, _ = h.presence.ReleaseDiscovery(ctx, peer.deviceID, peer.connectionID)
				}(p)
			}
			sweepDone := make(chan struct{})
			go func() {
				sweep.Wait()
				close(sweepDone)
			}()
			select {
			case <-sweepDone:
			case <-ctx.Done():
			}
			cancel()
		}
		done := make(chan struct{})
		go func() {
			h.waitGroup.Wait()
			close(done)
		}()
		remaining := time.Until(closeDeadline)
		if remaining <= 0 {
			return
		}
		waitTimer := time.NewTimer(remaining)
		defer waitTimer.Stop()
		select {
		case <-done:
		case <-waitTimer.C:
			// Sockets were already closed above; proceed even if a goroutine
			// is stuck, keeping the process exit path bounded.
		}
	})
}

// add is the immediately-active form used by already-authorized internal
// callers and focused tests. HTTP admission uses stage followed by activate so
// no socket worker can run before the post-registration durable recheck.
func (h *hub) add(peer *peer) bool {
	if !h.stage(peer) {
		return false
	}
	return h.activate(peer)
}

func (h *hub) stage(peer *peer) bool {
	return h.stageWithContext(context.Background(), peer)
}

// stageWithContext keeps all presence-claim work inside the caller's composite
// admission budget. The legacy stage wrapper remains for already-authorized
// internal callers and focused tests that have no HTTP admission context.
func (h *hub) stageWithContext(parent context.Context, peer *peer) bool {
	if parent == nil {
		parent = context.Background()
	}
	if err := parent.Err(); err != nil {
		closePeer(peer)
		return false
	}
	peer.lastSeen = time.Now()
	// 服务端心跳监视器从连接建立开始计时，给新连接最多 2 个心跳周期（40s）发送首个
	// heartbeat；尚未上传首个 heartbeat 的连接不会被误杀。
	peer.lastHeartbeat = time.Now()
	if peer.activation == nil {
		peer.activation = make(chan struct{})
	}
	// Serialize admission per device so the Redis lease claim lands in
	// connection-establishment order: a newer connection's TakePresence runs only
	// after any in-flight claim for the same device completed, so a stale claim
	// can never overwrite it and kick the valid connection.
	unlockAdmission, locked := h.lockAdmissionContext(parent, peer.deviceID)
	if !locked {
		closePeer(peer)
		return false
	}
	defer unlockAdmission()
	if err := parent.Err(); err != nil {
		closePeer(peer)
		return false
	}

	h.mutex.Lock()
	if h.closed {
		h.mutex.Unlock()
		closePeer(peer)
		return false
	}
	previous := h.peers[peer.deviceID]
	if previous == nil && len(h.peers)+len(h.pendingAdmissions) >= h.maxConnections {
		h.mutex.Unlock()
		closePeer(peer)
		return false
	}
	if h.pendingAdmissions == nil {
		h.pendingAdmissions = newPendingAdmissionMap()
	}
	h.pendingAdmissions[peer.deviceID] = peer
	h.mutex.Unlock()
	// Take the presence lease while the socket remains non-routable in
	// pendingAdmissions. A failed or timed-out shared-state claim fails closed:
	// no Ready frame, worker, or h.peers entry exists yet.
	leaseTaken := false
	var old Presence
	var replaced bool
	if h.presence != nil {
		ctx, cancel := context.WithTimeout(parent, presenceLeaseTimeout)
		var err error
		old, replaced, err = h.presence.TakePresence(ctx, peer.deviceID, peer.connectionID, h.presenceFor(peer), h.presenceTTL)
		cancel()
		if err != nil {
			h.mutex.Lock()
			if h.pendingAdmissions[peer.deviceID] == peer {
				delete(h.pendingAdmissions, peer.deviceID)
			}
			h.mutex.Unlock()
			closePeer(peer)
			return false
		}
		leaseTaken = true
		// 不再写占位 discovery：在线判定要求 presence 与 discovery 双有效 + 真实
		// revision（>0）+ owner 一致（明确版 §13 收紧版）。连接建立后、设备真正
		// 发布 discovery 之前，该设备不被 resolve 视为可连接——§8「上传 discovery
		// 后才广播为 online」由此自然成立。discovery 只在设备发布 DiscoveryPublish
		// 时由 publishDiscoveryV2 写入（CAS 要求当前 presence owner）。
	}
	// Atomically publish the peer and register both workers in the same critical
	// section used by close/disconnect. The staged marker must still belong to
	// this connection and the previous local generation must be unchanged.
	h.mutex.Lock()
	canCommit := !h.closed && h.pendingAdmissions[peer.deviceID] == peer && h.peers[peer.deviceID] == previous
	if canCommit && previous == nil && len(h.peers) >= h.maxConnections {
		canCommit = false
	}
	if h.pendingAdmissions[peer.deviceID] == peer {
		delete(h.pendingAdmissions, peer.deviceID)
	}
	if canCommit {
		h.peers[peer.deviceID] = peer
		if previous != nil {
			h.removeV2AttemptsForConnectionLocked(previous.connectionID)
			h.reservationGates.removeConnection(previous.connectionID)
		}
		h.waitGroup.Add(2)
	}
	h.mutex.Unlock()
	if !canCommit {
		// The lease was just taken but this admission was rejected (the hub closed
		// or the peer was kicked while the claim was in flight): release the lease
		// we wrote so a rejected connection cannot leave a phantom "online" entry.
		// The release is CAS'd to this connection, so if a newer connection has
		// since taken the lease over it is left untouched — the same lifecycle
		// rule the heartbeat path applies after a post-renew currency re-check.
		if leaseTaken && h.presence != nil {
			ctx, cancel := context.WithTimeout(parent, presenceLeaseTimeout)
			_, _ = h.presence.ReleasePresence(ctx, peer.deviceID, peer.connectionID)
			cancel()
		}
		closePeer(peer)
		return false
	}
	if previous != nil {
		closePeer(previous)
	}
	if h.presence != nil && replaced && old.ConnectionID != "" && old.InstanceID != "" && old.InstanceID != h.instanceID {
		// Cross-instance takeover: tell the superseded connection's instance to
		// close it now. A lost event is covered by the heartbeat CAS fallback.
		ctx, cancel := context.WithTimeout(parent, presenceLeaseTimeout)
		_ = h.presence.Publish(ctx, RelayEvent{
			Type:            eventConnectionReplaced,
			DeviceID:        peer.deviceID,
			OldInstanceID:   old.InstanceID,
			OldConnectionID: old.ConnectionID,
			NewConnectionID: peer.connectionID,
			Time:            time.Now().UnixMilli(),
		})
		cancel()
	}
	go h.write(peer)
	go h.read(peer)
	return true
}

// activate commits a staged peer as routable and releases both socket workers.
// A concurrent lifecycle close wins by removing the exact peer first.
func (h *hub) activate(peer *peer) bool {
	if peer == nil {
		return false
	}
	h.mutex.Lock()
	current := !h.closed && h.peers[peer.deviceID] == peer
	if current {
		peer.admissionActive.Store(true)
		peer.activationOnce.Do(func() { close(peer.activation) })
	}
	h.mutex.Unlock()
	if !current {
		closePeer(peer)
	}
	return current
}

func (peer *peer) waitForActivation() bool {
	if peer.activation == nil {
		return true
	}
	select {
	case <-peer.activation:
		return peer.admissionActive.Load()
	case <-peer.done:
		return false
	}
}

func peerIsRoutable(peer *peer) bool {
	return peer != nil && (peer.activation == nil || peer.admissionActive.Load())
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
	delete(h.coordinationTargets, connectionID)
	h.removeV2AttemptsForConnectionLocked(connectionID)
	h.reservationGates.removeConnection(connectionID)
	h.mutex.Unlock()
	// Stop local traffic before touching the shared presence store. A stalled
	// Redis release must never extend the lifetime of a connection selected for
	// replacement/revocation.
	closePeer(current)
	if h.presence != nil {
		ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
		_, _ = h.presence.ReleasePresence(ctx, deviceID, connectionID)
		_, _ = h.presence.ReleaseDiscovery(ctx, deviceID, connectionID)
		cancel()
	}
	return true
}

func (h *hub) remove(peer *peer) {
	h.mutex.Lock()
	// Only the current peer releases the lease: a replaced peer's read goroutine
	// may still exit after a duplicate connect, and must not erase the new
	// peer's presence. The CAS ReleasePresence additionally guards the
	// cross-instance case where a foreign connection now owns the lease.
	isCurrent := h.peers[peer.deviceID] == peer
	delete(h.coordinationTargets, peer.connectionID)
	h.removeV2AttemptsForConnectionLocked(peer.connectionID)
	h.reservationGates.removeConnection(peer.connectionID)
	if isCurrent {
		delete(h.peers, peer.deviceID)
	}
	h.mutex.Unlock()
	closePeer(peer)
	if isCurrent && h.presence != nil {
		ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
		released, _ := h.presence.ReleasePresence(ctx, peer.deviceID, peer.connectionID)
		_, _ = h.presence.ReleaseDiscovery(ctx, peer.deviceID, peer.connectionID)
		cancel()
		// 仅当租约真被释放（released=true）才广播 peer_offline：若 CAS 返回 false，
		// 说明租约已被同设备的另一条连接接管（如本实例 socket 断开后设备在其它实例
		// 重连，TakePresence 已接管），设备实际仍在线上，广播 offline 会误报。
		// 被取代连接的 teardown（isCurrent==false）或 revoke/kick 路径
		// （disconnectDevice 已广播）也不在此重复。
		if released {
			h.broadcastPeerEvent(framePeerOffline, peer.deviceID, Discovery{})
		}
	}
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
	h.disconnectDeviceBeforeGeneration(deviceID, 0)
}

// disconnectDeviceBeforeGeneration closes only sockets authenticated under an
// enrollment generation older than cutoff. cutoff <= 0 is the unconditional
// revoke/shutdown form. Delayed re-enrollment events use a positive cutoff so
// they cannot terminate a connection already authenticated under the new
// durable enrollment generation.
func (h *hub) disconnectDeviceBeforeGeneration(deviceID string, cutoff int64) {
	h.mutex.Lock()
	peer := h.peers[deviceID]
	pending := h.pendingAdmissions[deviceID]
	if cutoff > 0 && peer != nil && peer.enrollmentGeneration >= cutoff {
		peer = nil
	}
	if cutoff > 0 && pending != nil && pending.enrollmentGeneration >= cutoff {
		pending = nil
	}
	if peer != nil {
		delete(h.peers, deviceID)
		delete(h.coordinationTargets, peer.connectionID)
		h.removeV2AttemptsForConnectionLocked(peer.connectionID)
		h.reservationGates.removeConnection(peer.connectionID)
	}
	if pending != nil {
		delete(h.pendingAdmissions, deviceID)
	}
	h.mutex.Unlock()
	if pending != nil {
		closePeer(pending)
	}
	if peer != nil {
		// Stop the socket first. Presence cleanup is shared-state bookkeeping and
		// is allowed to consume its bounded timeout without keeping traffic alive.
		closePeer(peer)
		// Release only this instance's current lease (CAS): the peer's deferred
		// remove() would see isCurrent==false and never release it, so do it
		// here. If a newer connection replaced this peer or took over the lease
		// from another instance, the release is a no-op instead of wiping the
		// live presence. A device connected on another instance is released
		// there when it receives the revoke/kick event, or by reconcileRevocations.
		released := false
		if h.presence != nil {
			ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
			released, _ = h.presence.ReleasePresence(ctx, deviceID, peer.connectionID)
			_, _ = h.presence.ReleaseDiscovery(ctx, deviceID, peer.connectionID)
			cancel()
		}
		// 设备被整机断开（revoke/kick/对账/重新 enroll 抢占）：广播 peer_offline。
		// 关闭触发的 remove() 此时 isCurrent==false 不会重复广播。被新连接替换的
		// 定向断开走 disconnectConnection（新连接已接管，不广播 offline）。仅当租约
		// 真被释放（released=true）才广播——CAS 返回 false 说明设备已在别处重连，
		// 广播 offline 会误报仍在线的设备。
		if released {
			h.broadcastPeerEvent(framePeerOffline, deviceID, Discovery{})
		}
	}
}

func (h *hub) write(peer *peer) {
	defer h.waitGroup.Done()
	defer h.remove(peer)
	if !peer.waitForActivation() {
		return
	}
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
	if !peer.waitForActivation() {
		return
	}
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
			h.pruneExpiredV2AttemptsLocked(now, maxV2StatePrunesPerSweep)
			h.reservationGates.prune(now, maxV2StatePrunesPerSweep)
			h.mutex.Unlock()
		}
	}
}
