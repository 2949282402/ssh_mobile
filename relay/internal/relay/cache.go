// Ephemeral device-plane state: replay-protection nonces.
//
// Phase 0 ships the in-memory implementation, which reproduces the existing
// per-device nonce map and 128-entry cap exactly. Phase 2 adds the Redis-backed
// store behind the same contract so nonce state is shared across instances and
// gained presence, admin-session and transfer-session keys.
//
// As with Storage, individual methods are internally synchronized; composite
// device operations that span nonce consumption plus enrollment/revocation are
// serialized by the caller's per-device lock stripe (s.lockDevice).

package relay

import (
	"context"
	"errors"
	"time"
)

// maxProofNoncesPerDevice bounds the number of active proof nonces kept per
// device, matching the pre-abstraction in-memory cap.
const maxProofNoncesPerDevice = 128

// errAdminSessionCapacity reports that the in-memory administrator session
// store is full. Redis mode has no hard cap (login rate limiting and TTL bound
// it instead), so only the memory implementation returns this error.
var errAdminSessionCapacity = errors.New("administrator session capacity reached")

// errDiscoveryNotOwner reports that a discovery write was rejected because the
// writer is not the device's current presence lease owner. Presence ownership
// is the single source of truth for which connection may publish discovery
// (Redis Lua + memory store share this CAS contract), so a superseded
// connection can never overwrite the newer connection's discovery.
var errDiscoveryNotOwner = errors.New("discovery write rejected: connection is not the presence owner")

// Presence 是跨实例共享的设备在线状态。它同时是一份带所有权的租约：
// ConnectionID 唯一标识当前持有该设备在线租约的那条连接，后续续租（心跳）与
// 释放（断连）都必须携带它做 CAS，跨实例时旧连接不会误删新连接的在线状态。
type Presence struct {
	InstanceID   string    `json:"instance_id"`
	ConnectionID string    `json:"connection_id"`
	RemoteAddr   string    `json:"remote_addr,omitempty"`
	LastSeen     time.Time `json:"last_seen"`
}

// presenceEntry 是内存实现的在线条目，带显式过期时间（内存模式无 Redis TTL）。
type presenceEntry struct {
	presence  Presence
	expiresAt time.Time
}

// Cache 是短期、可重建状态的契约。
//
// 锁约定：非 nonce 方法内部自同步，可由 hub goroutine 与管理端处理器直接调用；
// ConsumeNonce/ClearDeviceNonces 用 memoryStore 的 deviceMu 自同步（Redis 模式并发
// 安全），同设备复合操作（enroll/吊销）的原子性由调用方的 per-device 分片锁保证。
type Cache interface {
	// ConsumeNonce 原子记录 deviceID 的 nonce；若该 nonce 已存在（重放）返回 true。
	// expiresAt 是 nonce 的有效上界；内存与 Redis 实现均遵守每设备活跃 nonce 上限
	// （已过期 nonce 惰性清理，上限只统计活跃 nonce）。
	ConsumeNonce(ctx context.Context, deviceID, nonce string, expiresAt time.Time) (bool, error)
	// ClearDeviceNonces 清除 deviceID 的全部 nonce（重新 enroll / 吊销时调用）。
	ClearDeviceNonces(ctx context.Context, deviceID string) error
	// TakePresence 让 connID 无条件取得 deviceID 的 presence 租约：新连接抢占，
	// 最新落盘者成为在线所有者（最后写者胜），ttl 后租约自动过期。返回被取代的
	// 上一份租约（replaced=true 表示存在上一 owner），调用方据此向旧实例发布
	// connection.replaced 事件，定向断开被取代的连接（立即替换而非等心跳收敛）。
	TakePresence(ctx context.Context, deviceID, connID string, p Presence, ttl time.Duration) (Presence, bool, error)
	// RenewPresence 仅当 connID 仍是租约所有者（或租约不存在/已过期）时续期并返回
	// true；返回 false 表示所有权已被其它连接抢走，调用方（本连接）已被取代、
	// 应自愈关闭。
	RenewPresence(ctx context.Context, deviceID, connID string, p Presence, ttl time.Duration) (bool, error)
	// ReleasePresence 仅当 connID 仍是所有者时释放租约（CAS 删除），返回是否真的
	// 释放；租约不存在或归其它连接所有时返回 false（旧连接不会误删新连接）。
	ReleasePresence(ctx context.Context, deviceID, connID string) (bool, error)
	// GetPresence 返回 deviceID 的在线状态与存在性。
	GetPresence(ctx context.Context, deviceID string) (Presence, bool, error)
	// GetPresences 批量返回多个 deviceID 的在线租约：结果 map 中存在的 key 即在线，
	// 缺失/已过期的设备不在 map 中；空列表返回空 map。admin 快照用它把 N 次
	// GetPresence 收敛成一次往返。
	GetPresences(ctx context.Context, deviceIDs []string) (map[string]Presence, error)
	// TakeDiscovery 仅当 connID 仍是该设备 presence 租约的当前 owner 时写入
	// discovery（CAS，Redis Lua 原子 + 内存实现同构）：presence 所有权是"哪条连接
	// 有权发布 discovery"的唯一权威，被取代的旧连接不可能把新连接的 discovery 覆盖
	// 回自身。ttl 后自动过期，与 presence 生命周期绑定（TTL 相同、心跳同时续期、
	// 断开同时释放）。落盘的 ConnectionID 强制为 connID。返回 errDiscoveryNotOwner
	// 表示 connID 不是当前 presence owner（已被同设备的新连接取代）。
	TakeDiscovery(ctx context.Context, deviceID, connID string, d Discovery, ttl time.Duration) error
	// RenewDiscovery 仅当 connID 仍是 discovery 所有者时续期（CAS，只续 TTL 不覆写
	// 内容），返回 false 表示所有权已被其它连接抢走。
	RenewDiscovery(ctx context.Context, deviceID, connID string, ttl time.Duration) (bool, error)
	// ReleaseDiscovery 仅当 connID 仍是所有者时释放 discovery（CAS 删除），返回是否
	// 真的释放；不存在或归其它连接所有时返回 false。
	ReleaseDiscovery(ctx context.Context, deviceID, connID string) (bool, error)
	// GetDiscovery 返回 deviceID 的 discovery 状态与存在性。
	GetDiscovery(ctx context.Context, deviceID string) (Discovery, bool, error)
	// GetDiscoveries 批量返回多个 deviceID 的 discovery：结果 map 中存在的 key 即
	// 有效，缺失/已过期的设备不在 map 中；空列表返回空 map。
	GetDiscoveries(ctx context.Context, deviceIDs []string) (map[string]Discovery, error)
	// ListOnlinePeers 返回全部在线设备的 discovery（按明确版 §13，presence 与
	// discovery 均有效的设备才计入）。用于 presence_snapshot 构建与 sweeper 判活。
	ListOnlinePeers(ctx context.Context) (map[string]Discovery, error)
	// SetAdminSession 创建 TTL 管理的管理端会话。内存实现在容量耗尽时返回
	// errAdminSessionCapacity（fail closed）。
	SetAdminSession(ctx context.Context, token string, ttl time.Duration) error
	// AdminSessionExists 报告管理端会话是否仍然有效。
	AdminSessionExists(ctx context.Context, token string) (bool, error)
	// DeleteAdminSession 删除管理端会话。
	DeleteAdminSession(ctx context.Context, token string) error
	// CreateReservation 原子存储一条 relay-data reservation（设计 §25，Redis
	// relay:reservation:{id}），TTL 到 expires_at_ms。
	CreateReservation(ctx context.Context, r Reservation) error
	// GetReservation 返回 reservation；不存在或已过期返回 (zero, false, nil)。
	GetReservation(ctx context.Context, reservationID string) (Reservation, bool, error)
	// DeleteReservation 删除 reservation（双方关闭后清理）。
	DeleteReservation(ctx context.Context, reservationID string) error
	// Publish 广播一个跨实例事件。内存实现为空操作（事件在本地直接处理）。
	Publish(ctx context.Context, event RelayEvent) error
	// Close 释放缓存持有的外部资源（Redis 连接等）；内存实现为空操作。
	Close() error
}

func (m *memoryStore) ConsumeNonce(_ context.Context, deviceID, nonce string, expiresAt time.Time) (bool, error) {
	m.deviceMu.Lock()
	defer m.deviceMu.Unlock()
	now := time.Now()
	deviceNonces := m.proofNonces[deviceID]
	if deviceNonces == nil {
		deviceNonces = make(map[string]time.Time)
		m.proofNonces[deviceID] = deviceNonces
	}
	for value, expiry := range deviceNonces {
		if now.After(expiry) {
			delete(deviceNonces, value)
		}
	}
	if _, exists := deviceNonces[nonce]; exists {
		return true, nil
	}
	if len(deviceNonces) >= maxProofNoncesPerDevice {
		return true, nil
	}
	deviceNonces[nonce] = expiresAt
	return false, nil
}

func (m *memoryStore) ClearDeviceNonces(_ context.Context, deviceID string) error {
	m.deviceMu.Lock()
	defer m.deviceMu.Unlock()
	delete(m.proofNonces, deviceID)
	return nil
}

func (m *memoryStore) TakePresence(_ context.Context, deviceID, connID string, p Presence, ttl time.Duration) (Presence, bool, error) {
	p.ConnectionID = connID
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	var previous Presence
	replaced := false
	if entry, present := m.presence[deviceID]; present {
		if now.Before(entry.expiresAt) {
			previous = entry.presence
			replaced = true
		} else {
			// 过期租约视为缺失（与 Redis GET 对过期 key 返回 nil 等价）。
			delete(m.presence, deviceID)
		}
	}
	m.presence[deviceID] = presenceEntry{presence: p, expiresAt: now.Add(ttl)}
	return previous, replaced, nil
}

// RenewPresence 在 m.mu 下复刻 Redis 的 CAS 语义：存在的活跃租约只允许所有者续期，
// 租约不存在或已过期时重新获取成功（过期即缺失，与 Redis GET 对过期 key 返回 nil
// 等价）。落盘的 ConnectionID 一律强制为 connID——connID 参数才是所有权权威，这保证
// 存储层从不产生 owner 为空的租约（否则首次心跳续租会失败并自愈关闭）。
func (m *memoryStore) RenewPresence(_ context.Context, deviceID, connID string, p Presence, ttl time.Duration) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	entry, present := m.presence[deviceID]
	if present && now.Before(entry.expiresAt) && entry.presence.ConnectionID != connID {
		return false, nil
	}
	p.ConnectionID = connID
	m.presence[deviceID] = presenceEntry{presence: p, expiresAt: now.Add(ttl)}
	return true, nil
}

// ReleasePresence 在 m.mu 下复刻 Redis 的 CAS 删除：只释放归 connID 所有的活跃租约；
// 不存在或已过期（视为缺失）或归其它连接所有时返回 false 且不删除。
func (m *memoryStore) ReleasePresence(_ context.Context, deviceID, connID string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	entry, present := m.presence[deviceID]
	if !present || !now.Before(entry.expiresAt) {
		// 过期条目顺手剪除（Redis 侧由 TTL 主动过期，无需此步）。
		if present {
			delete(m.presence, deviceID)
		}
		return false, nil
	}
	if entry.presence.ConnectionID != connID {
		return false, nil
	}
	delete(m.presence, deviceID)
	return true, nil
}

func (m *memoryStore) GetPresence(_ context.Context, deviceID string) (Presence, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	entry, present := m.presence[deviceID]
	if !present {
		return Presence{}, false, nil
	}
	if time.Now().After(entry.expiresAt) {
		delete(m.presence, deviceID)
		return Presence{}, false, nil
	}
	return entry.presence, true, nil
}

func (m *memoryStore) GetPresences(_ context.Context, deviceIDs []string) (map[string]Presence, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	result := make(map[string]Presence, len(deviceIDs))
	for _, deviceID := range deviceIDs {
		entry, present := m.presence[deviceID]
		if !present {
			continue
		}
		if now.After(entry.expiresAt) {
			// 过期视为缺失，顺手剪除（与 GetPresence 的惰性清理一致）。
			delete(m.presence, deviceID)
			continue
		}
		result[deviceID] = entry.presence
	}
	return result, nil
}

// TakeDiscovery 在 m.mu 下复刻 Redis 的 CAS 写入：仅当 connID 仍是该设备当前
// presence 租约的 owner 时才落盘（否则返回 errDiscoveryNotOwner）。presence 所有权
// 是"哪条连接有权发布 discovery"的唯一权威——被取代的旧连接（新连接已 TakePresence
// 接管）不可能把新连接的 discovery 覆盖回自身。落盘的 ConnectionID 强制为 connID。
func (m *memoryStore) TakeDiscovery(_ context.Context, deviceID, connID string, d Discovery, ttl time.Duration) error {
	d.ConnectionID = connID
	// 落盘前补齐排序字段：只带 generation（v1）或只带 revision（v2）的写入都产出
	// 完整行，保证 READY 判据（revision>0）对两种来源一致成立。
	normalizeDiscovery(&d)
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	entry, present := m.presence[deviceID]
	if !present || !now.Before(entry.expiresAt) || entry.presence.ConnectionID != connID {
		if present && !now.Before(entry.expiresAt) {
			// 过期租约顺手剪除（与 GetPresence 的惰性清理一致）。
			delete(m.presence, deviceID)
		}
		return errDiscoveryNotOwner
	}
	m.discovery[deviceID] = discoveryEntry{discovery: d, expiresAt: now.Add(ttl)}
	return nil
}

// RenewDiscovery 在 m.mu 下复刻 Redis 的 CAS 续期：只续 TTL、不覆写内容，且仅当
// connID 仍是所有者（或条目不存在/已过期，视为缺失可重新获取）。返回 false 表示
// 所有权已被其它连接抢走。
func (m *memoryStore) RenewDiscovery(_ context.Context, deviceID, connID string, ttl time.Duration) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	entry, present := m.discovery[deviceID]
	if present && now.Before(entry.expiresAt) && entry.discovery.ConnectionID != connID {
		return false, nil
	}
	if present {
		if now.After(entry.expiresAt) {
			// 过期视为缺失，顺手剪除。
			delete(m.discovery, deviceID)
		} else {
			entry.expiresAt = now.Add(ttl)
			m.discovery[deviceID] = entry
		}
	}
	return true, nil
}

// ReleaseDiscovery 在 m.mu 下复刻 Redis 的 CAS 删除：只释放归 connID 所有的活跃
// 条目；不存在或已过期（视为缺失）或归其它连接所有时返回 false 且不删除。
func (m *memoryStore) ReleaseDiscovery(_ context.Context, deviceID, connID string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	entry, present := m.discovery[deviceID]
	if !present || !now.Before(entry.expiresAt) {
		if present {
			delete(m.discovery, deviceID)
		}
		return false, nil
	}
	if entry.discovery.ConnectionID != connID {
		return false, nil
	}
	delete(m.discovery, deviceID)
	return true, nil
}

func (m *memoryStore) GetDiscovery(_ context.Context, deviceID string) (Discovery, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	entry, present := m.discovery[deviceID]
	if !present {
		return Discovery{}, false, nil
	}
	if time.Now().After(entry.expiresAt) {
		delete(m.discovery, deviceID)
		return Discovery{}, false, nil
	}
	return entry.discovery, true, nil
}

func (m *memoryStore) GetDiscoveries(_ context.Context, deviceIDs []string) (map[string]Discovery, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	result := make(map[string]Discovery, len(deviceIDs))
	for _, deviceID := range deviceIDs {
		entry, present := m.discovery[deviceID]
		if !present {
			continue
		}
		if now.After(entry.expiresAt) {
			delete(m.discovery, deviceID)
			continue
		}
		result[deviceID] = entry.discovery
	}
	return result, nil
}

// ListOnlinePeers 返回可在线判定的设备（明确版 §13）：presence 与 discovery 均有效、
// discovery 已可靠发布（ready()：revision>0，v1 由 generation 派生）、且 presence 与
// discovery 的所有者 ConnectionID 一致。占位 discovery 已移除后，revision=0 或 owner
// 不匹配的条目（重连窗口内旧连接的残留 discovery）都不算在线。
func (m *memoryStore) ListOnlinePeers(_ context.Context) (map[string]Discovery, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	result := make(map[string]Discovery)
	for deviceID, entry := range m.discovery {
		if now.After(entry.expiresAt) {
			delete(m.discovery, deviceID)
			continue
		}
		presence, present := m.presence[deviceID]
		if !present || now.After(presence.expiresAt) || presence.presence.ConnectionID != entry.discovery.ConnectionID {
			continue
		}
		if !entry.discovery.ready() {
			continue
		}
		result[deviceID] = entry.discovery
	}
	return result, nil
}

func (m *memoryStore) SetAdminSession(_ context.Context, token string, ttl time.Duration) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	for current, expiresAt := range m.adminSessions {
		if !now.Before(expiresAt) {
			delete(m.adminSessions, current)
		}
	}
	if len(m.adminSessions) >= m.maxAdminSession {
		return errAdminSessionCapacity
	}
	m.adminSessions[token] = now.Add(ttl)
	return nil
}

func (m *memoryStore) AdminSessionExists(_ context.Context, token string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	expiresAt, present := m.adminSessions[token]
	if !present {
		return false, nil
	}
	if time.Now().After(expiresAt) {
		delete(m.adminSessions, token)
		return false, nil
	}
	return true, nil
}

func (m *memoryStore) DeleteAdminSession(_ context.Context, token string) error {
	m.mu.Lock()
	delete(m.adminSessions, token)
	m.mu.Unlock()
	return nil
}

// Publish 内存实现为空操作：事件由本地 hub 直接处理，无需跨实例广播。
func (m *memoryStore) Publish(_ context.Context, _ RelayEvent) error { return nil }
