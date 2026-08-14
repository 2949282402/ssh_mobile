// Device-plane durable state: enrollment and revocation.
//
// Phase 0 ships the in-memory implementation, which reproduces the pre-existing
// process-local maps exactly. Phase 1 adds the MySQL-backed store behind the
// same contract so enrollment and revocation survive a restart.
//
// Locking note: every method here must be called while the caller holds
// s.devicesMutex. The memory store is not internally synchronized because the
// current device-plane critical sections span enrollment, revocation and nonce
// state as one unit; a single external lock keeps that atomicity. The MySQL
// store (Phase 1) executes database access under the same lock, which is
// acceptable for a control plane whose device count is bounded by configuration.

package relay

import (
	"context"
	"sync"
	"time"
)

// Storage 是设备长期状态（enrollment 与吊销）的持久化契约。
type Storage interface {
	// GetEnrollment 返回 deviceID 的 enrollment；不存在时返回 (nil, nil)。
	GetEnrollment(ctx context.Context, deviceID string) (*EnrolledDevice, error)
	// PutEnrollment 原子写入 enrollment，遵守身份冲突与 MaxEnrolledDevices 容量
	// 边界，并在写入成功后清除该设备的吊销 tombstone（重新 enroll 即解除吊销）。
	PutEnrollment(ctx context.Context, device *EnrolledDevice) (enrollmentResult, error)
	// RemoveEnrollment 删除 deviceID 的 enrollment。
	RemoveEnrollment(ctx context.Context, deviceID string) error
	// RecordRevocation 记录 deviceID 在 validUntil 之前保持吊销。内存实现遵守
	// MaxRevokedDevices 容量边界：饱和且 tombstone 仍有效时拒绝（fail closed），
	// 返回 (false, nil)。
	RecordRevocation(ctx context.Context, deviceID string, validUntil time.Time) (bool, error)
	// RevocationExpiry 返回 deviceID 吊销 tombstone 的上界与存在性，供校验和测试
	// 区分“已清除”与“仍存在但已过期”两种状态。
	RevocationExpiry(ctx context.Context, deviceID string) (time.Time, bool, error)
	// IsRevoked 报告 deviceID 当前是否处于吊销有效期内，并对已过期的 tombstone 做
	// 惰性清理（与既有 authenticatedRequest 路径语义一致）。
	IsRevoked(ctx context.Context, deviceID string, now time.Time) (bool, error)
	// CountEnrollments 返回已 enroll 设备数量。
	CountEnrollments(ctx context.Context) (int, error)
	// ListEnrollments 返回全部 enrollment（管理端快照用）。
	ListEnrollments(ctx context.Context) ([]*EnrolledDevice, error)
	// Close 释放存储持有的外部资源（数据库连接等）；内存实现为空操作。
	Close() error
}

// memoryStore 是 Storage 与 Cache 的内存实现，进程重启即清空，与重构前的 Relay
// 行为一致。它同时实现两个契约：非隔离场景下共享同一份内存与同一把调用方锁，
// 从而保留 enrollment/吊销/nonce 在既有实现中的原子性。
//
// 锁约定：device-plane 方法（enrollment/吊销/nonce）要求调用方持有 devicesMutex，
// 以保留复合操作的原子性；presence 与 admin 会话方法使用内部 m.mu 自同步，因为
// 它们由 hub goroutine 与管理端处理器在设备平面锁之外调用。
type memoryStore struct {
	enrolledDevices map[string]*EnrolledDevice
	revokedDevices  map[string]revokedDevice
	proofNonces     map[string]map[string]time.Time
	presence        map[string]presenceEntry
	adminSessions   map[string]time.Time
	maxEnrolled     int
	maxRevoked      int
	maxAdminSession int
	mu              sync.Mutex
}

// newMemoryStore 构造以给定配置容量为边界的内存存储。
func newMemoryStore(config Config) *memoryStore {
	return &memoryStore{
		enrolledDevices: make(map[string]*EnrolledDevice),
		revokedDevices:  make(map[string]revokedDevice),
		proofNonces:     make(map[string]map[string]time.Time),
		presence:        make(map[string]presenceEntry),
		adminSessions:   make(map[string]time.Time),
		maxEnrolled:     config.MaxEnrolledDevices,
		maxRevoked:      config.MaxRevokedDevices,
		maxAdminSession: config.MaxAdminSessions,
	}
}

func (m *memoryStore) GetEnrollment(_ context.Context, deviceID string) (*EnrolledDevice, error) {
	return m.enrolledDevices[deviceID], nil
}

func (m *memoryStore) PutEnrollment(_ context.Context, device *EnrolledDevice) (enrollmentResult, error) {
	existing, exists := m.enrolledDevices[device.DeviceID]
	if exists {
		if existing.PublicKey != device.PublicKey {
			return enrollmentIdentityConflict, nil
		}
	} else if len(m.enrolledDevices) >= m.maxEnrolled {
		return enrollmentResourceLimit, nil
	}
	m.enrolledDevices[device.DeviceID] = device
	delete(m.revokedDevices, device.DeviceID)
	return enrollmentOK, nil
}

func (m *memoryStore) RemoveEnrollment(_ context.Context, deviceID string) error {
	delete(m.enrolledDevices, deviceID)
	return nil
}

func (m *memoryStore) RecordRevocation(_ context.Context, deviceID string, validUntil time.Time) (bool, error) {
	now := time.Now()
	m.pruneExpiredRevocations(now)
	if existing, alreadyRevoked := m.revokedDevices[deviceID]; alreadyRevoked {
		if validUntil.After(existing.expiresAt) {
			m.revokedDevices[deviceID] = revokedDevice{expiresAt: validUntil}
		}
		return true, nil
	}
	if len(m.revokedDevices) >= m.maxRevoked {
		return false, nil
	}
	m.revokedDevices[deviceID] = revokedDevice{expiresAt: validUntil}
	return true, nil
}

func (m *memoryStore) RevocationExpiry(_ context.Context, deviceID string) (time.Time, bool, error) {
	entry, present := m.revokedDevices[deviceID]
	if !present {
		return time.Time{}, false, nil
	}
	return entry.expiresAt, true, nil
}

func (m *memoryStore) IsRevoked(_ context.Context, deviceID string, now time.Time) (bool, error) {
	entry, present := m.revokedDevices[deviceID]
	if !present {
		return false, nil
	}
	if !now.Before(entry.expiresAt) {
		// The tombstone's recorded expiry is an upper bound on the credential
		// expiry, so once it has passed the credential is already rejected by
		// verifyCredential; dropping the stale tombstone cannot reauthorize a
		// still-revoked credential.
		delete(m.revokedDevices, deviceID)
		return false, nil
	}
	return true, nil
}

func (m *memoryStore) CountEnrollments(_ context.Context) (int, error) {
	return len(m.enrolledDevices), nil
}

func (m *memoryStore) ListEnrollments(_ context.Context) ([]*EnrolledDevice, error) {
	items := make([]*EnrolledDevice, 0, len(m.enrolledDevices))
	for _, device := range m.enrolledDevices {
		items = append(items, device)
	}
	return items, nil
}

// Close 内存实现为空操作（无外部资源）。
func (m *memoryStore) Close() error { return nil }

// pruneExpiredRevocations removes tombstones whose protected credentials have
// expired, freeing capacity before a new revocation is recorded.
func (m *memoryStore) pruneExpiredRevocations(now time.Time) {
	for id, entry := range m.revokedDevices {
		if !now.Before(entry.expiresAt) {
			delete(m.revokedDevices, id)
		}
	}
}
