// Bounded, credential-expiry-aware revocation tombstone store.

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

// recordRevocationLocked records deviceID as revoked until credentialExpiry.
// The caller must hold s.devicesMutex. It returns false when the bounded store
// is saturated with still-in-force tombstones (fail closed). Expired
// tombstones are pruned first so capacity is reused as soon as it is safe.
func (s *Server) recordRevocationLocked(deviceID string, credentialExpiry time.Time) bool {
	now := time.Now()
	s.pruneExpiredRevocationsLocked(now)
	if existing, alreadyRevoked := s.revokedDevices[deviceID]; alreadyRevoked {
		if credentialExpiry.After(existing.expiresAt) {
			s.revokedDevices[deviceID] = revokedDevice{expiresAt: credentialExpiry}
		}
		return true
	}
	if len(s.revokedDevices) >= s.config.MaxRevokedDevices {
		return false
	}
	s.revokedDevices[deviceID] = revokedDevice{expiresAt: credentialExpiry}
	return true
}

// pruneExpiredRevocationsLocked removes tombstones whose protected credentials
// have expired. The caller must hold s.devicesMutex.
func (s *Server) pruneExpiredRevocationsLocked(now time.Time) {
	for id, entry := range s.revokedDevices {
		if !now.Before(entry.expiresAt) {
			delete(s.revokedDevices, id)
		}
	}
}
