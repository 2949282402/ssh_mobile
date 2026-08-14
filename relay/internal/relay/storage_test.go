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
