// Relay Data reservation model and shared TTL storage（设计 §25）。
//
// Reservation 是「Direct 失败后走 Relay」的短命数据通道凭证：发起方 A 通过 /v2/control
// 发 RelayReserveRequest，服务端创建 reservation（Redis relay:reservation:{id}，
// TTL=expires_at），给 A 回 RelayReserveResponse、给 B 推 IncomingRelayReservation；
// 双方随后各自连接 /v2/relay/{reservation_id}。本文件拥有 reservation 数据模型、
// Resolve→Offer→Reserve 的有界一次性授权、lifetime 规则和 memory/Redis 存储；HTTP
// 升级准入、one-shot 配对与 socket pump 分属独立 owner，且都不能解析
// encrypted_payload（ADR-017 边界）。

package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

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

// errReservationCapacity reports that all configured live reservation slots
// are occupied. Callers map it to a stable rate/resource-limit response.
var errReservationCapacity = errors.New("relay reservation capacity reached")

var errReservationExists = errors.New("relay reservation already exists")

const (
	defaultMaxRelayReservationGates        = 65536
	defaultMaxRelayReservationGatesPerConn = 64
)

// relayReservationGateRegistry owns the short-lived authorization between a
// successfully forwarded ConnectivityOffer and one RelayReserveRequest. It is
// deliberately separate from the attempt return-routing registry: an Answer or
// ProtocolError consumes its route without consuming Relay fallback authority.
// Callers serialize this registry with the Hub mutex.
type relayReservationGateRegistry struct {
	gates        map[relayReservationGateKey]relayReservationGate
	byConnection map[string]map[relayReservationGateKey]struct{}
	expiries     expiryIndex[relayReservationGateKey]
	maxTotal     int
	maxPerConn   int
}

type relayReservationGateKey struct {
	initiatorConnectionID string
	attemptID             string
}

type relayReservationGate struct {
	initiatorDeviceID     string
	initiatorConnectionID string
	targetDeviceID        string
	targetConnectionID    string
	expiresAt             time.Time
}

func newRelayReservationGateRegistry(maxTotal, maxPerConn int) relayReservationGateRegistry {
	if maxTotal <= 0 {
		maxTotal = defaultMaxRelayReservationGates
	}
	if maxPerConn <= 0 {
		maxPerConn = defaultMaxRelayReservationGatesPerConn
	}
	return relayReservationGateRegistry{
		gates:        make(map[relayReservationGateKey]relayReservationGate),
		byConnection: make(map[string]map[relayReservationGateKey]struct{}),
		maxTotal:     maxTotal,
		maxPerConn:   maxPerConn,
	}
}

func (r *relayReservationGateRegistry) ensure() {
	if r.gates == nil {
		r.gates = make(map[relayReservationGateKey]relayReservationGate)
	}
	if r.byConnection == nil {
		r.byConnection = make(map[string]map[relayReservationGateKey]struct{})
	}
	if r.maxTotal <= 0 {
		r.maxTotal = defaultMaxRelayReservationGates
	}
	if r.maxPerConn <= 0 {
		r.maxPerConn = defaultMaxRelayReservationGatesPerConn
	}
}

func (r *relayReservationGateRegistry) remove(key relayReservationGateKey) {
	gate, present := r.gates[key]
	if present {
		delete(r.gates, key)
		for _, connectionID := range []string{key.initiatorConnectionID, gate.targetConnectionID} {
			if connectionID == "" {
				continue
			}
			refs := r.byConnection[connectionID]
			delete(refs, key)
			if len(refs) == 0 {
				delete(r.byConnection, connectionID)
			}
		}
	}
	r.expiries.remove(key)
}

func (r *relayReservationGateRegistry) prune(now time.Time, limit int) int {
	pruned := 0
	for pruned < limit {
		key, expired := r.expiries.oldestExpired(now)
		if !expired {
			break
		}
		r.remove(key)
		pruned++
	}
	return pruned
}

func (r *relayReservationGateRegistry) contains(key relayReservationGateKey, now time.Time) bool {
	gate, present := r.gates[key]
	if present && !now.Before(gate.expiresAt) {
		r.remove(key)
		return false
	}
	return present
}

func (r *relayReservationGateRegistry) add(attemptID string, gate relayReservationGate, now time.Time) bool {
	if attemptID == "" || gate.initiatorDeviceID == "" || gate.targetDeviceID == "" ||
		gate.initiatorConnectionID == "" || gate.targetConnectionID == "" || !now.Before(gate.expiresAt) {
		return false
	}
	r.ensure()
	key := relayReservationGateKey{initiatorConnectionID: gate.initiatorConnectionID, attemptID: attemptID}
	if r.contains(key, now) {
		return false
	}
	if len(r.gates) >= r.maxTotal {
		// Recover exactly one expired global slot. The indexed heap means this
		// remains O(log n), independent of the number of live gates.
		r.prune(now, 1)
		if len(r.gates) >= r.maxTotal {
			return false
		}
	}
	connectionIDs := []string{gate.initiatorConnectionID}
	if gate.targetConnectionID != gate.initiatorConnectionID {
		connectionIDs = append(connectionIDs, gate.targetConnectionID)
	}
	for _, connectionID := range connectionIDs {
		if len(r.byConnection[connectionID]) >= r.maxPerConn &&
			!r.releaseExpiredSlotForConnection(connectionID, now) {
			return false
		}
	}
	r.gates[key] = gate
	if !r.expiries.add(key, gate.expiresAt) {
		delete(r.gates, key)
		return false
	}
	for _, connectionID := range connectionIDs {
		refs := r.byConnection[connectionID]
		if refs == nil {
			refs = make(map[relayReservationGateKey]struct{})
			r.byConnection[connectionID] = refs
		}
		refs[key] = struct{}{}
	}
	return true
}

// releaseExpiredSlotForConnection examines only one reverse-index bucket. The
// bucket is capped at maxPerConn (64 in production), avoiding a global scan
// when one busy connection reaches its own limit before the registry is full.
func (r *relayReservationGateRegistry) releaseExpiredSlotForConnection(connectionID string, now time.Time) bool {
	refs := r.byConnection[connectionID]
	checked := 0
	for key := range refs {
		if checked >= r.maxPerConn {
			break
		}
		checked++
		gate, present := r.gates[key]
		if !present || !now.Before(gate.expiresAt) {
			r.remove(key)
			break
		}
	}
	return len(r.byConnection[connectionID]) < r.maxPerConn
}

// take removes a gate before returning it, including an expired one. A
// malformed or replayed request cannot retain or probe live authorization.
func (r *relayReservationGateRegistry) take(key relayReservationGateKey, now time.Time) (relayReservationGate, bool) {
	gate, present := r.gates[key]
	if present {
		r.remove(key)
	}
	if !present || !now.Before(gate.expiresAt) {
		return relayReservationGate{}, false
	}
	return gate, true
}

func (r *relayReservationGateRegistry) removeConnection(connectionID string) {
	refs := r.byConnection[connectionID]
	if len(refs) == 0 {
		return
	}
	keys := make([]relayReservationGateKey, 0, len(refs))
	for key := range refs {
		keys = append(keys, key)
	}
	for _, key := range keys {
		r.remove(key)
	}
}

func (r *relayReservationGateRegistry) reset() {
	r.gates = make(map[relayReservationGateKey]relayReservationGate)
	r.byConnection = make(map[string]map[relayReservationGateKey]struct{})
	r.expiries.reset()
}

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
)

// ---------------------------------------------------------------------------
// Reservation 存储：memoryStore（cache.go 同锁 mu）
// ---------------------------------------------------------------------------

func (m *memoryStore) CreateReservation(_ context.Context, r Reservation) error {
	if r.ReservationID == "" {
		return fmt.Errorf("reservation id is empty")
	}
	expiresAt := reservationHardExpiry(r.ExpiresAtMs)
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	if !expiresAt.After(now) {
		return errors.New("relay reservation expires beyond the grace window")
	}
	for id, entry := range m.reservations {
		if !now.Before(entry.expiresAt) {
			delete(m.reservations, id)
		}
	}
	if _, exists := m.reservations[r.ReservationID]; exists {
		return errReservationExists
	}
	if len(m.reservations) >= m.maxReservations {
		return errReservationCapacity
	}
	m.reservations[r.ReservationID] = reservationEntry{
		reservation: r,
		expiresAt:   expiresAt,
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

func (r *redisStore) reservationIndexKey() string {
	return redisKeyPrefix + "reservations"
}

const createReservationScript = `
local ttl = tonumber(ARGV[2]) - tonumber(ARGV[1])
if ttl <= 0 then
  return -2
end
redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', ARGV[1])
if redis.call('EXISTS', KEYS[2]) == 1 then
  return -1
end
if redis.call('ZCARD', KEYS[1]) >= tonumber(ARGV[3]) then
  return 0
end
redis.call('SET', KEYS[2], ARGV[4], 'PX', ttl, 'NX')
redis.call('ZADD', KEYS[1], ARGV[2], ARGV[5])
return 1
`

func (r *redisStore) CreateReservation(ctx context.Context, res Reservation) error {
	data, err := json.Marshal(res)
	if err != nil {
		return err
	}
	// Redis TTL 也带宽限：条目保留到硬到期时刻，宽限内仍可被升级接受。
	expiresAt := reservationHardExpiry(res.ExpiresAtMs)
	now := time.Now()
	if !expiresAt.After(now) {
		return errors.New("relay reservation expires beyond the grace window")
	}
	result, err := r.client.Eval(ctx, createReservationScript,
		[]string{r.reservationIndexKey(), r.reservationKey(res.ReservationID)},
		now.UnixMilli(), expiresAt.UnixMilli(), r.maxReservations, string(data), res.ReservationID,
	).Int()
	if err != nil {
		return err
	}
	switch result {
	case 1:
		return nil
	case 0:
		return errReservationCapacity
	case -1:
		return errReservationExists
	default:
		return errors.New("relay reservation expires beyond the grace window")
	}
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
	return r.client.Eval(ctx, `
redis.call('DEL', KEYS[1])
redis.call('ZREM', KEYS[2], ARGV[1])
return 1
`, []string{r.reservationKey(reservationID), r.reservationIndexKey()}, reservationID).Err()
}

// RenewReservation 把 reservation 键的 TTL 滑动到 now+ttl（滑动窗口续期，数据面流量
// 到来时调用）。键不存在（已过期被 Redis 主动清除）时返回 false。
func (r *redisStore) RenewReservation(ctx context.Context, reservationID string, ttl time.Duration) (bool, error) {
	if ttl <= 0 {
		return false, nil
	}
	expiresAt := time.Now().Add(ttl)
	result, err := r.client.Eval(ctx, `
if redis.call('EXISTS', KEYS[1]) == 0 then
  redis.call('ZREM', KEYS[2], ARGV[2])
  return 0
end
redis.call('PEXPIRE', KEYS[1], ARGV[1])
redis.call('ZADD', KEYS[2], ARGV[3], ARGV[2])
return 1
`, []string{r.reservationKey(reservationID), r.reservationIndexKey()},
		ttl.Milliseconds(), reservationID, expiresAt.UnixMilli()).Int()
	if err != nil {
		return false, err
	}
	return result == 1, nil
}
