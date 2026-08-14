// Ephemeral device-plane state: replay-protection nonces.
//
// Phase 0 ships the in-memory implementation, which reproduces the existing
// per-device nonce map and 128-entry cap exactly. Phase 2 adds the Redis-backed
// store behind the same contract so nonce state is shared across instances and
// gained presence, admin-session and transfer-session keys.
//
// As with Storage, every method must be called while the caller holds
// s.devicesMutex.

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

// Presence 是跨实例共享的设备在线状态。
type Presence struct {
	InstanceID string    `json:"instance_id"`
	RemoteAddr string    `json:"remote_addr,omitempty"`
	LastSeen   time.Time `json:"last_seen"`
}

// presenceEntry 是内存实现的在线条目，带显式过期时间（内存模式无 Redis TTL）。
type presenceEntry struct {
	presence  Presence
	expiresAt time.Time
}

// Cache 是短期、可重建状态的契约。
//
// 锁约定：ConsumeNonce/ClearDeviceNonces 必须在持有 s.devicesMutex 时调用（与
// enrollment/吊销复合操作的原子性绑定）；presence 与 admin 会话方法自同步，可由
// hub goroutine 与管理端处理器在设备平面锁之外调用。
type Cache interface {
	// ConsumeNonce 原子记录 deviceID 的 nonce；若该 nonce 已存在（重放）返回 true。
	// expiresAt 是 nonce 的有效上界；内存与 Redis 实现均遵守每设备活跃 nonce 上限
	// （已过期 nonce 惰性清理，上限只统计活跃 nonce）。
	ConsumeNonce(ctx context.Context, deviceID, nonce string, expiresAt time.Time) (bool, error)
	// ClearDeviceNonces 清除 deviceID 的全部 nonce（重新 enroll / 吊销时调用）。
	ClearDeviceNonces(ctx context.Context, deviceID string) error
	// SetPresence 写入/续期 deviceID 的在线状态，ttl 后自动过期。
	SetPresence(ctx context.Context, deviceID string, p Presence, ttl time.Duration) error
	// GetPresence 返回 deviceID 的在线状态与存在性。
	GetPresence(ctx context.Context, deviceID string) (Presence, bool, error)
	// DeletePresence 清除 deviceID 的在线状态（断连时调用）。
	DeletePresence(ctx context.Context, deviceID string) error
	// SetAdminSession 创建 TTL 管理的管理端会话。内存实现在容量耗尽时返回
	// errAdminSessionCapacity（fail closed）。
	SetAdminSession(ctx context.Context, token string, ttl time.Duration) error
	// AdminSessionExists 报告管理端会话是否仍然有效。
	AdminSessionExists(ctx context.Context, token string) (bool, error)
	// DeleteAdminSession 删除管理端会话。
	DeleteAdminSession(ctx context.Context, token string) error
	// Publish 广播一个跨实例事件。内存实现为空操作（事件在本地直接处理）。
	Publish(ctx context.Context, event RelayEvent) error
	// Close 释放缓存持有的外部资源（Redis 连接等）；内存实现为空操作。
	Close() error
}

func (m *memoryStore) ConsumeNonce(_ context.Context, deviceID, nonce string, expiresAt time.Time) (bool, error) {
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
	delete(m.proofNonces, deviceID)
	return nil
}

func (m *memoryStore) SetPresence(_ context.Context, deviceID string, p Presence, ttl time.Duration) error {
	m.mu.Lock()
	m.presence[deviceID] = presenceEntry{presence: p, expiresAt: time.Now().Add(ttl)}
	m.mu.Unlock()
	return nil
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

func (m *memoryStore) DeletePresence(_ context.Context, deviceID string) error {
	m.mu.Lock()
	delete(m.presence, deviceID)
	m.mu.Unlock()
	return nil
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
