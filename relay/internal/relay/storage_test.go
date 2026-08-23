// Focused tests for the memoryStore device-plane seam. These mirror the
// behavior the Server surface already exercises through handlers, and will be
// replicated against the MySQL store in Phase 1.

package relay

import (
	"context"
	"fmt"
	"sync"
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

func TestMemoryStoreRevokeEnrollment(t *testing.T) {
	store := newMemoryStore(Config{MaxEnrolledDevices: 4, MaxRevokedDevices: 4})
	ctx := context.Background()

	if outcome, _, err := store.RevokeEnrollment(ctx, "device-a", time.Hour); err != nil || outcome != revokeNotEnrolled {
		t.Fatalf("revoke of an unenrolled device should report not enrolled: outcome=%v err=%v", outcome, err)
	}

	enrolledAt := time.Now().Add(-time.Hour)
	if result, _ := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: "device-a", PublicKey: "key-a", EnrolledAt: enrolledAt}); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	revokedAfter := time.Now()
	outcome, generation, err := store.RevokeEnrollment(ctx, "device-a", time.Hour)
	revokedBefore := time.Now()
	if err != nil || outcome != revokeOK {
		t.Fatalf("revoke failed: outcome=%v err=%v", outcome, err)
	}
	if generation != enrolledAt.UTC().Truncate(time.Microsecond).UnixMicro() {
		t.Fatalf("revoked generation=%d, want %d", generation, enrolledAt.UTC().Truncate(time.Microsecond).UnixMicro())
	}
	if device, _ := store.GetEnrollment(ctx, "device-a"); device != nil {
		t.Fatal("enrollment should be removed after revoke")
	}
	expiry, present, _ := store.RevocationExpiry(ctx, "device-a")
	if !present {
		t.Fatal("tombstone should be present after revoke")
	}
	if expiry.Before(revokedAfter.Add(time.Hour)) || expiry.After(revokedBefore.Add(time.Hour)) {
		t.Fatalf("tombstone bound = %v, want revoke-time window [%v, %v]", expiry,
			revokedAfter.Add(time.Hour), revokedBefore.Add(time.Hour))
	}
}

func TestMemoryStoreEnrollmentGenerationIsMonotonic(t *testing.T) {
	store := newMemoryStore(Config{MaxEnrolledDevices: 4, MaxRevokedDevices: 4})
	ctx := context.Background()
	fixedTime := time.Now()
	first := &EnrolledDevice{DeviceID: "device-a", PublicKey: "key-a", EnrolledAt: fixedTime}
	if result, err := store.PutEnrollment(ctx, first); err != nil || result != enrollmentOK {
		t.Fatalf("first enrollment: result=%v err=%v", result, err)
	}
	second := &EnrolledDevice{DeviceID: "device-a", PublicKey: "key-a", EnrolledAt: fixedTime}
	if result, err := store.PutEnrollment(ctx, second); err != nil || result != enrollmentOK {
		t.Fatalf("second enrollment: result=%v err=%v", result, err)
	}
	if !second.EnrolledAt.After(first.EnrolledAt) {
		t.Fatalf("generation did not advance: first=%s second=%s", first.EnrolledAt, second.EnrolledAt)
	}
}

func TestMemoryStoreReenrollmentAdvancesPastRevokedGeneration(t *testing.T) {
	store := newMemoryStore(Config{MaxEnrolledDevices: 4, MaxRevokedDevices: 4})
	ctx := context.Background()
	fixedTime := time.Now()
	first := &EnrolledDevice{DeviceID: "device-a", PublicKey: "key-a", EnrolledAt: fixedTime}
	if result, err := store.PutEnrollment(ctx, first); err != nil || result != enrollmentOK {
		t.Fatalf("first enrollment: result=%v err=%v", result, err)
	}
	outcome, revokedGeneration, err := store.RevokeEnrollment(ctx, "device-a", time.Hour)
	if err != nil || outcome != revokeOK {
		t.Fatalf("revoke: outcome=%v err=%v", outcome, err)
	}
	second := &EnrolledDevice{DeviceID: "device-a", PublicKey: "key-a", EnrolledAt: fixedTime}
	if result, err := store.PutEnrollment(ctx, second); err != nil || result != enrollmentOK {
		t.Fatalf("re-enrollment: result=%v err=%v", result, err)
	}
	if second.EnrolledAt.UnixMicro() <= revokedGeneration {
		t.Fatalf("re-enrollment generation=%d did not advance past revoked=%d", second.EnrolledAt.UnixMicro(), revokedGeneration)
	}
}

// TestMemoryStoreRevokeCapacityFailsClosedWithoutDeleting verifies a capacity
// failure inside RevokeEnrollment keeps the enrollment intact (fail closed), so
// the admin 429 path never half-revokes a device — matching RecordRevocation's
// saturate behavior.
func TestMemoryStoreRevokeCapacityFailsClosedWithoutDeleting(t *testing.T) {
	store := newMemoryStore(Config{MaxEnrolledDevices: 4, MaxRevokedDevices: 1})
	ctx := context.Background()
	// 先占满墓碑容量（in-force）。
	if recorded, _ := store.RecordRevocation(ctx, "device-other", time.Now().Add(time.Hour)); !recorded {
		t.Fatal("seed revocation rejected")
	}
	if result, _ := store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: "device-a", PublicKey: "key-a", EnrolledAt: time.Now()}); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}

	outcome, _, err := store.RevokeEnrollment(ctx, "device-a", time.Hour)
	if err != nil || outcome != revokeCapacity {
		t.Fatalf("expected capacity outcome, got outcome=%v err=%v", outcome, err)
	}
	if device, _ := store.GetEnrollment(ctx, "device-a"); device == nil {
		t.Fatal("enrollment must survive a capacity-failed revoke (fail closed)")
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
	// Explicit maintenance reset remains available, but enrollment lifecycle
	// code deliberately does not call it because that would reopen replay.
	_ = store.ClearDeviceNonces(ctx, "device-a")
	if len(store.proofNonces) != 0 || len(store.proofNonceExpiries) != 0 || len(store.proofNonceExpiryByDevice) != 0 {
		t.Fatalf("nonce clear left indexed state: maps=%d heap=%d index=%d",
			len(store.proofNonces), len(store.proofNonceExpiries), len(store.proofNonceExpiryByDevice))
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "nonce-1", expiry); replayed {
		t.Fatal("nonce still present after ClearDeviceNonces")
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "already-expired", time.Now().Add(-time.Second)); !replayed {
		t.Fatal("already-expired nonce window failed open")
	}
}

func TestMemoryStoreNonceSurvivesEnrollmentLifecycle(t *testing.T) {
	store := newMemoryStore(Config{})
	ctx := context.Background()
	expiry := time.Now().Add(time.Hour)

	if replayed, _ := store.ConsumeNonce(ctx, "device-reenroll", "proof", expiry); replayed {
		t.Fatal("initial re-enrollment proof was rejected")
	}
	for i := 0; i < 2; i++ {
		result, err := store.PutEnrollment(ctx, &EnrolledDevice{
			DeviceID:   "device-reenroll",
			PublicKey:  "key",
			EnrolledAt: time.Now(),
		})
		if err != nil || result != enrollmentOK {
			t.Fatalf("enrollment %d: result=%v err=%v", i, result, err)
		}
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-reenroll", "proof", expiry); !replayed {
		t.Fatal("same-key re-enrollment cleared an active proof nonce")
	}

	if replayed, _ := store.ConsumeNonce(ctx, "device-revoke", "proof", expiry); replayed {
		t.Fatal("initial revocation proof was rejected")
	}
	if result, err := store.PutEnrollment(ctx, &EnrolledDevice{
		DeviceID:   "device-revoke",
		PublicKey:  "key",
		EnrolledAt: time.Now(),
	}); err != nil || result != enrollmentOK {
		t.Fatalf("revoke enrollment: result=%v err=%v", result, err)
	}
	if outcome, _, err := store.RevokeEnrollment(ctx, "device-revoke", time.Hour); err != nil || outcome != revokeOK {
		t.Fatalf("revoke: outcome=%v err=%v", outcome, err)
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-revoke", "proof", expiry); !replayed {
		t.Fatal("revocation cleared an active proof nonce")
	}
}

// TestMemoryStoreNonceExpiryFreesCap pins the P0 contract that the Redis ZSET
// refactor mirrors: expired nonces are pruned lazily, so the 128-cap counts only
// *live* nonces and the 129th succeeds once earlier ones have expired.
func TestMemoryStoreNonceExpiryFreesCap(t *testing.T) {
	store := newMemoryStore(Config{MaxEnrolledDevices: 1, MaxRevokedDevices: 1})
	ctx := context.Background()
	expiry := time.Now().Add(time.Hour)

	for i := 0; i < maxProofNoncesPerDevice; i++ {
		if replayed, _ := store.ConsumeNonce(ctx, "device-a", fmt.Sprintf("t-%d", i), expiry); replayed {
			t.Fatalf("nonce %d unexpectedly rejected before the cap", i)
		}
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "t-over", expiry.Add(time.Hour)); !replayed {
		t.Fatal("nonce beyond the cap was accepted while all nonces are live")
	}

	// Drive the production pruning routine with an explicit later clock value;
	// no sleep or mutable production clock hook is needed.
	store.deviceMu.Lock()
	store.pruneExpiredProofNoncesLocked(expiry.Add(time.Nanosecond), maxProofNoncePrunesPerConsume)
	store.deviceMu.Unlock()
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "t-fresh", expiry.Add(time.Hour)); replayed {
		t.Fatal("expired nonces were not pruned; cap did not free")
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "t-0", expiry.Add(time.Hour)); replayed {
		t.Fatal("expired nonce still treated as replay (P0 regression)")
	}
}

func TestMemoryStoreNonceExpiryIndexMovesToEarlierInsert(t *testing.T) {
	store := newMemoryStore(Config{})
	ctx := context.Background()
	earlyExpiry := time.Now().Add(time.Hour)
	middleExpiry := earlyExpiry.Add(time.Hour)
	lateExpiry := middleExpiry.Add(time.Hour)

	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "late", lateExpiry); replayed {
		t.Fatal("late nonce was rejected")
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-b", "middle", middleExpiry); replayed {
		t.Fatal("middle nonce was rejected")
	}
	if replayed, _ := store.ConsumeNonce(ctx, "device-a", "early", earlyExpiry); replayed {
		t.Fatal("earlier nonce was rejected")
	}
	if root := store.proofNonceExpiries[0]; root.deviceID != "device-a" || !root.expiresAt.Equal(earlyExpiry) {
		t.Fatalf("expiry heap root=%+v, want device-a at %v", root, earlyExpiry)
	}

	store.deviceMu.Lock()
	store.pruneExpiredProofNoncesLocked(earlyExpiry.Add(time.Nanosecond), 1)
	store.deviceMu.Unlock()
	if nonces := store.proofNonces["device-a"]; len(nonces) != 1 || !nonces["late"].Equal(lateExpiry) {
		t.Fatalf("device-a after earliest prune=%v, want only late nonce", nonces)
	}
	if root := store.proofNonceExpiries[0]; root.deviceID != "device-b" || !root.expiresAt.Equal(middleExpiry) {
		t.Fatalf("re-indexed heap root=%+v, want device-b at %v", root, middleExpiry)
	}
}

// TestMemoryStoreNonceTargetPrunesBehindGlobalBacklog pins the per-device cap
// contract when more expired historical devices exist than one authentication's
// global cleanup budget. The target's own 128 expired entries must still be
// removed before applying its cap.
func TestMemoryStoreNonceTargetPrunesBehindGlobalBacklog(t *testing.T) {
	store := newMemoryStore(Config{})
	ctx := context.Background()
	futureExpiry := time.Now().Add(time.Hour)
	const historicalDevices = maxProofNoncePrunesPerConsume * 2

	for i := 0; i < historicalDevices; i++ {
		deviceID := fmt.Sprintf("historical-%02d", i)
		if replayed, err := store.ConsumeNonce(ctx, deviceID, "proof", futureExpiry); err != nil || replayed {
			t.Fatalf("seed %s: replayed=%v err=%v", deviceID, replayed, err)
		}
	}
	for i := 0; i < maxProofNoncesPerDevice; i++ {
		if replayed, err := store.ConsumeNonce(ctx, "target", fmt.Sprintf("proof-%d", i), futureExpiry); err != nil || replayed {
			t.Fatalf("seed target %d: replayed=%v err=%v", i, replayed, err)
		}
	}

	// Deterministically model clock passage without sleeping or adding a
	// production clock hook. Every heap key started equal, so replacing all keys
	// with the same past instant preserves heap order.
	pastExpiry := time.Now().Add(-time.Second)
	store.deviceMu.Lock()
	for _, nonces := range store.proofNonces {
		for nonce := range nonces {
			nonces[nonce] = pastExpiry
		}
	}
	for _, entry := range store.proofNonceExpiries {
		entry.expiresAt = pastExpiry
	}
	store.deviceMu.Unlock()

	if replayed, err := store.ConsumeNonce(ctx, "target", "fresh", time.Now().Add(time.Hour)); err != nil || replayed {
		t.Fatalf("fresh target proof behind cleanup backlog: replayed=%v err=%v", replayed, err)
	}
	if nonces := store.proofNonces["target"]; len(nonces) != 1 {
		t.Fatalf("target nonce count after targeted prune=%d, want 1", len(nonces))
	}
	if got := len(store.proofNonces); got != historicalDevices-maxProofNoncePrunesPerConsume+1 {
		t.Fatalf("bounded cleanup retained device maps=%d, want %d", got, historicalDevices-maxProofNoncePrunesPerConsume+1)
	}
}

// TestMemoryStoreNonceChurnPrunesHistoricalDeviceMaps verifies that expiry is
// globally ordered rather than cleaned only when the same device authenticates
// again. The heap retains exactly one entry per non-empty device map, and
// repeated fixed-budget pruning converges historical device churn while
// retaining a mixed device's later nonce.
func TestMemoryStoreNonceChurnPrunesHistoricalDeviceMaps(t *testing.T) {
	store := newMemoryStore(Config{})
	ctx := context.Background()
	earlyExpiry := time.Now().Add(time.Hour)
	lateExpiry := earlyExpiry.Add(time.Hour)
	const historicalDevices = 512

	for i := 0; i < historicalDevices; i++ {
		deviceID := fmt.Sprintf("historical-%d", i)
		if replayed, err := store.ConsumeNonce(ctx, deviceID, "proof", earlyExpiry); err != nil || replayed {
			t.Fatalf("seed %s: replayed=%v err=%v", deviceID, replayed, err)
		}
	}
	if replayed, err := store.ConsumeNonce(ctx, "mixed", "early", earlyExpiry); err != nil || replayed {
		t.Fatalf("seed mixed early: replayed=%v err=%v", replayed, err)
	}
	if replayed, err := store.ConsumeNonce(ctx, "mixed", "late", lateExpiry); err != nil || replayed {
		t.Fatalf("seed mixed late: replayed=%v err=%v", replayed, err)
	}
	if replayed, err := store.ConsumeNonce(ctx, "live", "proof", lateExpiry); err != nil || replayed {
		t.Fatalf("seed live: replayed=%v err=%v", replayed, err)
	}
	if got, want := len(store.proofNonceExpiries), historicalDevices+2; got != want {
		t.Fatalf("heap entries=%d, want one per device (%d)", got, want)
	}

	pruneTime := earlyExpiry.Add(time.Nanosecond)
	store.deviceMu.Lock()
	if got := store.pruneExpiredProofNoncesLocked(pruneTime, maxProofNoncePrunesPerConsume); got != maxProofNoncePrunesPerConsume {
		store.deviceMu.Unlock()
		t.Fatalf("first bounded prune processed=%d, want %d", got, maxProofNoncePrunesPerConsume)
	}
	if got := len(store.proofNonces); got != historicalDevices+2-maxProofNoncePrunesPerConsume {
		store.deviceMu.Unlock()
		t.Fatalf("first bounded prune retained maps=%d, want %d", got, historicalDevices+2-maxProofNoncePrunesPerConsume)
	}
	for len(store.proofNonceExpiries) > 0 && pruneTime.After(store.proofNonceExpiries[0].expiresAt) {
		store.pruneExpiredProofNoncesLocked(pruneTime, maxProofNoncePrunesPerConsume)
	}
	store.deviceMu.Unlock()

	if got := len(store.proofNonces); got != 2 {
		t.Fatalf("device maps after churn prune=%d, want mixed and live only", got)
	}
	if got := len(store.proofNonceExpiries); got != 2 {
		t.Fatalf("heap entries after churn prune=%d, want 2", got)
	}
	if got := len(store.proofNonceExpiryByDevice); got != 2 {
		t.Fatalf("expiry index after churn prune=%d, want 2", got)
	}
	if nonces := store.proofNonces["mixed"]; len(nonces) != 1 || !nonces["late"].Equal(lateExpiry) {
		t.Fatalf("mixed device nonces after prune=%v, want only later proof", nonces)
	}
	if entry := store.proofNonceExpiryByDevice["mixed"]; entry == nil || !entry.expiresAt.Equal(lateExpiry) {
		t.Fatalf("mixed device next expiry=%v, want %v", entry, lateExpiry)
	}
	for i := 0; i < historicalDevices; i++ {
		deviceID := fmt.Sprintf("historical-%d", i)
		if _, present := store.proofNonces[deviceID]; present {
			t.Fatalf("expired historical map %s was retained", deviceID)
		}
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

// TestMemoryStoreInternallySafeConcurrentAccess pins the devicesMutex → per-device
// refactor: the memory store must be safe to access concurrently without any
// caller-held lock, so global admin scans (ListEnrollments) and revocation
// reconciliation (IsRevoked) no longer serialize behind a global mutex. Under
// -race this fails on the old design, where concurrent map writes raced with
// the ListEnrollments scan.
func TestMemoryStoreInternallySafeConcurrentAccess(t *testing.T) {
	store := newMemoryStore(Config{MaxEnrolledDevices: 1000, MaxRevokedDevices: 1000})
	ctx := context.Background()
	stop := make(chan struct{})
	var wg sync.WaitGroup
	// Concurrent writers (enroll + nonce consume) racing with reader scans.
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; ; j++ {
				select {
				case <-stop:
					return
				default:
				}
				id := fmt.Sprintf("device-%d", j%200)
				_, _ = store.PutEnrollment(ctx, &EnrolledDevice{DeviceID: id, PublicKey: "key-" + id})
				_, _ = store.ConsumeNonce(ctx, id, fmt.Sprintf("n-%d", j), time.Now().Add(time.Minute))
				_, _ = store.RecordRevocation(ctx, id, time.Now().Add(time.Minute))
				_ = store.RemoveEnrollment(ctx, id)
			}
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			_, _ = store.ListEnrollments(ctx)
			_, _ = store.CountEnrollments(ctx)
			_, _ = store.IsRevoked(ctx, "device-1", time.Now())
		}
	}()
	time.Sleep(150 * time.Millisecond)
	close(stop)
	wg.Wait()
}
