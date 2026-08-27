package telemetry

import (
	"container/list"
	"math"
	"sync"
	"time"
)

// Sentinel errors describe admission failures that are safe to expose through
// the public ingest response without leaking store or authentication details.
var (
	ErrIngestOverloaded  = &ingestAdmissionError{code: "INGEST_OVERLOADED", message: "telemetry ingest is temporarily overloaded"}
	ErrIngestRateLimited = &ingestAdmissionError{code: "INGEST_RATE_LIMITED", message: "telemetry ingest rate limit exceeded"}
)

type ingestAdmissionError struct {
	code    string
	message string
}

func (e *ingestAdmissionError) Error() string {
	return e.message
}

func (e *ingestAdmissionError) Code() string {
	return e.code
}

type deviceRateLimitEntry struct {
	deviceID  string
	tokens    float64
	lastSeen  time.Time
	listEntry *list.Element
}

// deviceRateLimiter is a bounded, process-local token bucket keyed only by a
// device identity that has already passed bearer-token verification. It uses an
// LRU list both to cap cardinality and to make idle-entry cleanup bounded; no
// request-controlled map can grow without limit.
type deviceRateLimiter struct {
	mu      sync.Mutex
	config  IngestConfig
	entries map[string]*deviceRateLimitEntry
	order   *list.List
}

func newDeviceRateLimiter(config IngestConfig) *deviceRateLimiter {
	config = normalizeIngestConfig(config)
	return &deviceRateLimiter{
		config:  config,
		entries: make(map[string]*deviceRateLimitEntry, config.RateLimitMaxDevices),
		order:   list.New(),
	}
}

// allow consumes one request token and returns a bounded retry duration when
// the request is rejected. A missing entry is admitted only while the bounded
// device-cardinality table has capacity; active entries are never evicted just
// to admit a new attacker-controlled identity.
func (l *deviceRateLimiter) allow(deviceID string, now time.Time) (bool, time.Duration) {
	if l == nil || deviceID == "" {
		return false, time.Second
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	l.cleanupExpiredLocked(now)

	entry, ok := l.entries[deviceID]
	if !ok {
		if len(l.entries) >= l.config.RateLimitMaxDevices {
			return false, l.retryAfterDuration(l.config.RateLimitDeviceTTL)
		}
		entry = &deviceRateLimitEntry{
			deviceID: deviceID,
			tokens:   float64(l.config.RateLimitCapacity),
			lastSeen: now,
		}
		entry.listEntry = l.order.PushBack(entry)
		l.entries[deviceID] = entry
	} else {
		if now.Before(entry.lastSeen) {
			now = entry.lastSeen
		}
		l.refillLocked(entry, now)
		entry.lastSeen = now
		l.order.MoveToBack(entry.listEntry)
	}

	if entry.tokens < 1 {
		return false, l.retryAfterDuration(l.waitForToken(entry.tokens))
	}
	entry.tokens--
	return true, 0
}

func (l *deviceRateLimiter) refillLocked(entry *deviceRateLimitEntry, now time.Time) {
	if now.After(entry.lastSeen) {
		elapsed := now.Sub(entry.lastSeen).Seconds()
		entry.tokens = math.Min(
			float64(l.config.RateLimitCapacity),
			entry.tokens+elapsed*l.config.RateLimitRefillPerSec,
		)
	}
}

func (l *deviceRateLimiter) waitForToken(tokens float64) time.Duration {
	missing := 1 - tokens
	if missing <= 0 {
		return 0
	}
	seconds := missing / l.config.RateLimitRefillPerSec
	return time.Duration(math.Ceil(seconds * float64(time.Second)))
}

func (l *deviceRateLimiter) retryAfterDuration(wait time.Duration) time.Duration {
	max := time.Duration(l.config.RetryAfterSeconds) * time.Second
	if wait <= 0 {
		wait = time.Second
	}
	if wait > max {
		return max
	}
	return wait
}

func (l *deviceRateLimiter) cleanupExpiredLocked(now time.Time) {
	for element := l.order.Front(); element != nil; {
		next := element.Next()
		entry := element.Value.(*deviceRateLimitEntry)
		if now.Sub(entry.lastSeen) < l.config.RateLimitDeviceTTL {
			// Entries are ordered by last activity, so later entries are also
			// within the TTL while the production clock moves forward.
			break
		}
		delete(l.entries, entry.deviceID)
		l.order.Remove(element)
		element = next
	}
}

func (l *deviceRateLimiter) entryCount() int {
	if l == nil {
		return 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.entries)
}
