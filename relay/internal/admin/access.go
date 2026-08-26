// Administrator access token management endpoints (/api/admin/v1/access/*).

package admin

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
)

func (s *Server) tokenHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), adminOperationTimeout)
	defer cancel()

	tokenInfo, err := s.relayClient.EnrollmentToken(ctx)
	if err != nil {
		if errors.Is(err, ErrRelayUnavailable) {
			writeAdminError(w, http.StatusServiceUnavailable, adminErrorRelayUnavailable, "Relay service is unavailable.")
			return
		}
		writeAdminError(w, http.StatusInternalServerError, adminErrorInternal, "Failed to retrieve enrollment token.")
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(tokenInfo)
}

func (s *Server) rotateTokenHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), adminOperationTimeout)
	defer cancel()

	tokenInfo, err := s.relayClient.RotateEnrollmentToken(ctx)
	if err != nil {
		switch {
		case errors.Is(err, ErrConflict):
			writeAdminError(w, http.StatusConflict, adminErrorConflict,
				"Persistent deployments must rotate RELAY_ENROLLMENT_TOKEN and restart all Relay instances.")
		case errors.Is(err, ErrRelayUnavailable):
			writeAdminError(w, http.StatusServiceUnavailable, adminErrorRelayUnavailable, "Relay service is unavailable.")
		default:
			writeAdminError(w, http.StatusInternalServerError, adminErrorInternal, "Failed to rotate enrollment token.")
		}
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(tokenInfo)
}
