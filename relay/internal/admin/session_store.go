// Administrator session store interface.

package admin

import (
	"context"
	"errors"
	"time"
)

var (
	errSessionCapacity = errors.New("admin session store at capacity")
)

// SessionStore manages active administrator session tokens.
type SessionStore interface {
	// Create stores a new session token with the given TTL.
	Create(ctx context.Context, token string, ttl time.Duration) error
	// Exists checks if a session token is active and unexpired.
	Exists(ctx context.Context, token string) (bool, error)
	// Delete removes a session token (on logout).
	Delete(ctx context.Context, token string) error
	// Close releases any resources held by the session store.
	Close() error
}
