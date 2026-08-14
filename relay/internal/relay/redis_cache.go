// Redis-backed Cache: shared nonce, presence, administrator session and event
// bus. Phase 2 activates this when RELAY_REDIS_URL is set alongside mysql
// storage; it is the cross-instance state layer for the multi-instance design.

package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

const redisKeyPrefix = "relay:"

// redisStore implements Cache against Redis. go-redis clients are
// concurrent-safe, so no internal lock is needed. Key TTLs carry the expiry
// semantics that the memory store tracks explicitly.
type redisStore struct {
	client *redis.Client
}

// openRedisStore parses RELAY_REDIS_URL (accepting either a redis:// URL or a
// bare host:port) and verifies connectivity.
func openRedisStore(ctx context.Context, url string) (*redisStore, error) {
	opts, err := redis.ParseURL(url)
	if err != nil {
		opts, err = redis.ParseURL("redis://" + url)
		if err != nil {
			return nil, fmt.Errorf("invalid RELAY_REDIS_URL: %w", err)
		}
	}
	client := redis.NewClient(opts)
	if err := client.Ping(ctx).Err(); err != nil {
		_ = client.Close()
		return nil, err
	}
	return &redisStore{client: client}, nil
}

// Close 释放 Redis 连接。
func (r *redisStore) Close() error { return r.client.Close() }

func (r *redisStore) presenceKey(deviceID string) string {
	return redisKeyPrefix + "presence:" + deviceID
}
func (r *redisStore) noncesKey(deviceID string) string {
	return redisKeyPrefix + "nonces:" + deviceID
}
func (r *redisStore) adminSessionKey(token string) string {
	return redisKeyPrefix + "admin:session:" + token
}

// consumeNonceScript atomically records a nonce and enforces the per-device
// active-nonce cap using one ZSET per device. KEYS[1]=relay:nonces:<deviceID>;
// ARGV[1]=now(ms), ARGV[2]=expiresAt(ms), ARGV[3]=cap, ARGV[4]=nonce.
// Returns 1 when replayed or over the cap, else 0. Members expire with the
// credential (score = expiry ms) and are pruned by score on each call, matching
// the memory store's lazy pruning — so the cap counts only *active* nonces, not
// cumulative ones since the last ClearDeviceNonces. The key-level TTL tracks the
// longest-lived member so a later long-lived nonce is never dropped by an
// earlier shorter TTL. A stale SET from the pre-ZSET version is cleared inline
// so an upgrade recovers without waiting for a re-enroll.
const consumeNonceScript = `
local ttl = tonumber(ARGV[2]) - tonumber(ARGV[1])
if ttl <= 0 then
  return 0
end
if redis.call('TYPE', KEYS[1]).ok == 'set' then
  redis.call('DEL', KEYS[1])
end
redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', ARGV[1])
if redis.call('ZSCORE', KEYS[1], ARGV[4]) ~= false then
  return 1
end
if redis.call('ZCARD', KEYS[1]) >= tonumber(ARGV[3]) then
  return 1
end
redis.call('ZADD', KEYS[1], ARGV[2], ARGV[4])
local remaining = redis.call('PTTL', KEYS[1])
if remaining > ttl then ttl = remaining end
redis.call('PEXPIRE', KEYS[1], ttl)
return 0
`

func (r *redisStore) ConsumeNonce(ctx context.Context, deviceID, nonce string, expiresAt time.Time) (bool, error) {
	now := time.Now()
	if !expiresAt.After(now) {
		// Already expired: accept without recording (fail open on the edge).
		return false, nil
	}
	result, err := r.client.Eval(ctx, consumeNonceScript,
		[]string{r.noncesKey(deviceID)},
		now.UnixMilli(), expiresAt.UnixMilli(), maxProofNoncesPerDevice, nonce,
	).Int()
	if err != nil {
		return false, err
	}
	return result == 1, nil
}

func (r *redisStore) ClearDeviceNonces(ctx context.Context, deviceID string) error {
	return r.client.Del(ctx, r.noncesKey(deviceID)).Err()
}

// renewPresenceScript renews the presence lease only while connID still owns it
// (CAS). KEYS[1]=relay:presence:<deviceID>; ARGV[1]=connID, ARGV[2]=json,
// ARGV[3]=ttl(ms). Returns 1 when the lease is now held by connID (renewed, or
// acquired because the key was absent/expired), 0 when a different connection
// owns it. A non-JSON value — or a legacy entry without connection_id — is
// treated as foreign (return 0) so it self-heals on the next TakePresence
// instead of being renewed by a non-owner. The GET→compare→SET is atomic inside
// the single script, so concurrent takeovers cannot tear.
const renewPresenceScript = `
if tonumber(ARGV[3]) <= 0 then
  return 1
end
local data = redis.call('GET', KEYS[1])
if data then
  local ok, obj = pcall(cjson.decode, data)
  -- type(obj)=='table' excludes JSON null/primitives (cjson.null is userdata,
  -- indexing it would raise) and treats any non-object value as foreign.
  if ok and type(obj) == 'table' then
    if obj['connection_id'] ~= ARGV[1] then
      return 0
    end
  else
    return 0
  end
end
redis.call('SET', KEYS[1], ARGV[2], 'PX', ARGV[3])
return 1
`

// releasePresenceScript releases the presence lease only while connID still owns
// it (CAS delete). KEYS[1]=relay:presence:<deviceID>; ARGV[1]=connID. Returns 1
// when the lease was deleted, 0 when it was absent or owned by another
// connection — so a superseded connection can never erase a newer one.
const releasePresenceScript = `
local data = redis.call('GET', KEYS[1])
if not data then
  return 0
end
local ok, obj = pcall(cjson.decode, data)
-- type(obj)=='table' excludes JSON null/primitives (see renewPresenceScript).
if ok and type(obj) == 'table' and obj['connection_id'] == ARGV[1] then
  redis.call('DEL', KEYS[1])
  return 1
end
return 0
`

// TakePresence unconditionally establishes connID as the presence lease owner for
// deviceID: the newest authenticated connection wins (last writer wins). The
// stored ConnectionID is forced to connID so the persisted lease always carries
// its owner (a missing owner would make every renewal treat it as foreign and
// self-close the connection).
func (r *redisStore) TakePresence(ctx context.Context, deviceID, connID string, p Presence, ttl time.Duration) error {
	p.ConnectionID = connID
	data, err := json.Marshal(p)
	if err != nil {
		return err
	}
	return r.client.Set(ctx, r.presenceKey(deviceID), data, ttl).Err()
}

func (r *redisStore) RenewPresence(ctx context.Context, deviceID, connID string, p Presence, ttl time.Duration) (bool, error) {
	p.ConnectionID = connID
	data, err := json.Marshal(p)
	if err != nil {
		return false, err
	}
	result, err := r.client.Eval(ctx, renewPresenceScript,
		[]string{r.presenceKey(deviceID)},
		connID, string(data), ttl.Milliseconds(),
	).Int()
	if err != nil {
		return false, err
	}
	return result == 1, nil
}

func (r *redisStore) ReleasePresence(ctx context.Context, deviceID, connID string) (bool, error) {
	result, err := r.client.Eval(ctx, releasePresenceScript,
		[]string{r.presenceKey(deviceID)},
		connID,
	).Int()
	if err != nil {
		return false, err
	}
	return result == 1, nil
}

// forceDeletePresence unconditionally removes a device's presence key, bypassing
// the lease CAS. It exists for test isolation and operator troubleshooting only;
// production disconnect paths always use ReleasePresence so a stale connection
// cannot erase a newer one.
func (r *redisStore) forceDeletePresence(ctx context.Context, deviceID string) error {
	return r.client.Del(ctx, r.presenceKey(deviceID)).Err()
}

func (r *redisStore) GetPresence(ctx context.Context, deviceID string) (Presence, bool, error) {
	data, err := r.client.Get(ctx, r.presenceKey(deviceID)).Bytes()
	if errors.Is(err, redis.Nil) {
		return Presence{}, false, nil
	}
	if err != nil {
		return Presence{}, false, err
	}
	var p Presence
	if err := json.Unmarshal(data, &p); err != nil {
		return Presence{}, false, err
	}
	return p, true, nil
}

func (r *redisStore) SetAdminSession(ctx context.Context, token string, ttl time.Duration) error {
	return r.client.Set(ctx, r.adminSessionKey(token), "1", ttl).Err()
}

func (r *redisStore) AdminSessionExists(ctx context.Context, token string) (bool, error) {
	n, err := r.client.Exists(ctx, r.adminSessionKey(token)).Result()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

func (r *redisStore) DeleteAdminSession(ctx context.Context, token string) error {
	return r.client.Del(ctx, r.adminSessionKey(token)).Err()
}

func (r *redisStore) Publish(ctx context.Context, event RelayEvent) error {
	data, err := json.Marshal(event)
	if err != nil {
		return err
	}
	return r.client.Publish(ctx, relayEventsChannel, data).Err()
}

// runEventSubscriber 订阅 relayEventsChannel 并把事件分发到 handler，直到 ctx 结束。
// Redis 抖动导致订阅连接关闭时会退避重连；被错过的事件窗口由服务端周期吊销对账
// （Server.reconcileRevocations）兜底。
func (r *redisStore) runEventSubscriber(ctx context.Context, handler func(RelayEvent)) error {
	backoff := time.Second
	for {
		if ctx.Err() != nil {
			return nil
		}
		ps := r.client.Subscribe(ctx, relayEventsChannel)
		ch := ps.Channel()
		connected := true
		for connected {
			select {
			case <-ctx.Done():
				_ = ps.Close()
				return nil
			case msg, ok := <-ch:
				if !ok {
					connected = false
					continue
				}
				var event RelayEvent
				if json.Unmarshal([]byte(msg.Payload), &event) == nil && event.DeviceID != "" {
					handler(event)
				}
			}
		}
		_ = ps.Close()
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(backoff):
		}
		if backoff < 8*time.Second {
			backoff *= 2
		}
	}
}
