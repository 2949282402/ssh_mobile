// Telemetry HTTP Handlers for Public Ingest and Admin Query APIs.

package telemetry

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const MaxRequestBodyBytes = 1 << 20 // 1MB maximum body

// Handler exposes telemetry HTTP endpoints backed by a Service.
type Handler struct {
	service  *Service
	attestor DeviceAttestor
	config   IngestConfig
	writer   chan struct{}
	limiter  *deviceRateLimiter
	logger   *slog.Logger
}

// NewHandler creates a telemetry handler. The optional attestor keeps existing
// callers source-compatible while allowing Admin to inject the Relay-backed
// device identity capability.
func NewHandler(service *Service, attestors ...DeviceAttestor) *Handler {
	return NewHandlerWithConfig(service, DefaultIngestConfig(), attestors...)
}

// NewHandlerWithConfig creates a telemetry handler with explicit bounded
// ingestion limits. The config is normalized to safe hard bounds before any
// request can acquire a writer slot or create a rate-limit entry.
func NewHandlerWithConfig(service *Service, config IngestConfig, attestors ...DeviceAttestor) *Handler {
	config = normalizeIngestConfig(config)
	var attestor DeviceAttestor
	if len(attestors) > 0 {
		attestor = attestors[0]
	}
	return &Handler{
		service:  service,
		attestor: attestor,
		config:   config,
		writer:   make(chan struct{}, config.MaxConcurrentWriters),
		limiter:  newDeviceRateLimiter(config),
		logger:   slog.Default(),
	}
}

// WithLogger injects the structured logger used to record internal error
// detail that must not be exposed to HTTP clients.
func (h *Handler) WithLogger(logger *slog.Logger) *Handler {
	if logger == nil {
		logger = slog.Default()
	}
	h.logger = logger
	return h
}

func (h *Handler) logError(message string, err error) {
	logger := h.logger
	if logger == nil {
		logger = slog.Default()
	}
	logger.Error(message, "error", err)
}

func (h *Handler) RegisterPublicRoutes(mux *http.ServeMux) {
	mux.HandleFunc(RoutePublicEnroll, h.handlePublicEnroll)
	mux.HandleFunc(RoutePublicRotate, h.handlePublicRotate)
	mux.HandleFunc(RoutePublicAuth, h.handlePublicAuth)
	mux.HandleFunc(RoutePublicIngest, h.handlePublicIngest)
	mux.HandleFunc(RoutePublicPolicy, h.handlePublicPolicy)
}

// handlePublicEnroll creates the telemetry credential for a device that proves
// possession of its existing Relay enrollment. Relay validates the proof; the
// telemetry service never receives or persists Relay signing material.
func (h *Handler) handlePublicEnroll(w http.ResponseWriter, r *http.Request) {
	h.handlePublicCredential(w, r, false)
}

func (h *Handler) handlePublicRotate(w http.ResponseWriter, r *http.Request) {
	h.handlePublicCredential(w, r, true)
}

func (h *Handler) handlePublicCredential(w http.ResponseWriter, r *http.Request, rotate bool) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		h.writeError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed")
		return
	}
	if h.service == nil || !h.service.Available() {
		h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "telemetry service unavailable")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024)
	var request TelemetryEnrollmentRequest
	if err := decodeStrictJSON(r.Body, &request); err != nil {
		h.writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid enrollment request")
		return
	}
	if strings.TrimSpace(request.DeviceID) == "" || !isValidDeviceID(request.DeviceID) || strings.TrimSpace(request.DeviceID) != request.DeviceID {
		h.writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request: invalid deviceId format")
		return
	}

	var response TelemetryEnrollmentResponse
	var err error
	if rotate {
		response, err = h.service.RotateDevice(r.Context(), request, h.attestor)
	} else {
		response, err = h.service.EnrollDevice(r.Context(), request, h.attestor)
	}
	if err != nil {
		switch {
		case errors.Is(err, ErrEnrollmentInvalidRequest), errors.Is(err, ErrEnrollmentProofFailed):
			h.writeError(w, http.StatusUnauthorized, "AUTH_FAILED", "device enrollment proof failed")
		case errors.Is(err, ErrEnrollmentAlreadyExists):
			h.writeError(w, http.StatusConflict, "ALREADY_ENROLLED", "telemetry credential already enrolled")
		case errors.Is(err, ErrEnrollmentCredentialMissing):
			h.writeError(w, http.StatusNotFound, "NOT_ENROLLED", "telemetry credential is not enrolled")
		default:
			h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "telemetry service unavailable")
		}
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	status := http.StatusCreated
	if rotate {
		status = http.StatusOK
	}
	h.writeJSON(w, status, response)
}

func (h *Handler) RegisterAdminRoutes(mux *http.ServeMux, adminAuth func(http.HandlerFunc) http.HandlerFunc) {
	mux.HandleFunc(RouteAdminOverview, adminAuth(h.handleAdminOverview))
	mux.HandleFunc(RouteAdminEvents, adminAuth(h.handleAdminEvents))
	mux.HandleFunc(RouteAdminDiagnostics, adminAuth(h.handleAdminDiagnostics))
	mux.HandleFunc(RouteAdminSettings, adminAuth(h.handleAdminSettings))
}

func (h *Handler) writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (h *Handler) writeError(w http.ResponseWriter, status int, code, message string) {
	if code == "" {
		code = "TELEMETRY_ERROR"
	}
	message = sanitizeDiagnosticText(message, MaxDiagnosticMessageLength)
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
	if err := decodeStrictJSON(r.Body, &body); err != nil || strings.TrimSpace(body.DeviceID) == "" {
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

	// Reject a known oversize body before authentication, JSON decoding, or any
	// request-specific state allocation. Chunked/unknown-length bodies are
	// bounded below by MaxBytesReader and classified after decoding.
	if r.ContentLength > h.config.MaxBodyBytes {
		h.writeError(w, http.StatusRequestEntityTooLarge, "PAYLOAD_TOO_LARGE", fmt.Sprintf("telemetry request body exceeds %d bytes", h.config.MaxBodyBytes))
		return
	}

	// 1. Authenticate Device: token must be valid and bound to X-Device-Id.
	deviceID := strings.TrimSpace(r.Header.Get("X-Device-Id"))
	authHeader := strings.TrimSpace(r.Header.Get("Authorization"))
	token := strings.TrimSpace(strings.TrimPrefix(authHeader, "Bearer "))

	if deviceID == "" || token == "" || !h.service.VerifyDeviceTokenAt(r.Context(), deviceID, token) {
		h.writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "unauthorized telemetry device credential")
		return
	}

	// 2. Decode Batch Body
	r.Body = http.MaxBytesReader(w, r.Body, h.config.MaxBodyBytes)
	var req IngestBatchRequest
	if err := decodeStrictJSON(r.Body, &req); err != nil {
		if isMaxBytesError(err) {
			h.writeError(w, http.StatusRequestEntityTooLarge, "PAYLOAD_TOO_LARGE", fmt.Sprintf("telemetry request body exceeds %d bytes", h.config.MaxBodyBytes))
			return
		}
		h.writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid batch payload")
		return
	}

	if len(req.Records) == 0 {
		h.writeJSON(w, http.StatusOK, IngestBatchResponse{Results: []IngestRecordResult{}})
		return
	}
	if len(req.Records) > h.config.MaxBatchSize {
		h.writeError(w, http.StatusRequestEntityTooLarge, "BATCH_TOO_LARGE", fmt.Sprintf("telemetry batch contains %d records; maximum is %d", len(req.Records), h.config.MaxBatchSize))
		return
	}

	// The body field remains optional at the decoding boundary for legacy
	// partial batches, but when present it is an authenticated binding and must
	// agree with the header. Never overwrite a non-empty client value after
	// authentication: doing so would hide a confused-deputy or replay attempt
	// from validation and auditing. Whitespace-only values are treated as
	// absent and stamped from the verified header so legacy batches keep the
	// authenticated identity instead of failing catalog validation.
	for i := range req.Records {
		if strings.TrimSpace(req.Records[i].DeviceID) != "" && req.Records[i].DeviceID != deviceID {
			h.writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "telemetry record deviceId does not match authenticated device")
			return
		}
	}
	for i := range req.Records {
		if strings.TrimSpace(req.Records[i].DeviceID) == "" {
			req.Records[i].DeviceID = deviceID
		}
	}

	// Admission is intentionally after token verification. The client-provided
	// header cannot create or consume a bucket for another device, and invalid
	// credentials never consume bounded rate-limit state.
	if allowed, retryAfter := h.limiter.allow(deviceID, h.config.Clock()); !allowed {
		h.writeIngestRetryError(w, ErrIngestRateLimited, retryAfter)
		return
	}

	// Try the bounded writer gate without waiting. A waiting HTTP request would
	// consume a server goroutine and permit an otherwise avoidable queue to grow.
	select {
	case h.writer <- struct{}{}:
		defer func() { <-h.writer }()
	default:
		h.writeIngestRetryError(w, ErrIngestOverloaded, time.Duration(h.config.RetryAfterSeconds)*time.Second)
		return
	}

	// 3. Process Batch Ingest: server stamps receive time and persists atomically.
	// Any backing-store error surfaces as 503 so the client retries later.
	results, err := h.service.IngestBatch(r.Context(), req.Records)
	if err != nil {
		h.logError("telemetry ingest processing failed", err)
		h.writeError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "telemetry ingest processing failed")
		return
	}

	h.writeJSON(w, http.StatusOK, IngestBatchResponse{Results: results})
}

func isMaxBytesError(err error) bool {
	var maxErr *http.MaxBytesError
	return errors.As(err, &maxErr)
}

func (h *Handler) writeIngestRetryError(w http.ResponseWriter, err *ingestAdmissionError, retryAfter time.Duration) {
	seconds64 := int64(1)
	if retryAfter > 0 {
		// Subtract before rounding up so a maximum-duration input cannot
		// overflow while adding one second. The response is always bounded by
		// the normalized configuration below.
		seconds64 = int64((retryAfter-1)/time.Second) + 1
	}
	ceiling := maxIngestRetryAfterSeconds
	if h != nil && h.config.RetryAfterSeconds > 0 && h.config.RetryAfterSeconds < ceiling {
		ceiling = h.config.RetryAfterSeconds
	}
	if seconds64 > int64(ceiling) {
		seconds64 = int64(ceiling)
	}
	seconds := int(seconds64)
	w.Header().Set("Retry-After", strconv.Itoa(seconds))
	h.writeError(w, http.StatusTooManyRequests, err.Code(), fmt.Sprintf("%s; retry after %d seconds", err.Error(), seconds))
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
		h.logError("telemetry policy query failed", err)
		h.writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "telemetry policy query failed")
		return
	}

	h.writeJSON(w, http.StatusOK, policy)
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
		h.logError("telemetry overview query failed", err)
		h.writeError(w, http.StatusInternalServerError, "QUERY_ERROR", "telemetry overview query failed")
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
		h.logError("telemetry events query failed", err)
		h.writeError(w, http.StatusInternalServerError, "QUERY_ERROR", "telemetry events query failed")
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
		h.logError("telemetry diagnostics query failed", err)
		h.writeError(w, http.StatusInternalServerError, "QUERY_ERROR", "telemetry diagnostics query failed")
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
			h.logError("telemetry settings read failed", err)
			h.writeError(w, http.StatusInternalServerError, "GET_SETTINGS_ERROR", "telemetry settings read failed")
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
		if err := decodeStrictJSON(r.Body, &settings); err != nil {
			h.writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid settings payload")
			return
		}
		if err := h.service.UpdateSettings(r.Context(), settings); err != nil {
			if errors.Is(err, ErrPolicyVersionConflict) {
				h.writeError(w, http.StatusConflict, "POLICY_VERSION_CONFLICT", "telemetry policy is newer; reload settings before updating")
				return
			}
			h.logError("telemetry settings update failed", err)
			h.writeError(w, http.StatusInternalServerError, "UPDATE_SETTINGS_ERROR", "telemetry settings update failed")
			return
		}
		h.writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	default:
		h.writeError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed")
	}
}
