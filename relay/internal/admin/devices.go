// Administrator device management endpoints (/api/admin/v1/devices).

package admin

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/ssh-mobile/relay/internal/telemetry"
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

	// Invalidate the telemetry bearer credential before revoking the Relay
	// enrollment. This ordering fails closed: if telemetry persistence is
	// unavailable, Relay is left untouched instead of leaving an active token
	// behind. A device without telemetry enrollment is safe to continue.
	if s.telemetryService != nil && s.telemetryService.StoreAvailable() {
		if err := s.telemetryService.RevokeDeviceCredential(ctx, deviceID); err != nil && !errors.Is(err, telemetry.ErrDeviceCredentialNotFound) {
			writeAdminError(w, http.StatusServiceUnavailable, adminErrorInternal, "Telemetry credential store is unavailable; device was not revoked.")
			return
		}
	}

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
