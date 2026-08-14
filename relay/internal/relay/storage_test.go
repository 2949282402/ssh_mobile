// Focused tests for the memoryStore device-plane seam. These mirror the
// behavior the Server surface already exercises through handlers, and will be
// replicated against the MySQL store in Phase 1.

package relay

import (
	"context"
	"fmt"
	"testing"
	"time"
)

func TestMemoryStorePutEnrollmentIdentityAndCapacity(t *testing.T) {
	store := newMemoryStore(Config{MaxEnrolledDevices: 1, MaxRevokedDevices: 1})
	ctx := context.Background()
	enroll := func(deviceID, publicKey string) enrollmentResult {
		result, _ := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: deviceID, PublicKey: publicKey, EnrolledAt: time.Now()})
		return result
	}

	if result := enroll("device-a", "key-a"); result != enrollmentOK {
		t.Fatalf("first enrollment should succeed, got %v", result)
	}
	if result := enroll("device-a", "key-b"); result != enrollmentIdentityConflict {
		t.Fatalf("conflicting key should be rejected, got %v", result)
	}
	if result := enroll("device-b", "key-b"); result != enrollmentResourceLimit {
		t.Fatalf("capacity limit should reject a new device, got %v", result)
	}
	if result := enroll("device-a", "key-a"); result != enrollmentOK {
		t.Fatalf("same-key re-enroll should succeed, got %v", result)
	}
}

func TestMemoryStoreRevocationSemantics(t *testing.T) {
	store := newMemoryStore(Config{MaxEnrolledDevices: 4, MaxRevokedDevices: 1})
	ctx := context.Background()
	now := time.Now()

	if revoked, _ := store.IsRevoked(ctx, "device-a", now); revoked {
		t.Fatal("unrevoked device reported revoked")
	}
	if recorded, _ := store.RecordRevocation(ctx, "device-a", now.Add(time.Hour)); !recorded {
		t.Fatal("revocation was rejected")
	}
	if revoked, _ := store.IsRevoked(ctx, "device-a", now); !revoked {
		t.Fatal("in-force revocation was not reported")
	}
	// An expired tombstone is lazily pruned and no longer blocks.
	if revoked, _ := store.IsRevoked(ctx, "device-a", now.Add(2*time.Hour)); revoked {
		t.Fatal("expired revocation still in force")
	}
	if _, present, _ := store.RevocationExpiry(ctx, "device-a"); present {
		t.Fatal("expired tombstone was not pruned during IsRevoked")
	}
}

func TestMemoryStoreRevocationCapacityFailsClosed(t *testing.T) {
	store := newMemoryStore(Config{MaxEnrolledDevices: 4, MaxRevokedDevices: 1})
	ctx := context.Background()
	now := time.Now()

	// A stale tombstone still occupies the slot; only a prune of an expired
	// tombstone frees it.
	if recorded, _ := store.RecordRevocation(ctx, "device-a", now.Add(-time.Hour)); !recorded {
		t.Fatal("stale tombstone insertion should be allowed")
	}
	if recorded, _ := store.RecordRevocation(ctx, "device-b", now.Add(time.Hour)); !recorded {
		t.Fatal("expired tombstone did not free capacity for a new revocation")
	}
	if recorded, _ := store.RecordRevocation(ctx, "device-c", now.Add(time.Hour)); recorded {
		t.Fatal("second in-force revocation should fail closed at capacity")
	}
	if _, present, _ := store.RevocationExpiry(ctx, "device-a"); present {
		t.Fatal("expired tombstone was not pruned")
	}
}

func TestMemoryStoreNonceReplayAndClear(t *testing.T) {
	store := newMemoryStore(Config{MaxEnrolledDevices: 1, MaxRevokedDevices: 1})
	ctx := context.Background()
	expiry := time.Now().Add(time.Minute)

	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "nonce-1", expiry); replayed {
		t.Fatal("first nonce reported as replay")
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "nonce-1", expiry); !replayed {
		t.Fatal("replayed nonce was accepted")
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "nonce-2", expiry); replayed {
		t.Fatal("fresh nonce reported as replay")
	}
	// Re-enroll clears the device's nonces so old ones cannot be replayed.
	_ = store.ClearDeviceNonces(ctx, "device-a")
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "nonce-1", expiry); replayed {
		t.Fatal("nonce still present after ClearDeviceNonces")
	}
}

// TestMemoryStoreNonceExpiryFreesCap pins the P0 contract that the Redis ZSET
// refactor mirrors: expired nonces are pruned lazily, so the 128-cap counts only
// *live* nonces and the 129th succeeds once earlier ones have expired.
func TestMemoryStoreNonceExpiryFreesCap(t *testing.T) {
	store := newMemoryStore(Config{MaxEnrolledDevices: 1, MaxRevokedDevices: 1})
	ctx := context.Background()

	for i := 0; i < maxProofNoncesPerDevice; i++ {
		if replayed, _ := store.ConsumeNonce(ctx, "device-a", fmt.Sprintf("t-%d", i), time.Now().Add(time.Second)); replayed {
			t.Fatalf("nonce %d unexpectedly rejected before the cap", i)
		}
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "t-over", time.Now().Add(time.Hour)); !replayed {
		t.Fatal("nonce beyond the cap was accepted while all nonces are live")
	}

	// Poll rather than sleep: the over-cap rejection does not record the nonce,
	// so retrying the same fresh nonce is safe and never flakes on timing.
	deadline := time.Now().Add(5 * time.Second)
	for {
		if replayed, _ := store.ConsumeNonce(ctx, "device-a", "t-fresh", time.Now().Add(time.Hour)); !replayed {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("expired nonces were not pruned; cap never freed (P0 regression)")
		}
		time.Sleep(50 * time.Millisecond)
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "t-0", time.Now().Add(time.Hour)); replayed {
		t.Fatal("expired nonce still treated as replay (P0 regression)")
	}
}

// TestMemoryStorePresenceLeaseSemantics pins the same lease contract as the
// Redis store (TestRedisStorePresenceLeaseSemantics): newest Take wins, only the
// owner renews, release is CAS'd against the owner.
func TestMemoryStorePresenceLeaseSemantics(t *testing.T) {
	store := newMemoryStore(Config{MaxEnrolledDevices: 1, MaxRevokedDevices: 1})
	ctx := context.Background()

	if _, _, err := store.TakePresence(ctx, "device-a", "conn-a", Presence{InstanceID: "i-a"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.TakePresence(ctx, "device-a", "conn-b", Presence{InstanceID: "i-b"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	presence, present, err := store.GetPresence(ctx, "device-a")
	if err != nil || !present || presence.ConnectionID != "conn-b" || presence.InstanceID != "i-b" {
		t.Fatalf("newest connection should own the lease: %+v present=%v err=%v", presence, present, err)
	}
	if ok, _ := store.RenewPresence(ctx, "device-a", "conn-a", Presence{InstanceID: "i-a"}, time.Minute); ok {
		t.Fatal("superseded connection renewed a foreign lease")
	}
	if released, _ := store.ReleasePresence(ctx, "device-a", "conn-a"); released {
		t.Fatal("superseded connection released a foreign lease")
	}
	if _, present, _ := store.GetPresence(ctx, "device-a"); !present {
		t.Fatal("foreign lease was erased by a non-owner release")
	}
	if ok, _ := store.RenewPresence(ctx, "device-a", "conn-b", presence, time.Minute); !ok {
		t.Fatal("owner could not renew its own lease")
	}
	if released, _ := store.ReleasePresence(ctx, "device-a", "conn-b"); !released {
		t.Fatal("owner could not release its own lease")
	}
	if _, present, _ := store.GetPresence(ctx, "device-a"); present {
		t.Fatal("lease still present after owner release")
	}
}

// TestPresenceLeaseSemanticsMemoryMatchesRedis runs one operation sequence
// against both the memory and Redis stores and asserts every renewal/release
// outcome agrees. This pins the Step-2 contract that the two backends are
// interchangeable (it requires RELAY_TEST_REDIS_URL; it skips when absent).
func TestPresenceLeaseSemanticsMemoryMatchesRedis(t *testing.T) {
	memory := newMemoryStore(Config{MaxEnrolledDevices: 1, MaxRevokedDevices: 1})
	ctx := context.Background()
	redisStore, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatalf("open redis: %v", err)
	}
	defer redisStore.Close()
	_ = redisStore.forceDeletePresence(ctx, "equiv-device")
	defer func() { _ = redisStore.forceDeletePresence(ctx, "equiv-device") }()

	type presenceAPI interface {
		TakePresence(ctx context.Context, deviceID, connID string, p Presence, ttl time.Duration) (Presence, bool, error)
		RenewPresence(ctx context.Context, deviceID, connID string, p Presence, ttl time.Duration) (bool, error)
		ReleasePresence(ctx context.Context, deviceID, connID string) (bool, error)
	}
	stores := map[string]presenceAPI{"memory": memory, "redis": redisStore}

	run := func(step string, op func(presenceAPI) (bool, error)) {
		t.Helper()
		results := make(map[string]bool)
		for name, store := range stores {
			got, err := op(store)
			if err != nil {
				t.Fatalf("%s: %s errored: %v", step, name, err)
			}
			results[name] = got
		}
		if results["memory"] != results["redis"] {
			t.Fatalf("%s: memory=%v redis=%v diverged", step, results["memory"], results["redis"])
		}
	}

	run("take-a", func(s presenceAPI) (bool, error) {
		_, _, err := s.TakePresence(ctx, "equiv-device", "a", Presence{InstanceID: "i"}, time.Minute)
		return true, err
	})
	run("renew-owner", func(s presenceAPI) (bool, error) {
		return s.RenewPresence(ctx, "equiv-device", "a", Presence{InstanceID: "i"}, time.Minute)
	})
	run("renew-foreign", func(s presenceAPI) (bool, error) {
		return s.RenewPresence(ctx, "equiv-device", "b", Presence{InstanceID: "i"}, time.Minute)
	})
	run("release-foreign", func(s presenceAPI) (bool, error) {
		return s.ReleasePresence(ctx, "equiv-device", "b")
	})
	run("release-owner", func(s presenceAPI) (bool, error) {
		return s.ReleasePresence(ctx, "equiv-device", "a")
	})
	run("renew-after-release", func(s presenceAPI) (bool, error) {
		// Absent key: renew acquires and succeeds on both backends.
		return s.RenewPresence(ctx, "equiv-device", "a", Presence{InstanceID: "i"}, time.Minute)
	})
	run("release-new-owner", func(s presenceAPI) (bool, error) {
		return s.ReleasePresence(ctx, "equiv-device", "a")
	})
}

// TestPresenceBatchMemoryMatchesRedis pins the batch GetPresences contract across
// backends: for a mix of live/absent/expired devices both stores return the same
// result map, so the admin snapshot behaves identically in memory and Redis modes.
func TestPresenceBatchMemoryMatchesRedis(t *testing.T) {
	memory := newMemoryStore(Config{MaxEnrolledDevices: 1, MaxRevokedDevices: 1})
	ctx := context.Background()
	redisStore, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatalf("open redis: %v", err)
	}
	defer redisStore.Close()
	_ = redisStore.forceDeletePresence(ctx, "batch-a")
	_ = redisStore.forceDeletePresence(ctx, "batch-b")
	_ = redisStore.forceDeletePresence(ctx, "batch-c")
	defer func() {
		_ = redisStore.forceDeletePresence(ctx, "batch-a")
		_ = redisStore.forceDeletePresence(ctx, "batch-b")
		_ = redisStore.forceDeletePresence(ctx, "batch-c")
	}()

	type batchAPI interface {
		TakePresence(ctx context.Context, deviceID, connID string, p Presence, ttl time.Duration) (Presence, bool, error)
		GetPresences(ctx context.Context, deviceIDs []string) (map[string]Presence, error)
	}
	stores := map[string]batchAPI{"memory": memory, "redis": redisStore}
	for _, store := range stores {
		if _, _, err := store.TakePresence(ctx, "batch-a", "conn-a", Presence{InstanceID: "i", RemoteAddr: "10.0.0.1:9000"}, time.Minute); err != nil {
			t.Fatal(err)
		}
		// batch-c is written with a short TTL so it genuinely expires mid-test,
		// exercising the memory lazy-prune branch and the Redis TTL path.
		if _, _, err := store.TakePresence(ctx, "batch-c", "conn-c", Presence{InstanceID: "i"}, 50*time.Millisecond); err != nil {
			t.Fatal(err)
		}
	}
	time.Sleep(100 * time.Millisecond)

	got := make(map[string]map[string]Presence, 2)
	for name, store := range stores {
		result, err := store.GetPresences(ctx, []string{"batch-a", "batch-b", "batch-c", "batch-missing"})
		if err != nil {
			t.Fatalf("%s: GetPresences errored: %v", name, err)
		}
		got[name] = result
	}
	// Only batch-a is live; the never-written (batch-b/batch-missing) and the
	// expired (batch-c) devices must not appear.
	if len(got["memory"]) != 1 || len(got["redis"]) != 1 {
		t.Fatalf("expected exactly batch-a online in both backends: memory=%d redis=%d", len(got["memory"]), len(got["redis"]))
	}
	if _, ok := got["memory"]["batch-c"]; ok {
		t.Fatal("memory GetPresences returned an expired lease")
	}
	if _, ok := got["redis"]["batch-c"]; ok {
		t.Fatal("redis GetPresences returned an expired lease")
	}
	memA, redisA := got["memory"]["batch-a"], got["redis"]["batch-a"]
	if memA.ConnectionID != "conn-a" || memA.RemoteAddr != "10.0.0.1:9000" || memA.InstanceID != "i" {
		t.Fatalf("memory batch presence wrong: %+v", memA)
	}
	if memA.ConnectionID != redisA.ConnectionID || memA.RemoteAddr != redisA.RemoteAddr || memA.InstanceID != redisA.InstanceID {
		t.Fatalf("batch presence diverged: memory=%+v redis=%+v", memA, redisA)
	}
	// Empty input returns an empty, non-nil map on both.
	for name, store := range stores {
		result, err := store.GetPresences(ctx, nil)
		if err != nil || result == nil || len(result) != 0 {
			t.Fatalf("%s: empty GetPresences should return an empty map: result=%v err=%v", name, result, err)
		}
	}
}

func TestMemoryStoreEnrollmentListingAndRemoval(t *testing.T) {
	store := newMemoryStore(Config{MaxEnrolledDevices: 4, MaxRevokedDevices: 1})
	ctx := context.Background()
	for _, id := range []string{"device-a", "device-b"} {
		if _, err := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: id, PublicKey: "key-" + id}); err != nil {
			t.Fatal(err)
		}
	}

	count, _ := store.CountEnrollments(ctx)
	if count != 2 {
		t.Fatalf("expected 2 enrollments, got %d", count)
	}
	items, _ := store.ListEnrollments(ctx)
	if len(items) != 2 {
		t.Fatalf("expected 2 listed enrollments, got %d", len(items))
	}
	_ = store.RemoveEnrollment(ctx, "device-a")
	if count, _ := store.CountEnrollments(ctx); count != 1 {
		t.Fatalf("expected 1 enrollment after removal, got %d", count)
	}
}
