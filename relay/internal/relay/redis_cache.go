// Redis-backed Cache: shared nonce, presence, administrator session and event
// bus. Phase 2 activates this when RELAY_REDIS_URL is set alongside mysql
// storage; it is the shared-live-state layer. Relay Control and Relay Data are
// single-instance in this phase; there is no Global Control Routing or Relay
// Data Node Selection (design §26). Redis carries only rebuildable live state
// (presence/discovery/nonce/events); MySQL remains the durable truth.

package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

const redisKeyPrefix = "relay:"

// redisStore implements Cache against Redis. go-redis clients are
// concurrent-safe, so no internal lock is needed. Key TTLs carry the expiry
// semantics that the memory store tracks explicitly.
type redisStore struct {
	client *redis.Client
	logger *slog.Logger
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
	return &redisStore{client: client, logger: slog.Default()}, nil
}

// Close 释放 Redis 连接。
func (r *redisStore) Close() error { return r.client.Close() }

func (r *redisStore) presenceKey(deviceID string) string {
	return redisKeyPrefix + "presence:" + deviceID
}
func (r *redisStore) discoveryKey(deviceID string) string {
	return redisKeyPrefix + "discovery:" + deviceID
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

// takePresenceScript unconditionally establishes the new lease owner and returns
// the previous value (nil when the lease was free), so the claimer can notify
// the superseded owner's instance with a targeted connection.replaced event.
// KEYS[1]=relay:presence:<deviceID>; ARGV[1]=json, ARGV[2]=ttl(ms). The GET→SET
// is atomic inside the script, so the returned previous owner cannot be torn by
// a concurrent claim.
const takePresenceScript = `
local previous = redis.call('GET', KEYS[1])
if tonumber(ARGV[2]) <= 0 then
  return previous
end
redis.call('SET', KEYS[1], ARGV[1], 'PX', ARGV[2])
return previous
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
// self-close the connection). It returns the superseded lease (replaced=true
// when there was a live previous owner) so the claimer can publish a targeted
// connection.replaced event to the old owner's instance.
func (r *redisStore) TakePresence(ctx context.Context, deviceID, connID string, p Presence, ttl time.Duration) (Presence, bool, error) {
	p.ConnectionID = connID
	data, err := json.Marshal(p)
	if err != nil {
		return Presence{}, false, err
	}
	previous, err := r.client.Eval(ctx, takePresenceScript,
		[]string{r.presenceKey(deviceID)},
		string(data), ttl.Milliseconds(),
	).Result()
	if err != nil {
		if !errors.Is(err, redis.Nil) {
			return Presence{}, false, err
		}
		// Lua returned nil: the lease was free, so there is no previous owner.
		return Presence{}, false, nil
	}
	if s, ok := previous.(string); ok {
		var prev Presence
		if err := json.Unmarshal([]byte(s), &prev); err != nil {
			// A corrupt/foreign previous value: still take over, but report no
			// previous owner (we cannot target a replacement event at it).
			return Presence{}, false, nil
		}
		return prev, true, nil
	}
	return Presence{}, false, nil
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

func (r *redisStore) GetPresences(ctx context.Context, deviceIDs []string) (map[string]Presence, error) {
	if len(deviceIDs) == 0 {
		return map[string]Presence{}, nil
	}
	keys := make([]string, 0, len(deviceIDs))
	for _, deviceID := range deviceIDs {
		keys = append(keys, r.presenceKey(deviceID))
	}
	values, err := r.client.MGet(ctx, keys...).Result()
	if err != nil {
		return nil, err
	}
	result := make(map[string]Presence, len(deviceIDs))
	for i, value := range values {
		if value == nil {
			continue // 缺失/已过期：不在结果中。
		}
		data, ok := value.(string)
		if !ok {
			// 值不是字符串（如误用 INCR 产生的整数）：跳过并记日志，否则在线数
			// 异常时无从排查。
			r.logger.Warn("skipped non-string presence value in batch query", "device_id", deviceIDs[i])
			continue
		}
		var p Presence
		if err := json.Unmarshal([]byte(data), &p); err != nil {
			// 与单 key GetPresence 不同，损坏条目跳过而非返回 error：admin 调用方
			// 忽略错误，单条损坏不应让全部设备显示离线（保持逐设备 fail-open 粒度）。
			r.logger.Warn("skipped corrupt presence value in batch query", "device_id", deviceIDs[i], "error", err)
			continue
		}
		result[deviceIDs[i]] = p
	}
	return result, nil
}

// takeDiscoveryScript stores a device's discovery only while the writer still
// owns the presence lease (CAS). Presence ownership is the single authority for
// "which connection may publish discovery": a superseded connection whose
// presence has been taken over by a newer connection cannot overwrite the newer
// connection's discovery back to itself (cross-instance reconnect race).
// KEYS[1]=relay:presence:<deviceID>, KEYS[2]=relay:discovery:<deviceID>;
// ARGV[1]=connID, ARGV[2]=discovery json, ARGV[3]=ttl(ms). Returns 1 when the
// discovery was written, 0 when connID is not the presence owner (rejected).
const takeDiscoveryScript = `
local pdata = redis.call('GET', KEYS[1])
if not pdata then
  return 0
end
local pok, pobj = pcall(cjson.decode, pdata)
-- type(pobj)=='table' excludes JSON null/primitives (see renewPresenceScript).
if not (pok and type(pobj) == 'table' and pobj['connection_id'] == ARGV[1]) then
  return 0
end
redis.call('SET', KEYS[2], ARGV[2], 'PX', ARGV[3])
return 1
`

// renewDiscoveryScript renews the discovery TTL only while connID still owns it
// (CAS), and only extends TTL — it does not rewrite the stored candidates. An
// absent/expired key is treated as "owned but nothing to renew" (return 1), so a
// device that has not uploaded discovery yet is never self-closed by the
// heartbeat path; the discovery appears once the device uploads it. A foreign
// owner (or a non-object legacy value) returns 0 so a superseded connection
// cannot keep a newer one's discovery alive.
const renewDiscoveryScript = `
local data = redis.call('GET', KEYS[1])
if not data then
  return 1
end
local ok, obj = pcall(cjson.decode, data)
if ok and type(obj) == 'table' and obj['connection_id'] == ARGV[1] then
  redis.call('PEXPIRE', KEYS[1], ARGV[2])
  return 1
end
return 0
`

// releaseDiscoveryScript releases the discovery only while connID owns it (CAS
// delete), so a superseded connection can never erase a newer one's discovery.
const releaseDiscoveryScript = `
local data = redis.call('GET', KEYS[1])
if not data then
  return 0
end
local ok, obj = pcall(cjson.decode, data)
if ok and type(obj) == 'table' and obj['connection_id'] == ARGV[1] then
  redis.call('DEL', KEYS[1])
  return 1
end
return 0
`

func (r *redisStore) TakeDiscovery(ctx context.Context, deviceID, connID string, d Discovery, ttl time.Duration) error {
	d.ConnectionID = connID
	data, err := json.Marshal(d)
	if err != nil {
		return err
	}
	// 脚本同时读 presence（KEYS[1]）与 discovery（KEYS[2]），GET→校验→SET 原子，
	// 不存在 get-then-set 的 TOCTOU 窗口。
	result, err := r.client.Eval(ctx, takeDiscoveryScript,
		[]string{r.presenceKey(deviceID), r.discoveryKey(deviceID)},
		connID, string(data), ttl.Milliseconds(),
	).Int()
	if err != nil {
		return err
	}
	if result != 1 {
		return errDiscoveryNotOwner
	}
	return nil
}

func (r *redisStore) RenewDiscovery(ctx context.Context, deviceID, connID string, ttl time.Duration) (bool, error) {
	result, err := r.client.Eval(ctx, renewDiscoveryScript,
		[]string{r.discoveryKey(deviceID)},
		connID, ttl.Milliseconds(),
	).Int()
	if err != nil {
		return false, err
	}
	return result == 1, nil
}

func (r *redisStore) ReleaseDiscovery(ctx context.Context, deviceID, connID string) (bool, error) {
	result, err := r.client.Eval(ctx, releaseDiscoveryScript,
		[]string{r.discoveryKey(deviceID)},
		connID,
	).Int()
	if err != nil {
		return false, err
	}
	return result == 1, nil
}

func (r *redisStore) GetDiscovery(ctx context.Context, deviceID string) (Discovery, bool, error) {
	data, err := r.client.Get(ctx, r.discoveryKey(deviceID)).Bytes()
	if errors.Is(err, redis.Nil) {
		return Discovery{}, false, nil
	}
	if err != nil {
		return Discovery{}, false, err
	}
	var d Discovery
	if err := json.Unmarshal(data, &d); err != nil {
		return Discovery{}, false, err
	}
	return d, true, nil
}

func (r *redisStore) GetDiscoveries(ctx context.Context, deviceIDs []string) (map[string]Discovery, error) {
	if len(deviceIDs) == 0 {
		return map[string]Discovery{}, nil
	}
	keys := make([]string, 0, len(deviceIDs))
	for _, deviceID := range deviceIDs {
		keys = append(keys, r.discoveryKey(deviceID))
	}
	values, err := r.client.MGet(ctx, keys...).Result()
	if err != nil {
		return nil, err
	}
	result := make(map[string]Discovery, len(deviceIDs))
	for i, value := range values {
		if value == nil {
			continue
		}
		data, ok := value.(string)
		if !ok {
			r.logger.Warn("skipped non-string discovery value in batch query", "device_id", deviceIDs[i])
			continue
		}
		var d Discovery
		if err := json.Unmarshal([]byte(data), &d); err != nil {
			r.logger.Warn("skipped corrupt discovery value in batch query", "device_id", deviceIDs[i], "error", err)
			continue
		}
		result[deviceIDs[i]] = d
	}
	return result, nil
}

// ListOnlinePeers 返回可在线判定的设备（明确版 §13）：presence 与 discovery 均有效、
// discovery 已可靠发布（ready()：revision>0）、且 presence 与 discovery 的所有者
// ConnectionID 一致。用 SCAN 枚举 presence 键，再批量取 presence 值与 discovery；
// presence 键的 TTL 由 Redis 主动过期，故 SCAN 到的键未过期，但 SCAN 与 MGET 之间仍
// 可能被过期清除（MGET 返回 nil 即跳过）。owner 不匹配或 revision=0 的条目（重连
// 窗口内旧连接的残留 discovery）不算在线。
func (r *redisStore) ListOnlinePeers(ctx context.Context) (map[string]Discovery, error) {
	result := make(map[string]Discovery)
	var cursor uint64
	for {
		keys, next, err := r.client.Scan(ctx, cursor, redisKeyPrefix+"presence:*", 100).Result()
		if err != nil {
			return nil, err
		}
		if len(keys) > 0 {
			deviceIDs := make([]string, 0, len(keys))
			presenceKeys := make([]string, 0, len(keys))
			discoveryKeys := make([]string, 0, len(keys))
			for _, key := range keys {
				deviceID := strings.TrimPrefix(key, redisKeyPrefix+"presence:")
				deviceIDs = append(deviceIDs, deviceID)
				presenceKeys = append(presenceKeys, key)
				discoveryKeys = append(discoveryKeys, r.discoveryKey(deviceID))
			}
			presenceValues, err := r.client.MGet(ctx, presenceKeys...).Result()
			if err != nil {
				return nil, err
			}
			discoveryValues, err := r.client.MGet(ctx, discoveryKeys...).Result()
			if err != nil {
				return nil, err
			}
			for i, value := range discoveryValues {
				if value == nil {
					continue // presence 在、discovery 缺失/已过期：不算在线。
				}
				presenceValue := presenceValues[i]
				if presenceValue == nil {
					continue // SCAN 与 MGET 之间 presence 已过期。
				}
				pdata, ok := presenceValue.(string)
				if !ok {
					continue
				}
				var p Presence
				if err := json.Unmarshal([]byte(pdata), &p); err != nil {
					r.logger.Warn("skipped corrupt presence value in online peers", "device_id", deviceIDs[i], "error", err)
					continue
				}
				ddata, ok := value.(string)
				if !ok {
					continue
				}
				var d Discovery
				if err := json.Unmarshal([]byte(ddata), &d); err != nil {
					r.logger.Warn("skipped corrupt discovery value in online peers", "device_id", deviceIDs[i], "error", err)
					continue
				}
				if !d.ready() || p.ConnectionID != d.ConnectionID {
					continue
				}
				result[deviceIDs[i]] = d
			}
		}
		if next == 0 {
			break
		}
		cursor = next
	}
	return result, nil
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
