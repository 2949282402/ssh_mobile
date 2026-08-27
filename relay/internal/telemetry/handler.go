// Telemetry HTTP Handlers for Public Ingest and Admin Query APIs.

package telemetry

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const MaxRequestBodyBytes = 1 << 20 // 1MB maximum body

// Handler exposes telemetry HTTP endpoints backed by a Service.
type Handler struct {
	service *Service
}

func NewHandler(service *Service) *Handler {
	return &Handler{service: service}
}

func (h *Handler) RegisterPublicRoutes(mux *http.ServeMux) {
	mux.HandleFunc(RoutePublicAuth, h.handlePublicAuth)
	mux.HandleFunc(RoutePublicIngest, h.handlePublicIngest)
	mux.HandleFunc(RoutePublicPolicy, h.handlePublicPolicy)
}

func (h *Handler) RegisterAdminRoutes(mux *http.ServeMux, adminAuth func(http.HandlerFunc) http.HandlerFunc) {
	mux.HandleFunc(RouteAdminOverview, adminAuth(h.handleAdminOverview))
	mux.HandleFunc(RouteAdminEvents, adminAuth(h.handleAdminEvents))
	mux.HandleFunc(RouteAdminDiagnostics, adminAuth(h.handleAdminDiagnostics))
	mux.HandleFunc(RouteAdminSettings, adminAuth(h.handleAdminSettings))
	mux.HandleFunc(RouteAdminRegisterDevice, adminAuth(h.handleAdminRegisterDevice))
}

func (h *Handler) writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (h *Handler) writeError(w http.ResponseWriter, status int, code, message string) {
	if code == "" {
		code = "TELEMETRY_ERROR"
	}
	h.writeJSON(w, status, map[string]any{
		"error": map[string]string{
			"code":    code,
			"message": message,
		},
		"message": message,
	})
}

// handlePublicAuth verifies device proof-of-possession of its enrolled secret
// and issues a short-lived scoped token bound to the device.
func (h *Handler) handlePublicAuth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		h.writeError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed")
		return
	}
	if h.service == nil || !h.service.Available() {
		h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "telemetry service unavailable")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024)
	var body struct {
		DeviceID string `json:"deviceId"`
		Proof    string `json:"proof"`
		ExpEpoch int64  `json:"expEpoch"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || strings.TrimSpace(body.DeviceID) == "" {
		h.writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request: missing or empty deviceId")
		return
	}
	if !isValidDeviceID(body.DeviceID) {
		h.writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request: invalid deviceId format")
		return
	}

	token, expiresIn, err := h.service.AuthenticateDevice(r.Context(), body.DeviceID, body.Proof, body.ExpEpoch)
	if err != nil {
		switch {
		case errors.Is(err, ErrDeviceNotRegistered):
			h.writeError(w, http.StatusUnauthorized, "DEVICE_NOT_REGISTERED", "device not registered")
		case errors.Is(err, ErrAuthFailed):
			h.writeError(w, http.StatusUnauthorized, "AUTH_FAILED", "device authentication failed")
		default:
			h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "telemetry service unavailable")
		}
		return
	}

	h.writeJSON(w, http.StatusOK, map[string]any{
		"token":     token,
		"expiresIn": expiresIn,
		"deviceId":  body.DeviceID,
	})
}

// handlePublicIngest handles batch telemetry uploads from authenticated devices.
func (h *Handler) handlePublicIngest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		h.writeError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed")
		return
	}
	if h.service == nil || !h.service.Available() {
		h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "telemetry service unavailable")
		return
	}

	// 1. Authenticate Device: token must be valid and bound to X-Device-Id.
	deviceID := strings.TrimSpace(r.Header.Get("X-Device-Id"))
	authHeader := strings.TrimSpace(r.Header.Get("Authorization"))
	token := strings.TrimPrefix(authHeader, "Bearer ")

	if deviceID == "" || token == "" || !h.service.VerifyDeviceToken(deviceID, token) {
		h.writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "unauthorized telemetry device credential")
		return
	}

	// 2. Decode Batch Body
	r.Body = http.MaxBytesReader(w, r.Body, MaxRequestBodyBytes)
	var req IngestBatchRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid batch payload: "+err.Error())
		return
	}

	if len(req.Records) == 0 {
		h.writeJSON(w, http.StatusOK, IngestBatchResponse{Results: []IngestRecordResult{}})
		return
	}

	// Ensure all records in the batch match the authenticated deviceId
	for i := range req.Records {
		req.Records[i].DeviceID = deviceID
	}

	// 3. Process Batch Ingest: server stamps receive time and persists atomically.
	// Any backing-store error surfaces as 503 so the client retries later.
	results, err := h.service.IngestBatch(r.Context(), req.Records)
	if err != nil {
		h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "ingest processing error: "+err.Error())
		return
	}

	h.writeJSON(w, http.StatusOK, IngestBatchResponse{Results: results})
}

// handlePublicPolicy returns the current upload policy for clients.
func (h *Handler) handlePublicPolicy(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		h.writeError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed")
		return
	}
	if h.service == nil || !h.service.StoreAvailable() {
		h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "telemetry service unavailable")
		return
	}

	policy, err := h.service.GetPolicy(r.Context())
	if err != nil {
		h.writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "get policy error: "+err.Error())
		return
	}

	h.writeJSON(w, http.StatusOK, policy)
}

// handleAdminRegisterDevice enrolls a telemetry device and returns a one-time
// secret the device uses to prove ownership during authentication.
//
//	POST /api/admin/v1/telemetry/devices
//	{"deviceId": "..."}  ->  201 {"deviceId": "...", "secret": "<32-byte hex>"}
func (h *Handler) handleAdminRegisterDevice(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		h.writeError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed")
		return
	}
	if h.service == nil {
		h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "telemetry service unavailable")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024)
	var body struct {
		DeviceID string `json:"deviceId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || strings.TrimSpace(body.DeviceID) == "" {
		h.writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request: missing or empty deviceId")
		return
	}
	if !isValidDeviceID(body.DeviceID) {
		h.writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request: invalid deviceId format")
		return
	}
	deviceID := strings.TrimSpace(body.DeviceID)

	randomSecret := make([]byte, 32)
	if _, err := rand.Read(randomSecret); err != nil {
		h.writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to generate device secret")
		return
	}
	secret := hex.EncodeToString(randomSecret)
	if err := h.service.RegisterDeviceCredential(r.Context(), deviceID, hashSecret(secret)); err != nil {
		h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "failed to persist device credential: "+err.Error())
		return
	}

	h.writeJSON(w, http.StatusCreated, map[string]any{
		"deviceId": deviceID,
		"secret":   secret,
	})
}

func parseQueryFilter(r *http.Request) QueryFilter {
	q := r.URL.Query()
	f := QueryFilter{
		TimeRange:  q.Get("timeRange"),
		DeviceID:   q.Get("deviceId"),
		TraceID:    q.Get("traceId"),
		EventName:  q.Get("eventName"),
		Feature:    q.Get("feature"),
		Severity:   Severity(q.Get("severity")),
		ErrorCode:  q.Get("errorCode"),
		AppVersion: q.Get("appVersion"),
		Platform:   q.Get("platform"),
	}

	if st := q.Get("startTime"); st != "" {
		if t, err := time.Parse(time.RFC3339, st); err == nil {
			f.StartTime = t
		}
	}
	if et := q.Get("endTime"); et != "" {
		if t, err := time.Parse(time.RFC3339, et); err == nil {
			f.EndTime = t
		}
	}

	if f.StartTime.IsZero() && f.TimeRange != "" && f.TimeRange != "all" {
		now := time.Now().UTC()
		switch f.TimeRange {
		case "1h":
			f.StartTime = now.Add(-1 * time.Hour)
		case "24h":
			f.StartTime = now.Add(-24 * time.Hour)
		case "7d":
			f.StartTime = now.Add(-7 * 24 * time.Hour)
		case "30d":
			f.StartTime = now.Add(-30 * 24 * time.Hour)
		default:
			if d, err := time.ParseDuration(f.TimeRange); err == nil && d > 0 {
				f.StartTime = now.Add(-d)
			}
		}
		if !f.StartTime.IsZero() && f.EndTime.IsZero() {
			f.EndTime = now
		}
	}

	if p, err := strconv.Atoi(q.Get("page")); err == nil && p > 0 {
		f.Page = p
	} else {
		f.Page = 1
	}

	if ps, err := strconv.Atoi(q.Get("pageSize")); err == nil && ps > 0 && ps <= 200 {
		f.PageSize = ps
	} else {
		f.PageSize = 50
	}

	return f
}

// handleAdminOverview returns aggregated metrics for Admin Dashboard.
func (h *Handler) handleAdminOverview(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		h.writeError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed")
		return
	}
	if h.service == nil || !h.service.StoreAvailable() {
		h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "telemetry service unavailable")
		return
	}

	filter := parseQueryFilter(r)
	metrics, err := h.service.QueryOverview(r.Context(), filter)
	if err != nil {
		h.writeError(w, http.StatusInternalServerError, "QUERY_ERROR", "query overview error: "+err.Error())
		return
	}

	h.writeJSON(w, http.StatusOK, metrics)
}

// handleAdminEvents returns raw events for Event Explorer.
func (h *Handler) handleAdminEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		h.writeError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed")
		return
	}
	if h.service == nil || !h.service.StoreAvailable() {
		h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "telemetry service unavailable")
		return
	}

	filter := parseQueryFilter(r)
	items, total, err := h.service.QueryEvents(r.Context(), filter)
	if err != nil {
		h.writeError(w, http.StatusInternalServerError, "QUERY_ERROR", "query events error: "+err.Error())
		return
	}

	h.writeJSON(w, http.StatusOK, map[string]any{
		"items":    items,
		"total":    total,
		"page":     filter.Page,
		"pageSize": filter.PageSize,
	})
}

// handleAdminDiagnostics returns diagnostic logs for Admin Diagnostic Log Explorer.
func (h *Handler) handleAdminDiagnostics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		h.writeError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed")
		return
	}
	if h.service == nil || !h.service.StoreAvailable() {
		h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "telemetry service unavailable")
		return
	}

	filter := parseQueryFilter(r)
	items, total, source, err := h.service.QueryDiagnostics(r.Context(), filter)
	if err != nil {
		h.writeError(w, http.StatusInternalServerError, "QUERY_ERROR", "query diagnostics error: "+err.Error())
		return
	}

	h.writeJSON(w, http.StatusOK, map[string]any{
		"items":    items,
		"total":    total,
		"page":     filter.Page,
		"pageSize": filter.PageSize,
		"source":   source,
	})
}

// handleAdminSettings handles GET and PUT for Telemetry Settings.
func (h *Handler) handleAdminSettings(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		if h.service == nil || !h.service.StoreAvailable() {
			h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "telemetry service unavailable")
			return
		}
		settings, err := h.service.GetSettings(r.Context())
		if err != nil {
			h.writeError(w, http.StatusInternalServerError, "GET_SETTINGS_ERROR", "get settings error: "+err.Error())
			return
		}
		h.writeJSON(w, http.StatusOK, settings)
	case http.MethodPut:
		if h.service == nil || !h.service.StoreAvailable() {
			h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "telemetry service unavailable")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 64*1024)
		var settings TelemetrySettings
		if err := json.NewDecoder(r.Body).Decode(&settings); err != nil {
			h.writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid settings payload: "+err.Error())
			return
		}
		if err := h.service.UpdateSettings(r.Context(), settings); err != nil {
			h.writeError(w, http.StatusInternalServerError, "UPDATE_SETTINGS_ERROR", "update settings error: "+err.Error())
			return
		}
		h.writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	default:
		h.writeError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed")
	}
}
