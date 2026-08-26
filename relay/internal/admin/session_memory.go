// In-memory implementation of SessionStore for single-replica Admin deployments.

package admin

import (
	"context"
	"sync"
	"time"
)

type memorySessionStore struct {
	mu          sync.Mutex
	maxSessions int
	sessions    map[string]time.Time
}

func newMemorySessionStore(maxSessions int) *memorySessionStore {
	return &memorySessionStore{
		maxSessions: maxSessions,
		sessions:    make(map[string]time.Time),
	}
}

func (m *memorySessionStore) Create(_ context.Context, token string, ttl time.Duration) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	now := time.Now()
	// Prune expired sessions
	for k, exp := range m.sessions {
		if !exp.After(now) {
			delete(m.sessions, k)
		}
	}

	if len(m.sessions) >= m.maxSessions {
		return errSessionCapacity
	}

	m.sessions[token] = now.Add(ttl)
	return nil
}

func (m *memorySessionStore) Exists(_ context.Context, token string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	now := time.Now()
	exp, ok := m.sessions[token]
	if !ok {
		return false, nil
	}
	if !exp.After(now) {
		delete(m.sessions, token)
		return false, nil
	}
	return true, nil
}

func (m *memorySessionStore) Delete(_ context.Context, token string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.sessions, token)
	return nil
}

func (m *memorySessionStore) Close() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sessions = make(map[string]time.Time)
	return nil
}
