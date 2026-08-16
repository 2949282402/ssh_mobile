package relay

import (
	"encoding/json"
	"net/http"
)

// adminErrorResponse 是独立于设备传输协议的管理端错误结构。
type adminErrorResponse struct {
	Error adminErrorDetail `json:"error"`
}

type adminErrorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

const (
	adminErrorUnauthorized   = "unauthorized"
	adminErrorInvalidRequest = "invalid_request"
	adminErrorDeviceNotFound = "device_not_found"
	adminErrorConflict       = "conflict"
	adminErrorInternal       = "internal_error"
	adminErrorForbidden      = "forbidden"
	adminErrorRateLimited    = "rate_limited"
	adminErrorResourceLimit  = "resource_limit"
)

func writeAdminError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(adminErrorResponse{
		Error: adminErrorDetail{Code: code, Message: message},
	})
}
