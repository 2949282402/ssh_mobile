package relay

import (
	"encoding/hex"
	"encoding/json"
	"net/http"
	"time"
)

func (s *Server) adminToken(w http.ResponseWriter, _ *http.Request) {
	s.devicesMutex.Lock()
	token := s.config.EnrollmentToken
	s.devicesMutex.Unlock()

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"enrollment_token": token,
	})
}

func (s *Server) adminRotateToken(w http.ResponseWriter, _ *http.Request) {
	newToken := hex.EncodeToString(randomBytes(16))
	s.devicesMutex.Lock()
	s.config.EnrollmentToken = newToken
	s.devicesMutex.Unlock()

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"enrollment_token": newToken,
	})
}

func (s *Server) adminRevokeDevice(w http.ResponseWriter, r *http.Request) {
	deviceID := r.PathValue("deviceId")
	if deviceID == "" || len(deviceID) > 128 {
		writeAdminError(w, http.StatusBadRequest, adminErrorInvalidRequest, "Device identity is invalid.")
		return
	}

	s.devicesMutex.Lock()
	enrolled, exists := s.enrolledDevices[deviceID]
	if !exists {
		s.devicesMutex.Unlock()
		writeAdminError(w, http.StatusNotFound, adminErrorDeviceNotFound, "The requested device was not found.")
		return
	}
	// The revoked device's current credential was issued at enrollment and
	// expires CredentialTTL later; the tombstone only needs to outlive that.
	// Guard the degenerate zero EnrolledAt so a fresh, conservative bound is
	// used instead of a tombstone that is already expired.
	credentialExpiry := enrolled.EnrolledAt.Add(s.config.CredentialTTL)
	if enrolled.EnrolledAt.IsZero() {
		credentialExpiry = time.Now().Add(s.config.CredentialTTL)
	}
	if !s.recordRevocationLocked(deviceID, credentialExpiry) {
		s.devicesMutex.Unlock()
		writeAdminError(w, http.StatusTooManyRequests, adminErrorResourceLimit, "Revocation store is at capacity; retry after existing revocations expire.")
		return
	}
	delete(s.enrolledDevices, deviceID)
	delete(s.proofNonces, deviceID)
	s.devicesMutex.Unlock()

	s.hub.disconnectDevice(deviceID)
	w.WriteHeader(http.StatusNoContent)
}
