package relay

import (
	"encoding/hex"
	"encoding/json"
	"net/http"
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
	if _, enrolled := s.enrolledDevices[deviceID]; !enrolled {
		s.devicesMutex.Unlock()
		writeAdminError(w, http.StatusNotFound, adminErrorDeviceNotFound, "The requested device was not found.")
		return
	}
	delete(s.enrolledDevices, deviceID)
	s.revokedDevices[deviceID] = struct{}{}
	delete(s.proofNonces, deviceID)
	s.devicesMutex.Unlock()

	s.hub.disconnectDevice(deviceID)
	w.WriteHeader(http.StatusNoContent)
}
