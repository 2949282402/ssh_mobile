// Regression tests for code-review package B fixes: DSN validation, snapshot
// error propagation, and revocation reconciliation.

package relay

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// TestOpenMySQLStoreRequiresParseTime verifies startup rejects a DSN that would
// silently break time.Scan at runtime.
func TestOpenMySQLStoreRequiresParseTime(t *testing.T) {
	_, err := openMySQLStore(context.Background(), "root:pw@tcp(127.0.0.1:3306)/relay", 100)
	if err == nil || !strings.Contains(err.Error(), "must include parseTime=true") {
		t.Fatalf("expected parseTime validation error before dialing, got %v", err)
	}
}

// TestOpenMySQLStoreRequiresUTCLocation verifies durable generations cannot be
// interpreted in a process-local timezone that differs across Relay instances.
func TestOpenMySQLStoreRequiresUTCLocation(t *testing.T) {
	_, err := openMySQLStore(context.Background(), "root:pw@tcp(127.0.0.1:3306)/relay?parseTime=true&loc=Local", 100)
	if err == nil || !strings.Contains(err.Error(), "location must be UTC") {
		t.Fatalf("expected UTC location validation error before dialing, got %v", err)
	}
}

// failingListStore wraps a working store whose enrollment listing fails.
type failingListStore struct {
	Storage
}

func (failingListStore) ListEnrollments(context.Context) ([]*EnrolledDevice, error) {
	return nil, errors.New("injected storage failure")
}

// TestStatusSnapshotFailsClosedOnStorageError verifies the internal status
// snapshot reports an error (not a misleading "0 devices") when storage is
// unavailable.
func TestStatusSnapshotFailsClosedOnStorageError(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	server.store = failingListStore{Storage: server.store}

	if _, err := server.StatusSnapshot(context.Background()); err == nil {
		t.Fatal("expected an error on storage failure")
	}
}

// TestReconcileRevocationsDisconnectsRevokedDevice verifies a single
// reconciliation sweep disconnects a locally connected device whose revocation
// was missed by the event bus.
func TestReconcileRevocationsDisconnectsRevokedDevice(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	if result := server.replaceEnrollment("device-a", "key-a", "test", RelayBootstrapProtocolVersion, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	injectPeer(server.hub, "device-a")

	outcome, _, err := server.store.RevokeEnrollment(ctx, "device-a", time.Hour)
	if err != nil || outcome != revokeOK {
		t.Fatalf("revoke failed: outcome=%v err=%v", outcome, err)
	}

	server.reconcileRevocationsOnce()

	server.hub.mutex.Lock()
	_, present := server.hub.peers["device-a"]
	server.hub.mutex.Unlock()
	if present {
		t.Fatal("reconciliation did not disconnect the revoked device")
	}
}
