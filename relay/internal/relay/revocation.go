// Bounded, credential-expiry-aware revocation tombstone store.
//
// The tombstone semantics below are implemented by memoryStore.RecordRevocation,
// memoryStore.RevokeEnrollment and memoryStore.IsRevoked in storage.go.
// RevokeEnrollment is the atomic composite (tombstone + enrollment removal)
// behind the revoke path: the memory store runs it inside one deviceMu
// critical section, and the MySQL store runs it as a single transaction (device
// row FOR UPDATE first) so a cross-instance re-enroll serializes against it.

package relay

import "time"

// revokedDevice is a revocation tombstone that remains in force only while the
// revoked device's most recent credential could still be presented.
//
// A device can refresh its credential at any time while enrolled, so
// EnrolledAt + CredentialTTL is not a safe upper bound. Revocation records
// revoke-time + CredentialTTL instead: even a credential issued immediately
// before the revoke has expired by then. This longer bound also lets an
// instance that missed the revoke event close an existing connection during
// periodic reconciliation.
//
// When the store is saturated with tombstones that are still in force, new
// revocations are rejected (fail closed) rather than evicting an older
// tombstone. Dropping an in-force tombstone could silently reauthorize a
// revoked credential; rejecting a new revocation instead leaves the target
// device enrolled but keeps every previously revoked credential permanently
// unusable. The operator must wait for in-force tombstones to expire (or
// restart, which clears all in-memory state) before revoking again.
type revokedDevice struct {
	expiresAt       time.Time
	generationFloor time.Time
}
