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
func (r *redisStore) nonceKey(deviceID, nonce string) string {
	return redisKeyPrefix + "nonce:" + deviceID + ":" + nonce
}
func (r *redisStore) noncesSetKey(deviceID string) string {
	return redisKeyPrefix + "nonces:" + deviceID
}
func (r *redisStore) adminSessionKey(token string) string {
	return redisKeyPrefix + "admin:session:" + token
}

// consumeNonceScript atomically records a nonce and enforces the per-device
// active-nonce cap. KEYS[1]=device nonce SET, KEYS[2]=the nonce key;
// ARGV[1]=TTL(ms), ARGV[2]=cap. Returns 1 when replayed or over the cap.
//
// The SET member set is bounded by the cap (128), matching the in-memory
// behavior where a device that exceeds 128 active nonces is rejected until
// re-enrollment. Members expire with the credential but still count toward the
// cap — identical to the memory store, which prunes only on credential expiry.
const consumeNonceScript = `
if redis.call('SISMEMBER', KEYS[1], KEYS[2]) == 1 then
  return 1
end
if redis.call('SCARD', KEYS[1]) >= tonumber(ARGV[2]) then
  return 1
end
redis.call('SADD', KEYS[1], KEYS[2])
redis.call('SET', KEYS[2], '1', 'PX', ARGV[1])
return 0
`

func (r *redisStore) ConsumeNonce(ctx context.Context, deviceID, nonce string, expiresAt time.Time) (bool, error) {
	ttl := time.Until(expiresAt)
	if ttl <= 0 {
		// Already expired: accept without recording (fail open on the edge).
		return false, nil
	}
	result, err := r.client.Eval(ctx, consumeNonceScript,
		[]string{r.noncesSetKey(deviceID), r.nonceKey(deviceID, nonce)},
		ttl.Milliseconds(), maxProofNoncesPerDevice,
	).Int()
	if err != nil {
		return false, err
	}
	return result == 1, nil
}

func (r *redisStore) ClearDeviceNonces(ctx context.Context, deviceID string) error {
	setKey := r.noncesSetKey(deviceID)
	members, err := r.client.SMembers(ctx, setKey).Result()
	if err != nil {
		return err
	}
	if len(members) > 0 {
		if err := r.client.Del(ctx, members...).Err(); err != nil {
			return err
		}
	}
	return r.client.Del(ctx, setKey).Err()
}

func (r *redisStore) SetPresence(ctx context.Context, deviceID string, p Presence, ttl time.Duration) error {
	data, err := json.Marshal(p)
	if err != nil {
		return err
	}
	return r.client.Set(ctx, r.presenceKey(deviceID), data, ttl).Err()
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

func (r *redisStore) DeletePresence(ctx context.Context, deviceID string) error {
	return r.client.Del(ctx, r.presenceKey(deviceID)).Err()
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
