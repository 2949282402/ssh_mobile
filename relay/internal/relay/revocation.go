// Bounded, credential-expiry-aware revocation tombstone store.
//
// The tombstone semantics below are implemented by memoryStore.RecordRevocation
// and memoryStore.IsRevoked in storage.go.

package relay

import "time"

// revokedDevice is a revocation tombstone that remains in force only while the
// revoked device's most recent credential could still be presented.
//
// A device's credential is issued at enrollment time and expires after the
// process-wide CredentialTTL. Enrollment time is captured just after issuance,
// so a credential can never outlive EnrolledAt + CredentialTTL. Therefore the
// tombstone's recorded expiresAt (EnrolledAt + CredentialTTL) is a safe upper
// bound on the real credential expiry: evicting a tombstone whose recorded
// expiry has passed cannot reauthorize a still-revoked credential, because by
// that time the underlying credential has already expired and verifyCredential
// rejects it.
//
// When the store is saturated with tombstones that are still in force, new
// revocations are rejected (fail closed) rather than evicting an older
// tombstone. Dropping an in-force tombstone could silently reauthorize a
// revoked credential; rejecting a new revocation instead leaves the target
// device enrolled but keeps every previously revoked credential permanently
// unusable. The operator must wait for in-force tombstones to expire (or
// restart, which clears all in-memory state) before revoking again.
type revokedDevice struct {
	expiresAt time.Time
}
