// Relay Data reservation model and shared TTL storage（设计 §25）。
//
// Reservation 是「Direct 失败后走 Relay」的短命数据通道凭证：发起方 A 通过 /v2/control
// 发 RelayReserveRequest，服务端创建 reservation（Redis relay:reservation:{id}，
// TTL=expires_at），给 A 回 RelayReserveResponse、给 B 推 IncomingRelayReservation；
// 双方随后各自连接 /v2/relay/{reservation_id}。本文件只拥有 reservation 数据模型、
// lifetime 规则和 memory/Redis 存储；HTTP 准入、one-shot 配对与 socket pump 分属独立
// owner，且都不能解析 encrypted_payload（ADR-017 边界）。

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
