// Relay Data reservation model（设计 §25）与 /v2/relay/{reservation_id} 不透明转发。
//
// Reservation 是「Direct 失败后走 Relay」的短命数据通道凭证：发起方 A 通过 /v2/control
// 发 RelayReserveRequest，服务端创建 reservation（Redis relay:reservation:{id}，
// TTL=expires_at），给 A 回 RelayReserveResponse、给 B 推 IncomingRelayReservation；
// 双方随后各自连接 /v2/relay/{reservation_id}，数据面只做加密 payload 的透明转发、
// flow control 与 close——服务端绝不解析 encrypted_payload（ADR-017 边界）。
//
// 数据面连接不使用 hub peer 表，也没有 presence 租约：它是 reservation 作用域内的
// 短命双端点连接。relayDataRegistry 负责按 initiator/responder 角色把同一 reservation
// 的两个端点链接起来，并在配对完成后发送 PairReady Ping；之后每个端点收到的
// RelayDataPayload/RelayDataAck 都被原样转发到另一端，RelayDataClose 则双向关闭。

package relay

import (
	"context"
	"crypto/hmac"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"github.com/redis/go-redis/v9"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

// Reservation 是服务端共享状态层中的一条 relay-data reservation（设计 §25）。
// 两个 local_token 各自独立：InitiatorToken 只给 A（RelayReserveResponse.local_token），
// ResponderToken 只给 B（IncomingRelayReservation.local_token），这样 A 无法用 B 的
// token 抢占 B 的端点。Redis 模式存 relay:reservation:{reservation_id}，TTL 到
// expires_at_ms。LifetimeS 是创建时夹取后的存活秒数（[15,120]），数据面用它做滑动
// 窗口续期（每次成功帧把到期时刻重置为 now+lifetime+grace）。
type Reservation struct {
	ReservationID     string `json:"reservation_id"`            // 16-byte hex，32 chars
	AttemptID         string `json:"attempt_id,omitempty"`      // 发起方异步 attempt 关联键
	InitiatorDeviceID string `json:"initiator_device_id"`       // 发起方 A
	ResponderDeviceID string `json:"responder_device_id"`       // 接收方 B
	RelayDataEndpoint string `json:"relay_data_endpoint"`       // 自包含 wss://<host>/v2/relay/<id>
	InitiatorToken    []byte `json:"initiator_token,omitempty"` // A 的 32-byte 连接凭证
	ResponderToken    []byte `json:"responder_token,omitempty"` // B 的 32-byte 连接凭证
	// ExpiresAtMs 是创建时刻的「名义」到期（Unix 毫秒）。滑动窗口续期只滑动存储 TTL，
	// 绝不回写本字段；升级准入与数据面到期定时器都用滑动窗口（GetReservation ok 结果 /
	// refreshTTL/touch），本字段只作 nominal 展示与旧格式条目的兜底参考。
	ExpiresAtMs int64  `json:"expires_at_ms"`
	LifetimeS   uint32 `json:"lifetime_s,omitempty"` // 夹取后的存活秒数（滑动窗口续期基准）
}

// reservationEntry 是内存实现的 reservation 条目，带显式过期时间（内存模式无 Redis TTL）。
type reservationEntry struct {
	reservation Reservation
	expiresAt   time.Time
}

// errReservationNotOwner 报告 reservation 写者不是期望的所有者（预留，暂未使用，
// 保持与 presence/discovery 的 CAS 语义同构——本阶段 reservation 一次性创建、无接管）。
var errReservationNotOwner = errors.New("relay reservation write rejected: not the owner")

// clampReservationLifetime 把客户端想要的 reservation 存活秒数夹到冻结契约的
// [RESERVATION_LIFETIME_S_MIN, RESERVATION_LIFETIME_S_MAX] 区间；0 用默认值。
func clampReservationLifetime(desired uint32) uint32 {
	if desired == 0 {
		desired = v2.RESERVATION_LIFETIME_S_DEFAULT
	}
	if desired < reservationLifetimeMinS {
		desired = reservationLifetimeMinS
	}
	if desired > reservationLifetimeMaxS {
		desired = reservationLifetimeMaxS
	}
	return desired
}

// reservationHardExpiry 返回 reservation 的硬到期时刻：nominal expires_at_ms 之后再
// 加冻结的宽限（RESERVATION_EXPIRY_GRACE_S）。存储层把条目保留到硬到期，使「过期但
// 仍在宽限内」的连接还能被 /v2/relay 升级接受；数据面连接在硬到期时刻由自身定时器关闭。
func reservationHardExpiry(expiresAtMs int64) time.Time {
	return time.UnixMilli(expiresAtMs).Add(time.Duration(v2.RESERVATION_EXPIRY_GRACE_S) * time.Second)
}

// reservation 生命周期与数据面限制的集中常量（禁止散落 magic number，§39）。
const (
	// reservationLifetimeMinS / reservationLifetimeMaxS 是服务端对
	// desired_lifetime_s 的夹取区间（冻结契约 [15, 120]）。
	reservationLifetimeMinS = 15
	reservationLifetimeMaxS = 120
	// maxPendingRelayDataConns 是 relayDataRegistry 中「已连接一个端点、等待第二个」的
	// reservation 上限，防止异常客户端堆积 pending 连接耗尽内存。
	maxPendingRelayDataConns = 4096
	// relayDataWriteTimeout 是数据面每次 socket 写操作的 deadline。
	relayDataWriteTimeout = 10 * time.Second
	// RelayData liveness is independent from reservation admission TTL once both
	// roles have paired.  Control frames are still serialized by the same
	// outbound writer as binary RelayData frames.
	relayDataPingInterval            = 30 * time.Second
	relayDataPongTimeout             = 15 * time.Second
	relayDataPairReadyPing           = "ssh-mobile-relay-paired-v1:"
	maxConsumedRelayDataReservations = 65536
)

// ---------------------------------------------------------------------------
// Reservation 存储：memoryStore（cache.go 同锁 mu）
// ---------------------------------------------------------------------------

func (m *memoryStore) CreateReservation(_ context.Context, r Reservation) error {
	if r.ReservationID == "" {
		return fmt.Errorf("reservation id is empty")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	for id, entry := range m.reservations {
		if now.After(entry.expiresAt) {
			delete(m.reservations, id)
		}
	}
	m.reservations[r.ReservationID] = reservationEntry{
		reservation: r,
		expiresAt:   reservationHardExpiry(r.ExpiresAtMs),
	}
	return nil
}

func (m *memoryStore) GetReservation(_ context.Context, reservationID string) (Reservation, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	entry, present := m.reservations[reservationID]
	if !present {
		return Reservation{}, false, nil
	}
	if time.Now().After(entry.expiresAt) {
		// 过期视为缺失，顺手剪除（与 GetPresence 的惰性清理一致）。
		delete(m.reservations, reservationID)
		return Reservation{}, false, nil
	}
	return entry.reservation, true, nil
}

func (m *memoryStore) DeleteReservation(_ context.Context, reservationID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.reservations, reservationID)
	return nil
}

// RenewReservation 把 reservation 的存活期限滑动到 now+ttl（滑动窗口续期：数据面流量
// 到来时由 relayDataConn.touch 调用）。条目不存在或已硬过期视为缺失，返回 false 不复活。
func (m *memoryStore) RenewReservation(_ context.Context, reservationID string, ttl time.Duration) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	entry, present := m.reservations[reservationID]
	if !present {
		return false, nil
	}
	if time.Now().After(entry.expiresAt) {
		// 已硬过期视为缺失，顺手剪除（与 GetReservation 的惰性清理一致）。
		delete(m.reservations, reservationID)
		return false, nil
	}
	entry.expiresAt = time.Now().Add(ttl)
	m.reservations[reservationID] = entry
	return true, nil
}

// ---------------------------------------------------------------------------
// Reservation 存储：redisStore（Redis relay:reservation:{id}，TTL=expires_at）
// ---------------------------------------------------------------------------

func (r *redisStore) reservationKey(reservationID string) string {
	return redisKeyPrefix + "reservation:" + reservationID
}

func (r *redisStore) CreateReservation(ctx context.Context, res Reservation) error {
	data, err := json.Marshal(res)
	if err != nil {
		return err
	}
	// Redis TTL 也带宽限：条目保留到硬到期时刻，宽限内仍可被升级接受。
	ttl := time.Until(reservationHardExpiry(res.ExpiresAtMs))
	if ttl <= 0 {
		return errors.New("relay reservation expires beyond the grace window")
	}
	return r.client.Set(ctx, r.reservationKey(res.ReservationID), string(data), ttl).Err()
}

func (r *redisStore) GetReservation(ctx context.Context, reservationID string) (Reservation, bool, error) {
	data, err := r.client.Get(ctx, r.reservationKey(reservationID)).Bytes()
	if errors.Is(err, redis.Nil) {
		return Reservation{}, false, nil
	}
	if err != nil {
		return Reservation{}, false, err
	}
	var res Reservation
	if err := json.Unmarshal(data, &res); err != nil {
		return Reservation{}, false, err
	}
	return res, true, nil
}

func (r *redisStore) DeleteReservation(ctx context.Context, reservationID string) error {
	return r.client.Del(ctx, r.reservationKey(reservationID)).Err()
}

// RenewReservation 把 reservation 键的 TTL 滑动到 now+ttl（滑动窗口续期，数据面流量
// 到来时调用）。键不存在（已过期被 Redis 主动清除）时返回 false。
func (r *redisStore) RenewReservation(ctx context.Context, reservationID string, ttl time.Duration) (bool, error) {
	if ttl <= 0 {
		return false, nil
	}
	return r.client.Expire(ctx, r.reservationKey(reservationID), ttl).Result()
}

// ---------------------------------------------------------------------------
// /v2/relay/{reservation_id} —— 不透明数据面
// ---------------------------------------------------------------------------

type relayDataRole uint8

const (
	relayDataRoleInitiator relayDataRole = iota + 1
	relayDataRoleResponder
)

type relayDataPair struct {
	initiator *relayDataConn
	responder *relayDataConn
}

// relayDataRegistry 把同一 reservation 的 initiator/responder 两个 /v2/relay
// 端点链接起来。角色由首帧 token 决定，不能因为到达顺序而互换。
type relayDataRegistry struct {
	mutex sync.Mutex
	pairs map[string]*relayDataPair
	// consumed is process-local because this deployment deliberately has one
	// live RelayData instance.  Once a pair has been established, the
	// reservation token cannot create another pair; active sockets retain their
	// in-memory reservation and are not dependent on the admission record.
	consumed map[string]struct{}
	// deviceRefs indexes every data endpoint after its RelayDataConnect frame
	// has been admitted.  Revocation uses it to close pending endpoints and the
	// counterpart of an active pair without scanning unrelated sockets.
	deviceRefs map[string]map[*relayDataConn]struct{}
	// upgradeRefs covers an authenticated WebSocket that has not sent its
	// RelayDataConnect first frame yet.  Revoke must close this pending socket
	// too; it must not be able to outlive the device authorization decision.
	upgradeRefs  map[string]map[*relayDataConn]struct{}
	pendingPairs int
}

func newRelayDataRegistry() *relayDataRegistry {
	return &relayDataRegistry{
		pairs:       make(map[string]*relayDataPair),
		consumed:    make(map[string]struct{}),
		deviceRefs:  make(map[string]map[*relayDataConn]struct{}),
		upgradeRefs: make(map[string]map[*relayDataConn]struct{}),
	}
}

func (r *relayDataRegistry) trackUpgradeLocked(rc *relayDataConn) {
	refs := r.upgradeRefs[rc.deviceID]
	if refs == nil {
		refs = make(map[*relayDataConn]struct{})
		r.upgradeRefs[rc.deviceID] = refs
	}
	refs[rc] = struct{}{}
}

func (r *relayDataRegistry) trackUpgrade(rc *relayDataConn) {
	r.mutex.Lock()
	r.trackUpgradeLocked(rc)
	r.mutex.Unlock()
}

func (r *relayDataRegistry) removeUpgradeLocked(rc *relayDataConn) {
	refs := r.upgradeRefs[rc.deviceID]
	if refs == nil {
		return
	}
	delete(refs, rc)
	if len(refs) == 0 {
		delete(r.upgradeRefs, rc.deviceID)
	}
}

func (r *relayDataRegistry) addDeviceRefLocked(rc *relayDataConn) {
	refs := r.deviceRefs[rc.deviceID]
	if refs == nil {
		refs = make(map[*relayDataConn]struct{})
		r.deviceRefs[rc.deviceID] = refs
	}
	refs[rc] = struct{}{}
}

func (r *relayDataRegistry) removeDeviceRefLocked(rc *relayDataConn) {
	refs := r.deviceRefs[rc.deviceID]
	if refs == nil {
		return
	}
	delete(refs, rc)
	if len(refs) == 0 {
		delete(r.deviceRefs, rc.deviceID)
	}
}

// register 登记一条已通过 Connect 校验的数据面连接。
//
// 同角色重试会替换旧端点；已经完成配对的 reservation 则整体拆除旧 pair，要求
// 两端重新完成 Connect。只有两个角色都存在时才会按顺序排入 PairReady Ping，并
// 将 ready 置为 true。返回的 replaced 由调用方在解锁后关闭，避免旧连接的读循环
// 参与新 pair 的状态变更。
func (r *relayDataRegistry) register(rc *relayDataConn) (peer *relayDataConn, replaced []*relayDataConn, ok bool) {
	r.mutex.Lock()
	r.removeUpgradeLocked(rc)
	if _, alreadyConsumed := r.consumed[rc.reservationID]; alreadyConsumed {
		r.mutex.Unlock()
		return nil, nil, false
	}
	pair := r.pairs[rc.reservationID]
	if pair == nil {
		if r.pendingPairs >= maxPendingRelayDataConns {
			r.mutex.Unlock()
			return nil, nil, false
		}
		pair = &relayDataPair{}
		r.pairs[rc.reservationID] = pair
		r.pendingPairs++
	}

	var slot **relayDataConn
	var other *relayDataConn
	switch rc.role {
	case relayDataRoleInitiator:
		slot = &pair.initiator
		other = pair.responder
	case relayDataRoleResponder:
		slot = &pair.responder
		other = pair.initiator
	default:
		r.mutex.Unlock()
		return nil, nil, false
	}
	if *slot != nil {
		// A role slot is one-shot.  Replacing an endpoint would let a replayed
		// token steal a still-pending pair and made reservation consumption
		// ambiguous.  The caller closes the duplicate outside the registry lock.
		r.mutex.Unlock()
		return nil, nil, false
	}
	*slot = rc
	r.addDeviceRefLocked(rc)

	if pair.initiator != nil && pair.responder != nil {
		if len(r.consumed) >= maxConsumedRelayDataReservations {
			r.mutex.Unlock()
			return nil, nil, false
		}
		if r.pendingPairs > 0 {
			r.pendingPairs--
		}
		peer = other
		rc.link(peer)
		// PairReady is the sole L1 setup signal on the frozen contract.  It is a
		// WebSocket Ping, queued before publishing ready=true, and therefore
		// shares the same single writer as Pong, keepalive, binary, and Close.
		pairReadyQueued := rc.enqueuePairReadyPing() && peer.enqueuePairReadyPing()
		rc.ready.Store(pairReadyQueued)
		peer.ready.Store(pairReadyQueued)
		if pairReadyQueued {
			r.consumed[rc.reservationID] = struct{}{}
			rc.paired.Store(true)
			peer.paired.Store(true)
		}
	}
	r.mutex.Unlock()
	return peer, replaced, true
}

// unregister 在端点关闭时解除注册。旧的、已经被同角色替换的连接不会触碰当前 pair。
func (r *relayDataRegistry) unregister(rc *relayDataConn) {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	r.removeUpgradeLocked(rc)
	pair := r.pairs[rc.reservationID]
	if pair == nil {
		r.removeDeviceRefLocked(rc)
		return
	}
	wasComplete := pair.initiator != nil && pair.responder != nil
	removed := false
	if pair.initiator == rc {
		pair.initiator = nil
		removed = true
	}
	if pair.responder == rc {
		pair.responder = nil
		removed = true
	}
	if !removed {
		r.removeDeviceRefLocked(rc)
		return
	}
	r.removeDeviceRefLocked(rc)
	rc.ready.Store(false)
	other := pair.initiator
	if other == nil {
		other = pair.responder
	}
	if other != nil {
		other.ready.Store(false)
		other.clearPeer()
	}
	rc.clearPeer()
	if wasComplete {
		delete(r.pairs, rc.reservationID)
	} else if pair.initiator == nil && pair.responder == nil {
		delete(r.pairs, rc.reservationID)
		if r.pendingPairs > 0 {
			r.pendingPairs--
		}
	}
}

// closeDevice closes every data endpoint authenticated as deviceID.  An active
// endpoint also closes its counterpart; a pending endpoint is closed in place.
// The registry lock is released before socket work so revoke cannot block
// registration of unrelated reservations on a slow WebSocket peer.
func (r *relayDataRegistry) closeDevice(deviceID string) {
	r.mutex.Lock()
	targets := make(map[*relayDataConn]struct{})
	for rc := range r.deviceRefs[deviceID] {
		targets[rc] = struct{}{}
		if peer := rc.peerConn(); peer != nil {
			targets[peer] = struct{}{}
		}
	}
	for rc := range r.upgradeRefs[deviceID] {
		targets[rc] = struct{}{}
	}
	r.mutex.Unlock()

	for rc := range targets {
		rc.sendCloseAndShutdown(2, "device revoked")
	}
}

// closeAll is used during server shutdown.  It is deliberately separate from
// closeDevice so shutdown can close every local data socket without pretending
// that a device-level revocation occurred.
func (r *relayDataRegistry) closeAll() {
	r.mutex.Lock()
	targets := make(map[*relayDataConn]struct{})
	for _, pair := range r.pairs {
		if pair.initiator != nil {
			targets[pair.initiator] = struct{}{}
		}
		if pair.responder != nil {
			targets[pair.responder] = struct{}{}
		}
	}
	for _, refs := range r.upgradeRefs {
		for rc := range refs {
			targets[rc] = struct{}{}
		}
	}
	r.mutex.Unlock()

	for rc := range targets {
		rc.sendCloseAndShutdown(2, "relay server shutting down")
	}
}

// relayDataConn 是 /v2/relay/{reservation_id} 的一个端点。它没有 presence 租约，
// 只用 reservation 校验身份；peer 是同一 reservation 的另一端点（由 registry 链接）。
// 写侧：read goroutine 阻塞读 socket，write goroutine 从 outbound 写帧并在 close 时
// 先 drain 再关 socket，保证 RelayDataClose 帧能被冲刷到对端。
type relayDataConn struct {
	reservationID string
	res           Reservation
	deviceID      string
	role          relayDataRole
	registry      *relayDataRegistry
	cache         Cache // 滑动窗口续期 reservation 存储 TTL 用
	socket        *websocket.Conn
	outbound      chan outboundFrame
	done          chan struct{}
	writeDone     chan struct{}
	once          sync.Once
	grace         time.Duration

	peerMutex sync.Mutex
	peer      *relayDataConn
	ready     atomic.Bool
	paired    atomic.Bool
	lastPong  atomic.Int64

	// 与 hub peer 同构的速率/积压预算字段。
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
}

func newRelayDataConn(registry *relayDataRegistry, res Reservation, socket *websocket.Conn, config Config, cache Cache, deviceID string, role relayDataRole) *relayDataConn {
	return &relayDataConn{
		reservationID:      res.ReservationID,
		res:                res,
		deviceID:           deviceID,
		role:               role,
		registry:           registry,
		cache:              cache,
		socket:             socket,
		outbound:           make(chan outboundFrame, config.MaxPendingFramesPerDevice),
		done:               make(chan struct{}),
		writeDone:          make(chan struct{}),
		grace:              time.Duration(v2.RESERVATION_EXPIRY_GRACE_S) * time.Second,
		maxPendingFrames:   config.MaxPendingFramesPerDevice,
		maxPendingBytes:    config.MaxPendingBytesPerDevice,
		maxFramesPerSecond: config.MaxFramesPerSecondPerDevice,
		maxBytesPerSecond:  config.MaxBytesPerSecondPerDevice,
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
		rc.registry.unregister(rc)
		if other != nil {
			other.sendCloseAndShutdown(2, "relay peer disconnected")
		}
		<-rc.writeDone
	}()
	rc.socket.SetReadLimit(v2.MAX_RELAY_DATA_FRAME_BYTES)
	// Gorilla invokes these handlers from the single read goroutine.  Responses
	// are queued instead of calling WriteControl/WriteMessage directly, so every
	// WebSocket write (Pong, keepalive Ping, PairReady Ping, binary frames and
	// Close) has one owner.
	rc.lastPong.Store(time.Now().UnixNano())
	rc.socket.SetPingHandler(func(payload string) error {
		rc.lastPong.Store(time.Now().UnixNano())
		if !rc.enqueue(outboundFrame{websocket.PongMessage, []byte(payload)}) {
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
		kind, data, err := rc.socket.ReadMessage()
		if err != nil {
			return
		}
		if kind != websocket.BinaryMessage {
			rc.sendCloseAndShutdown(2, "only binary frames are allowed on /v2/relay")
			return
		}
		if !rc.allowFrame(len(data)) {
			rc.sendCloseAndShutdown(2, "relay data rate limit exceeded")
			return
		}
		frame, err := v2.DecodeData(data)
		if err != nil {
			rc.sendCloseAndShutdown(2, v2.ErrorCodeOf(err).String())
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
			peer, replaced, registered := rc.registry.register(rc)
			for _, old := range replaced {
				old.sendCloseAndShutdown(2, "relay data connection replaced")
			}
			if !registered {
				rc.sendCloseAndShutdown(2, "too many pending relay data connections")
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
				if rc.cache != nil {
					ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
					_ = rc.cache.DeleteReservation(ctx, rc.reservationID)
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
	if !rc.paired.Load() {
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
				now := time.Now()
				if !lastPing.IsZero() && now.Sub(lastPing) >= relayDataPongTimeout {
					last := time.Unix(0, rc.lastPong.Load())
					if !last.After(lastPing) {
						rc.sendCloseAndShutdown(2, "relay data pong timeout")
						return
					}
				}
				if !lastPing.IsZero() && now.Sub(lastPing) < relayDataPingInterval {
					continue
				}
				if !rc.enqueue(outboundFrame{
					messageType: websocket.PingMessage,
					data:        []byte(relayDataPairReadyPing + rc.reservationID),
				}) {
					rc.close()
					return
				}
				lastPing = now
			}
		}
	}()
}

// touch 在每次成功的数据面帧后续期滑动窗口：(a) 本地到期定时器重置到
// now+lifetime+grace；(b) 尽力续期共享存储里 reservation 的 TTL（失败静默——数据面
// 连接仍由本地定时器兜底关闭）。Stop 返回 false 表示定时器已触发（回调正在运行）、
// 连接正在关闭，此时不再续期。仅 read goroutine 调用 Stop/Reset，避免与回调并发。
func (rc *relayDataConn) touch(expiryTimer *time.Timer) {
	if rc.paired.Load() {
		return
	}
	if !expiryTimer.Stop() {
		return
	}
	ttl := rc.refreshTTL()
	expiryTimer.Reset(ttl)
	if rc.cache == nil {
		return
	}
	rctx, rcancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	_, _ = rc.cache.RenewReservation(rctx, rc.reservationID, ttl)
	rcancel()
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
	other := rc.peerConn()
	if !rc.ready.Load() || other == nil || !other.ready.Load() {
		return false
	}
	return other.enqueueFrame(frame)
}

func (rc *relayDataConn) enqueuePairReadyPing() bool {
	return rc.enqueue(outboundFrame{
		messageType: websocket.PingMessage,
		data:        []byte(relayDataPairReadyPing + rc.reservationID),
	})
}

// enqueueFrame 编码并投递一帧到本连接的 outbound。
func (rc *relayDataConn) enqueueFrame(frame *v2.RelayDataFrame) bool {
	data, err := v2.EncodeDataFrame(frame)
	if err != nil {
		return false
	}
	return rc.enqueue(outboundFrame{websocket.BinaryMessage, data})
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
	rc.once.Do(func() {
		close(rc.done)
	})
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
	for {
		select {
		case <-rc.done:
			rc.drainOutbound()
			return
		case frame := <-rc.outbound:
			rc.dequeue(frame)
			_ = rc.socket.SetWriteDeadline(time.Now().Add(relayDataWriteTimeout))
			if err := rc.socket.WriteMessage(frame.messageType, frame.data); err != nil {
				return
			}
		}
	}
}

// drainOutbound 在 done 之后把仍在 outbound 里的帧尽力写完（非阻塞 select 读空）。
func (rc *relayDataConn) drainOutbound() {
	for {
		select {
		case frame := <-rc.outbound:
			_ = rc.socket.SetWriteDeadline(time.Now().Add(time.Second))
			if rc.socket.WriteMessage(frame.messageType, frame.data) != nil {
				return
			}
		default:
			return
		}
	}
}

// enqueue/dequeue/allowFrame 与 hub peer 同构：outbound 积压与每秒帧/字节预算。
func (rc *relayDataConn) enqueue(frame outboundFrame) bool {
	rc.stateMutex.Lock()
	defer rc.stateMutex.Unlock()
	select {
	case <-rc.done:
		return false
	default:
	}
	if rc.maxPendingFrames > 0 && rc.pendingFrames >= rc.maxPendingFrames {
		return false
	}
	frameBytes := int64(len(frame.data))
	if rc.maxPendingBytes > 0 && frameBytes > rc.maxPendingBytes-rc.pendingBytes {
		return false
	}
	select {
	case rc.outbound <- frame:
		rc.pendingFrames++
		rc.pendingBytes += frameBytes
		return true
	default:
		return false
	}
}

func (rc *relayDataConn) dequeue(frame outboundFrame) {
	rc.stateMutex.Lock()
	if rc.pendingFrames > 0 {
		rc.pendingFrames--
	}
	frameBytes := int64(len(frame.data))
	if frameBytes >= rc.pendingBytes {
		rc.pendingBytes = 0
	} else {
		rc.pendingBytes -= frameBytes
	}
	rc.stateMutex.Unlock()
}

func (rc *relayDataConn) allowFrame(size int) bool {
	rc.stateMutex.Lock()
	defer rc.stateMutex.Unlock()
	now := time.Now()
	if now.Sub(rc.windowStartedAt) >= time.Second {
		rc.windowStartedAt = now
		rc.framesInWindow = 0
		rc.bytesInWindow = 0
	}
	maxFrames := rc.maxFramesPerSecond
	if maxFrames <= 0 {
		maxFrames = defaultMaxFramesPerSecondPerDevice
	}
	maxBytes := rc.maxBytesPerSecond
	if maxBytes <= 0 {
		maxBytes = defaultMaxBytesPerSecondPerDevice
	}
	if rc.framesInWindow >= maxFrames || int64(size) > maxBytes-rc.bytesInWindow {
		return false
	}
	rc.framesInWindow++
	rc.bytesInWindow += int64(size)
	return true
}

// ---------------------------------------------------------------------------
// HTTP：GET /v2/relay/{reservation_id}
// ---------------------------------------------------------------------------

// connectRelayData 处理 /v2/relay/{reservation_id} 升级。先完成与控制面相同的
// authenticatedRequest，再按 authenticated device -> reservation role -> role token
// 绑定校验 query/header token；首帧 RelayDataConnect 会再次执行同一绑定校验。
func (s *Server) connectRelayData(w http.ResponseWriter, r *http.Request) {
	reservationID := r.PathValue("reservation_id")
	if !validReservationID(reservationID) {
		http.Error(w, "invalid reservation id", http.StatusNotFound)
		return
	}
	// Authenticate before touching reservation state.  An unauthenticated caller
	// must not be able to distinguish an existing reservation from a missing one.
	claims, publicKey, code, authenticated := s.authenticatedRequest(r)
	if !authenticated {
		retry := retryUnspecified
		if code == relayErrorCredentialExpired {
			retry = retryRefreshCredentialThenRetry
		}
		writeNetworkErrorRetry(w, http.StatusUnauthorized, code,
			"Relay data-plane authentication failed.", "connect_relay_data", "", retry, 0)
		return
	}
	unlockAdmission, admissionCode, admitted := s.admitAuthenticatedDevice(r.Context(), claims, publicKey)
	if !admitted {
		retry := retryUnspecified
		if admissionCode == relayErrorCredentialExpired {
			retry = retryRefreshCredentialThenRetry
		}
		writeNetworkErrorRetry(w, http.StatusUnauthorized, admissionCode,
			"Relay data-plane authentication failed.", "connect_relay_data", "", retry, 0)
		return
	}
	// Hold the device admission lock through reservation/token validation,
	// websocket upgrade, and upgrade-registry insertion only. The data socket is
	// long-lived, so retaining the lock for its whole lifetime would delay
	// revoke/re-enroll indefinitely; after trackUpgrade, revoke can find and
	// close this endpoint directly.
	defer func() {
		if unlockAdmission != nil {
			unlockAdmission()
		}
	}()
	ctx, cancel := context.WithTimeout(r.Context(), presenceLeaseTimeout)
	res, ok, err := s.cache.GetReservation(ctx, reservationID)
	cancel()
	if err != nil {
		writeNetworkErrorRetry(w, http.StatusServiceUnavailable, relayErrorUnspecified,
			"Relay data reservation lookup failed.", "connect_relay_data", "", retryUnspecified, 0)
		return
	}
	if !ok {
		http.Error(w, "reservation not found", http.StatusNotFound)
		return
	}
	// 不按名义 ExpiresAtMs 做升级准入：滑动窗口续期（RenewReservation/touch）只滑动
	// 存储 TTL，从不回写 ExpiresAtMs，因此晚加入的端点即使名义到期已过、只要存储键仍
	// 存活（GetReservation ok）就必须被接受。GetReservation 的 ok 结果已编码滑动窗口
	// 活性（memoryStore 按滑动的 entry.expiresAt 剪除，redisStore 依赖滑动的 Redis TTL）。
	role, roleOK := relayDataRoleForDevice(res, claims.DeviceID)
	if !roleOK || !validRelayTokenForRole(r, res, role) {
		http.Error(w, "invalid reservation token", http.StatusUnauthorized)
		return
	}
	connection, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	// 不在升级阶段登记：只有首帧 RelayDataConnect 通过校验后才进入 registry（避免
	// 把自身当成等待对端）。未发 Connect 的已升级连接不占 pending 容量，但仍
	// 由 upgradeRefs 追踪，以便 explicit revoke 立即关闭它。
	rc := newRelayDataConn(&s.relayData, res, connection, s.config, s.cache, claims.DeviceID, role)
	s.relayData.trackUpgrade(rc)
	unlockAdmission()
	unlockAdmission = nil
	go rc.write()
	go rc.read()
}

func relayDataRoleForDevice(res Reservation, deviceID string) (relayDataRole, bool) {
	if deviceID == "" || res.InitiatorDeviceID == res.ResponderDeviceID {
		return 0, false
	}
	switch deviceID {
	case res.InitiatorDeviceID:
		return relayDataRoleInitiator, true
	case res.ResponderDeviceID:
		return relayDataRoleResponder, true
	default:
		return 0, false
	}
}

// validReservationID 校验 reservation_id 是 16-byte hex、32 个小写字符。
func validReservationID(id string) bool {
	if len(id) != v2.RESERVATION_ID_HEX_CHARS {
		return false
	}
	if id != strings.ToLower(id) {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

// validRelayToken 从 query (?token=) 或 header (X-Relay-Token) 读取 hex 编码的
// reservation token，并校验它匹配 A 或 B 任一端的 token。
func validRelayToken(r *http.Request, res Reservation) bool {
	return validRelayTokenForRole(r, res, relayDataRoleInitiator) ||
		validRelayTokenForRole(r, res, relayDataRoleResponder)
}

func validRelayTokenForRole(r *http.Request, res Reservation, role relayDataRole) bool {
	queryToken := r.URL.Query().Get("token")
	headerToken := r.Header.Get("X-Relay-Token")
	if queryToken == "" && headerToken == "" {
		return false
	}
	if queryToken != "" && headerToken != "" && queryToken != headerToken {
		return false
	}
	token := queryToken
	if token == "" {
		token = headerToken
	}
	raw, err := hex.DecodeString(token)
	if err != nil {
		return false
	}
	var expected []byte
	switch role {
	case relayDataRoleInitiator:
		expected = res.InitiatorToken
	case relayDataRoleResponder:
		expected = res.ResponderToken
	default:
		return false
	}
	return len(raw) == len(expected) && hmac.Equal(raw, expected)
}
