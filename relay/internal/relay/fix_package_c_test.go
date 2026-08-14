// Regression tests for code-review package C: durable revocation cleanup.

package relay

import (
	"context"
	"testing"
	"time"
)

// TestMySQLStorePrunesExpiredRevocations verifies the periodic sweeper removes
// revocation tombstones whose protected credentials have expired, bounding the
// growth of the durable revocations table.
func TestMySQLStorePrunesExpiredRevocations(t *testing.T) {
	dsn := requireMySQLDSN(t)
	ctx := context.Background()
	store, err := openMySQLStore(ctx, dsn, 100)
	if err != nil {
		t.Fatalf("open mysql store: %v", err)
	}
	defer store.Close()
	if _, err := store.db.ExecContext(ctx, `DELETE FROM revocations WHERE device_id = 'prune-device'`); err != nil {
		t.Fatal(err)
	}

	if recorded, err := store.RecordRevocation(ctx, "prune-device", time.Now().Add(-time.Minute)); err != nil || !recorded {
		t.Fatalf("record stale revocation failed: recorded=%v err=%v", recorded, err)
	}
	if _, present, _ := store.RevocationExpiry(ctx, "prune-device"); !present {
		t.Fatal("stale revocation was not stored")
	}
	if err := store.pruneExpiredRevocations(ctx); err != nil {
		t.Fatal(err)
	}
	if _, present, _ := store.RevocationExpiry(ctx, "prune-device"); present {
		t.Fatal("expired revocation was not pruned")
	}
}
