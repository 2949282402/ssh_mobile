// Administrator overview endpoint (/api/admin/v1/overview).

package admin

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"
)

const adminOperationTimeout = 5 * time.Second

func (s *Server) overviewHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), adminOperationTimeout)
	defer cancel()

	status, err := s.relayClient.Status(ctx)
	if err != nil {
		if errors.Is(err, ErrRelayUnavailable) {
			writeAdminError(w, http.StatusServiceUnavailable, adminErrorRelayUnavailable, "Relay service is unavailable.")
			return
		}
		writeAdminError(w, http.StatusInternalServerError, adminErrorInternal, "Failed to load relay overview.")
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(status)
}
