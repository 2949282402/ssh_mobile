// Administrator device management endpoints (/api/admin/v1/devices).

package admin

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
)

func (s *Server) devicesHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), adminOperationTimeout)
	defer cancel()

	devices, err := s.relayClient.Devices(ctx)
	if err != nil {
		if errors.Is(err, ErrRelayUnavailable) {
			writeAdminError(w, http.StatusServiceUnavailable, adminErrorRelayUnavailable, "Relay service is unavailable.")
			return
		}
		writeAdminError(w, http.StatusInternalServerError, adminErrorInternal, "Failed to list relay devices.")
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(devices)
}

func (s *Server) revokeHandler(w http.ResponseWriter, r *http.Request) {
	deviceID := r.PathValue("deviceId")
	if deviceID == "" || len(deviceID) > 128 {
		writeAdminError(w, http.StatusBadRequest, adminErrorInvalidRequest, "Device identity is invalid.")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), adminOperationTimeout)
	defer cancel()

	err := s.relayClient.RevokeDevice(ctx, deviceID)
	if err != nil {
		switch {
		case errors.Is(err, ErrDeviceNotFound):
			writeAdminError(w, http.StatusNotFound, adminErrorDeviceNotFound, "The requested device was not found.")
		case errors.Is(err, ErrResourceLimit):
			writeAdminError(w, http.StatusTooManyRequests, adminErrorResourceLimit, "Revocation store is at capacity; retry later.")
		case errors.Is(err, ErrRelayUnavailable):
			writeAdminError(w, http.StatusServiceUnavailable, adminErrorRelayUnavailable, "Relay service is unavailable.")
		default:
			writeAdminError(w, http.StatusInternalServerError, adminErrorInternal, "Failed to revoke device.")
		}
		return
	}

	w.WriteHeader(http.StatusNoContent)
}
