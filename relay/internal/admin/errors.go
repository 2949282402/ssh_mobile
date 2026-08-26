// Admin API error definitions and response rendering.

package admin

import (
	"encoding/json"
	"net/http"
)

const (
	adminErrorInvalidRequest      = "invalid_request"
	adminErrorAuthenticationFailed = "authentication_failed"
	adminErrorResourceLimit       = "resource_limit"
	adminErrorConflict            = "conflict"
	adminErrorDeviceNotFound      = "device_not_found"
	adminErrorInternal            = "internal_error"
	adminErrorRelayUnavailable    = "relay_unavailable"
)

type adminErrorEnvelope struct {
	Error adminErrorBody `json:"error"`
}

type adminErrorBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func writeAdminError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(adminErrorEnvelope{
		Error: adminErrorBody{Code: code, Message: message},
	})
}
