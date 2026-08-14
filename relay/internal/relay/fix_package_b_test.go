// Regression tests for code-review package B fixes: DSN validation, admin
// snapshot error propagation, and revocation reconciliation.

package relay

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// TestOpenMySQLStoreRequiresParseTime verifies startup rejects a DSN that would
// silently break time.Scan at runtime.
func TestOpenMySQLStoreRequiresParseTime(t *testing.T) {
	if _, err := openMySQLStore(context.Background(), "root:pw@tcp(127.0.0.1:3306)/relay", 100); err == nil {
		t.Fatal("DSN without parseTime=true was accepted")
	}
}

// failingListStore wraps a working store whose enrollment listing fails.
type failingListStore struct {
	Storage
}

func (failingListStore) ListEnrollments(context.Context) ([]*EnrolledDevice, error) {
	return nil, errors.New("injected storage failure")
}

// TestAdminOverviewFailsClosedOnStorageError verifies the admin overview
// reports 500 (not a misleading "0 devices") when storage is unavailable.
func TestAdminOverviewFailsClosedOnStorageError(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	server.store = failingListStore{Storage: server.store}

	request := httptest.NewRequest(http.MethodGet, "/api/admin/v1/overview", nil)
	rec := httptest.NewRecorder()
	server.adminOverview(rec, request)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500 on storage failure, got %d", rec.Code)
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

	if result := server.replaceEnrollment("device-a", "key-a", "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll failed: %v", result)
	}
	injectPeer(server.hub, "device-a")

	recorded, err := server.store.RecordRevocation(ctx, "device-a", time.Now().Add(time.Hour))
	if err != nil || !recorded {
		t.Fatalf("revoke failed: recorded=%v err=%v", recorded, err)
	}

	server.reconcileRevocationsOnce()

	server.hub.mutex.Lock()
	_, present := server.hub.peers["device-a"]
	server.hub.mutex.Unlock()
	if present {
		t.Fatal("reconciliation did not disconnect the revoked device")
	}
}
