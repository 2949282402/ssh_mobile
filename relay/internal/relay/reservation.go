// Relay Data reservation model（设计 §25）与 /v2/relay/{reservation_id} 不透明转发。
//
// Reservation 是「Direct 失败后走 Relay」的短命数据通道凭证：发起方 A 通过 /v2/control
// 发 RelayReserveRequest，服务端创建 reservation（Redis relay:reservation:{id}，
// TTL=expires_at），给 A 回 RelayReserveResponse、给 B 推 IncomingRelayReservation；
// 双方随后各自连接 /v2/relay/{reservation_id}，数据面只做加密 payload 的透明转发、
// flow control 与 close——服务端绝不解析 encrypted_payload（ADR-017 边界）。
//
// 数据面连接不使用 hub peer 表，也没有 presence 租约：它是 reservation 作用域内的
// 短命双端点连接。relayDataRegistry 负责把同一 reservation 的两个端点链接起来，之后
// 每个端点收到的 RelayDataPayload/RelayDataAck 都被原样转发到另一端，RelayDataClose
// 则双向关闭。

package relay

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/redis/go-redis/v9"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

// Reservation 是服务端共享状态层中的一条 relay-data reservation（设计 §25）。
// 两个 local_token 各自独立：InitiatorToken 只给 A（RelayReserveResponse.local_token），
// ResponderToken 只给 B（IncomingRelayReservation.local_token），这样 A 无法用 B 的
// token 抢占 B 的端点。Redis 模式存 relay:reservation:{reservation_id}，TTL 到
// expires_at_ms。
type Reservation struct {
	ReservationID     string `json:"reservation_id"`            // 16-byte hex，32 chars
	AttemptID         string `json:"attempt_id,omitempty"`      // 发起方异步 attempt 关联键
	InitiatorDeviceID string `json:"initiator_device_id"`       // 发起方 A
	ResponderDeviceID string `json:"responder_device_id"`       // 接收方 B
	RelayDataEndpoint string `json:"relay_data_endpoint"`       // 自包含 wss://<host>/v2/relay/<id>
	InitiatorToken    []byte `json:"initiator_token,omitempty"` // A 的 32-byte 连接凭证
	ResponderToken    []byte `json:"responder_token,omitempty"` // B 的 32-byte 连接凭证
	ExpiresAtMs       int64  `json:"expires_at_ms"`             // Unix 毫秒
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

// ---------------------------------------------------------------------------
// /v2/relay/{reservation_id} —— 不透明数据面
// ---------------------------------------------------------------------------

// relayDataRegistry 把同一 reservation 的两个 /v2/relay 端点链接起来。第一个连接的
// 端点进入 pending 等待对端；第二个连接到达时把它们互相 link，随后各自转发。任一
// 端点关闭时 unregister 解除链接并让对端感知。
type relayDataRegistry struct {
	mutex   sync.Mutex
	pending map[string]*relayDataConn
}

func newRelayDataRegistry() *relayDataRegistry {
	return &relayDataRegistry{pending: make(map[string]*relayDataConn)}
}

// register 登记一条已通过 Connect 校验的数据面连接。返回 false 表示 pending 容量
// 已满且该 reservation 尚无对端，调用方应关闭该连接。
func (r *relayDataRegistry) register(rc *relayDataConn) bool {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	if other := r.pending[rc.reservationID]; other != nil {
		// 对端已在等待：两个端点齐了，互相 link。
		delete(r.pending, rc.reservationID)
		rc.link(other)
		return true
	}
	if len(r.pending) >= maxPendingRelayDataConns {
		return false
	}
	r.pending[rc.reservationID] = rc
	return true
}

// unregister 在端点关闭时解除注册。若是 pending 中的等待端点直接移除；若是已链接
// 的端点则清空双方的 peer 引用，让对端转发失败后自行关闭。
func (r *relayDataRegistry) unregister(rc *relayDataConn) {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	if r.pending[rc.reservationID] == rc {
		delete(r.pending, rc.reservationID)
		return
	}
	rc.clearPeer()
}

// relayDataConn 是 /v2/relay/{reservation_id} 的一个端点。它没有 presence 租约，
// 只用 reservation 校验身份；peer 是同一 reservation 的另一端点（由 registry 链接）。
// 写侧：read goroutine 阻塞读 socket，write goroutine 从 outbound 写帧并在 close 时
// 先 drain 再关 socket，保证 RelayDataClose 帧能被冲刷到对端。
type relayDataConn struct {
	reservationID string
	res           Reservation
	registry      *relayDataRegistry
	socket        *websocket.Conn
	outbound      chan outboundFrame
	done          chan struct{}
	writeDone     chan struct{}
	once          sync.Once
	grace         time.Duration

	peerMutex sync.Mutex
	peer      *relayDataConn

	// 与 peer 同构的速率/积压预算字段（v1 数据面同款语义）。
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

func newRelayDataConn(registry *relayDataRegistry, res Reservation, socket *websocket.Conn, config Config) *relayDataConn {
	return &relayDataConn{
		reservationID:      res.ReservationID,
		res:                res,
		registry:           registry,
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
// 之后 RelayDataPayload/RelayDataAck 原样转发给对端，RelayDataClose 转发后双向关闭。
// 任何协议违规 / 过期 / 预算超限都以 RelayDataClose(reason 1/2) 收场。
func (rc *relayDataConn) read() {
	defer func() {
		rc.close()
		rc.registry.unregister(rc)
		if other := rc.peerConn(); other != nil {
			other.sendCloseAndShutdown(2, "relay peer disconnected")
		}
		<-rc.writeDone
	}()
	rc.socket.SetReadLimit(v2.MAX_RELAY_DATA_FRAME_BYTES)
	// reservation 到期（含 5s 宽限）即强制关闭：即使对端空闲也会在到期时刻被踢。
	expiryDelay := time.Until(time.UnixMilli(rc.res.ExpiresAtMs).Add(rc.grace))
	expiryTimer := time.AfterFunc(expiryDelay, func() {
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
			if !rc.acceptConnect(connect) {
				rc.sendCloseAndShutdown(2, "invalid reservation id or token")
				return
			}
			connected = true
			if !rc.registry.register(rc) {
				rc.sendCloseAndShutdown(2, "too many pending relay data connections")
				return
			}
			continue
		}
		switch {
		case frame.GetPayload() != nil || frame.GetAck() != nil:
			// opaque 转发：encrypted_payload 绝不解密/解析，Ack 仅按 sequence 转发。
			if !rc.forward(frame) {
				rc.sendCloseAndShutdown(2, "relay peer not connected")
				return
			}
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

// acceptConnect 校验首帧 RelayDataConnect：reservation_id 必须等于路径段，local_token
// 必须匹配本端（A 或 B）的 token。
func (rc *relayDataConn) acceptConnect(connect *v2.RelayDataConnect) bool {
	if connect.ReservationId != rc.reservationID {
		return false
	}
	return bytes.Equal(connect.LocalToken, rc.res.InitiatorToken) ||
		bytes.Equal(connect.LocalToken, rc.res.ResponderToken)
}

// forward 把一帧 RelayDataFrame 编码后投递给对端端点。返回 false 表示对端未连接或
// 编码/投递失败。
func (rc *relayDataConn) forward(frame *v2.RelayDataFrame) bool {
	other := rc.peerConn()
	if other == nil {
		return false
	}
	return other.enqueueFrame(frame)
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

// enqueue/dequeue/allowFrame 与 v1 peer 同构：outbound 积压与每秒帧/字节预算。
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

// connectRelayData 处理 /v2/relay/{reservation_id} 升级。升级阶段校验 reservation_id
// 格式、存在性与未过期（含宽限），并用 query/header 中的 token（hex 编码）做授权；
// 首帧 RelayDataConnect 会再次校验 reservation_id + local_token（双保险）。
func (s *Server) connectRelayData(w http.ResponseWriter, r *http.Request) {
	reservationID := r.PathValue("reservation_id")
	if !validReservationID(reservationID) {
		http.Error(w, "invalid reservation id", http.StatusNotFound)
		return
	}
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
	grace := time.Duration(v2.RESERVATION_EXPIRY_GRACE_S) * time.Second
	if time.Now().After(time.UnixMilli(res.ExpiresAtMs).Add(grace)) {
		http.Error(w, "reservation expired", http.StatusGone)
		return
	}
	if !validRelayToken(r, res) {
		http.Error(w, "invalid reservation token", http.StatusUnauthorized)
		return
	}
	connection, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	// 不在升级阶段登记：只有首帧 RelayDataConnect 通过校验后才进入 registry（避免
	// 把自身当成等待对端）。未发 Connect 的已升级连接不占 pending 容量。
	rc := newRelayDataConn(&s.relayData, res, connection, s.config)
	go rc.write()
	go rc.read()
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
	token := r.URL.Query().Get("token")
	if token == "" {
		token = r.Header.Get("X-Relay-Token")
	}
	if token == "" {
		return false
	}
	raw, err := hex.DecodeString(token)
	if err != nil {
		return false
	}
	return bytes.Equal(raw, res.InitiatorToken) || bytes.Equal(raw, res.ResponderToken)
}
