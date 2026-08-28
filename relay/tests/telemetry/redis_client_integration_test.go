package telemetry_test

import (
	"context"
	"os"
	"testing"

	"github.com/redis/go-redis/v9"
	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func telemetryRedisURL(t *testing.T) string {
	t.Helper()
	for _, name := range []string{"TELEMETRY_TEST_REDIS_URL", "TELEMETRY_REDIS_URL"} {
		if value := os.Getenv(name); value != "" {
			return value
		}
	}
	t.Skip("TELEMETRY_TEST_REDIS_URL or TELEMETRY_REDIS_URL not set; skipping Redis integration test")
	return ""
}

func TestRedisClientCacheRoundTripBoundsAndDegradation(t *testing.T) {
	ctx := context.Background()
	redisURL := telemetryRedisURL(t)
	options, err := redis.ParseURL(redisURL)
	if err != nil {
		t.Fatalf("parse Redis test URL: %v", err)
	}
	direct := redis.NewClient(options)
	defer direct.Close()
	if err := direct.Ping(ctx).Err(); err != nil {
		t.Fatalf("ping Redis test server: %v", err)
	}
	if err := direct.Del(ctx, RecentDiagnosticsKey).Err(); err != nil {
		t.Fatalf("clear Redis diagnostics list: %v", err)
	}

	if _, err := NewRedisClientCacheFromURL("://invalid", ""); err == nil {
		t.Fatal("invalid Redis URL unexpectedly parsed")
	}
	cache, err := NewRedisClientCacheFromURL(redisURL, "")
	if err != nil {
		t.Fatalf("create Redis cache: %v", err)
	}
	envA := testEnvelope("redis-cache-a", "redis-device")
	envB := testEnvelope("redis-cache-b", "redis-device")
	if err := cache.PushDiagnostic(ctx, envA, 0); err != nil {
		t.Fatalf("push diagnostic with default bound: %v", err)
	}
	if err := cache.PushDiagnostic(ctx, envB, DefaultMaxCacheCeil+1); err != nil {
		t.Fatalf("push diagnostic with maximum bound: %v", err)
	}
	if err := direct.LPush(ctx, RecentDiagnosticsKey, "not-json").Err(); err != nil {
		t.Fatalf("seed malformed Redis diagnostic: %v", err)
	}
	records, err := cache.GetRecentDiagnostics(ctx, 0)
	if err != nil || len(records) != 2 {
		t.Fatalf("default-limit diagnostics = %#v, err=%v, want two valid records", records, err)
	}
	if records[0].EventID != envB.EventID || records[1].EventID != envA.EventID {
		t.Fatalf("Redis diagnostic order = %#v, want newest-first %q/%q", records, envB.EventID, envA.EventID)
	}
	if records, err = cache.GetRecentDiagnostics(ctx, DefaultMaxCacheCeil+1); err != nil || len(records) != 2 {
		t.Fatalf("maximum-limit diagnostics = %#v, err=%v, want two valid records", records, err)
	}

	bad := testEnvelope("redis-cache-bad", "redis-device")
	bad.Properties["session_type"] = func() {}
	if err := cache.PushDiagnostic(ctx, bad, 1); err == nil {
		t.Fatal("unmarshalable diagnostic unexpectedly pushed")
	}
	if err := cache.Close(); err != nil {
		t.Fatalf("close Redis cache: %v", err)
	}
	if err := cache.PushDiagnostic(ctx, envA, 1); err == nil {
		t.Fatal("push on closed Redis cache unexpectedly succeeded")
	}
	if _, err := cache.GetRecentDiagnostics(ctx, 1); err == nil {
		t.Fatal("read on closed Redis cache unexpectedly succeeded")
	}

	noop := NewRedisClientCache(nil)
	if got, err := noop.GetRecentDiagnostics(ctx, 1); err != nil || got != nil {
		t.Fatalf("nil Redis client read = %#v, err=%v, want nil/nil", got, err)
	}
	if err := noop.PushDiagnostic(ctx, envA, 1); err != nil {
		t.Fatalf("nil Redis client push: %v", err)
	}
	if err := noop.Close(); err != nil {
		t.Fatalf("close nil Redis client: %v", err)
	}
}
