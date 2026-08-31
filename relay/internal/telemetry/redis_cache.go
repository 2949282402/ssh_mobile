// Redis Hot Cache Adapter for Telemetry Diagnostics.

package telemetry

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/redis/go-redis/v9"
)

const (
	RecentDiagnosticsKey = "telemetry:recent_diagnostics"
	DefaultMaxCacheCeil  = 10000
)

type RedisCache interface {
	PushDiagnostic(ctx context.Context, env TelemetryEnvelope, maxRecords int) error
	GetRecentDiagnostics(ctx context.Context, limit int) ([]TelemetryEnvelope, error)
	Close() error
}

type RedisClientCache struct {
	client *redis.Client
}

func NewRedisClientCache(client *redis.Client) *RedisClientCache {
	return &RedisClientCache{client: client}
}

// NewRedisClientCacheFromURL parses a Redis URL and verifies connectivity.
func NewRedisClientCacheFromURL(redisURL, password string) (*RedisClientCache, error) {
	opt, err := redis.ParseURL(redisURL)
	if err != nil {
		return nil, fmt.Errorf("parse redis url error: %w", err)
	}
	if password != "" {
		opt.Password = password
	}
	client := redis.NewClient(opt)
	return &RedisClientCache{client: client}, nil
}

func (r *RedisClientCache) PushDiagnostic(ctx context.Context, env TelemetryEnvelope, maxRecords int) error {
	if r.client == nil {
		return nil
	}
	if maxRecords <= 0 {
		maxRecords = 1000
	}
	if maxRecords > DefaultMaxCacheCeil {
		maxRecords = DefaultMaxCacheCeil
	}

	data, err := json.Marshal(env)
	if err != nil {
		return fmt.Errorf("marshal diagnostic envelope: %w", err)
	}

	pipe := r.client.Pipeline()
	pipe.LPush(ctx, RecentDiagnosticsKey, data)
	pipe.LTrim(ctx, RecentDiagnosticsKey, 0, int64(maxRecords-1))
	_, err = pipe.Exec(ctx)
	return err
}

func (r *RedisClientCache) GetRecentDiagnostics(ctx context.Context, limit int) ([]TelemetryEnvelope, error) {
	if r.client == nil {
		return nil, nil
	}
	if limit <= 0 {
		limit = 50
	}
	if limit > DefaultMaxCacheCeil {
		limit = DefaultMaxCacheCeil
	}

	items, err := r.client.LRange(ctx, RecentDiagnosticsKey, 0, int64(limit-1)).Result()
	if err != nil {
		return nil, err
	}

	records := make([]TelemetryEnvelope, 0, len(items))
	for _, raw := range items {
		var env TelemetryEnvelope
		if err := json.Unmarshal([]byte(raw), &env); err == nil {
			records = append(records, env)
		}
	}

	return records, nil
}

func (r *RedisClientCache) Close() error {
	if r.client != nil {
		return r.client.Close()
	}
	return nil
}

type NoopRedisCache struct{}

func (n *NoopRedisCache) PushDiagnostic(ctx context.Context, env TelemetryEnvelope, maxRecords int) error {
	return nil
}

func (n *NoopRedisCache) GetRecentDiagnostics(ctx context.Context, limit int) ([]TelemetryEnvelope, error) {
	return nil, nil
}

func (n *NoopRedisCache) Close() error {
	return nil
}
