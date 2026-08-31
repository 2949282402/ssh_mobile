// Relay internal management application service and HTTP API (/internal/v2/*).
// Authenticated via Authorization: Bearer <RELAY_INTERNAL_TOKEN>.

package relay

import (
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"runtime"
	"sort"
	"strings"
	"time"
)

// RevokeOutcome represents the typed result of a device revocation.
type RevokeOutcome int

const (
	RevokeStatusOK RevokeOutcome = iota
	RevokeStatusNotFound
	RevokeStatusCapacity
	RevokeStatusUnavailable
	RevokeStatusTimeout
)

var (
	ErrTokenRotationUnsupported        = errors.New("token rotation is not supported in persistent storage mode")
	errTelemetryAttestationInvalid     = errors.New("telemetry attestation is invalid")
	errTelemetryAttestationUnavailable = errors.New("telemetry attestation is unavailable")
)

type internalTelemetryAttestationRequest struct {
	DeviceID        string `json:"device_id"`
	RelayCredential string `json:"relay_credential"`
	PublicKey       string `json:"public_key"`
	Timestamp       int64  `json:"timestamp"`
	Nonce           string `json:"nonce"`
	Signature       string `json:"signature"`
	TranscriptPath  string `json:"transcript_path,omitempty"`
}

type internalTelemetryAttestationResponse struct {
	DeviceID             string `json:"device_id"`
	EnrollmentGeneration int64  `json:"enrollment_generation"`
	ProtocolVersion      uint32 `json:"protocol_version"`
}

type internalStatusResponse struct {
	ServerTime        int64               `json:"server_time"`
	UptimeSeconds     int64               `json:"uptime_seconds"`
	Devices           internalDeviceStat  `json:"devices"`
	Relay             internalRelayStat   `json:"relay"`
	Runtime           internalRuntimeStat `json:"runtime"`
	PresenceAvailable bool                `json:"presence_available"`
}

type internalDeviceStat struct {
	Enrolled int `json:"enrolled"`
	Online   int `json:"online"`
}

type internalRelayStat struct {
	ActiveTransfers int `json:"active_transfers"`
}

type internalRuntimeStat struct {
	AllocatedMemMB float64 `json:"allocated_mem_mb"`
	Goroutines     int     `json:"goroutines"`
}

type internalDevicesResponse struct {
	Items             []internalDevice `json:"items"`
	Total             int              `json:"total"`
	PresenceAvailable bool             `json:"presence_available"`
}

type internalDevice struct {
	DeviceID             string `json:"device_id"`
	Platform             string `json:"platform"`
	ProtocolVersion      uint32 `json:"protocol_version"`
	EnrolledAt           string `json:"enrolled_at"`
	Online               bool   `json:"online"`
	RemoteAddr           string `json:"remote_addr"`
	PublicKeyFingerprint string `json:"public_key_fingerprint"`
}

const internalSnapshotTimeout = 5 * time.Second

// RevokeDevice performs authoritative revocation of a device across durable storage,
// active sockets, presence, and event bus.
func (s *Server) RevokeDevice(ctx context.Context, deviceID string) (RevokeOutcome, error) {
	if deviceID == "" || len(deviceID) > 128 {
		return RevokeStatusNotFound, errors.New("device identity is invalid")
	}

	opCtx, cancel := context.WithTimeout(ctx, deviceSecurityOperationTimeout)
	defer cancel()

	unlock, locked := s.lockDeviceContext(opCtx, deviceID)
	if !locked {
		return RevokeStatusTimeout, errors.New("revocation operation lock timeout")
	}

	outcome, generation, err := s.store.RevokeEnrollment(opCtx, deviceID, s.config.CredentialTTL)
	if err != nil {
		unlock()
		return RevokeStatusUnavailable, err
	}

	switch outcome {
	case revokeNotEnrolled:
		unlock()
		return RevokeStatusNotFound, nil
	case revokeCapacity:
		unlock()
		return RevokeStatusCapacity, nil
	}

	// Authoritative local teardown
	s.relayData.closeDevice(deviceID)
	s.hub.disconnectDevice(deviceID)
	s.hub.forgetDiscoveryPublish(deviceID)
	unlock()

	// Broadcast revocation event to peer Relay instances
	publishCtx, publishCancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	defer publishCancel()
	if err := s.cache.Publish(publishCtx, RelayEvent{
		Type:                 eventDeviceRevoked,
		DeviceID:             deviceID,
		EnrollmentGeneration: generation,
		Time:                 time.Now().UnixMilli(),
	}); err != nil {
		s.logger.Warn("failed to publish revocation event; other instances may not disconnect",
			"device_id", deviceID, "error", err)
	}

	return RevokeStatusOK, nil
}

// StatusSnapshot returns a point-in-time runtime snapshot of the Relay service.
func (s *Server) StatusSnapshot(ctx context.Context) (internalStatusResponse, error) {
	enrolledList, err := s.store.ListEnrollments(ctx)
	if err != nil {
		return internalStatusResponse{}, err
	}
	enrolled := len(enrolledList)
	deviceIDs := make([]string, 0, enrolled)
	for _, device := range enrolledList {
		deviceIDs = append(deviceIDs, device.DeviceID)
	}
	presences, presenceErr := s.cache.GetPresences(ctx, deviceIDs)
	presenceAvailable := presenceErr == nil
	if presenceErr != nil {
		s.logger.Warn("presence cache unavailable; online status is unknown", "error", presenceErr)
	}
	if presenceErr == nil && presences == nil {
		presences = map[string]Presence{}
	}
	online := len(presences)

	var memory runtime.MemStats
	runtime.ReadMemStats(&memory)

	return internalStatusResponse{
		ServerTime:        time.Now().Unix(),
		UptimeSeconds:     int64(time.Since(s.startedAt).Seconds()),
		Devices:           internalDeviceStat{Enrolled: enrolled, Online: online},
		Relay:             internalRelayStat{ActiveTransfers: s.relayData.activePairCount()},
		Runtime:           internalRuntimeStat{AllocatedMemMB: float64(memory.Alloc) / 1024 / 1024, Goroutines: runtime.NumGoroutine()},
		PresenceAvailable: presenceAvailable,
	}, nil
}

// ListDevices returns the list of all enrolled devices and their presence status.
func (s *Server) ListDevices(ctx context.Context) ([]internalDevice, bool, error) {
	enrolledList, err := s.store.ListEnrollments(ctx)
	if err != nil {
		return nil, false, err
	}
	deviceIDs := make([]string, 0, len(enrolledList))
	for _, enrolled := range enrolledList {
		deviceIDs = append(deviceIDs, enrolled.DeviceID)
	}
	presences, presenceErr := s.cache.GetPresences(ctx, deviceIDs)
	presenceAvailable := presenceErr == nil
	if presenceErr != nil {
		s.logger.Warn("presence cache unavailable; online status is unknown", "error", presenceErr)
	}
	if presenceErr == nil && presences == nil {
		presences = map[string]Presence{}
	}
	items := make([]internalDevice, 0, len(enrolledList))
	for _, enrolled := range enrolledList {
		presence, online := presences[enrolled.DeviceID]
		items = append(items, internalDevice{
			DeviceID:             enrolled.DeviceID,
			Platform:             enrolled.Platform,
			ProtocolVersion:      enrolled.ProtocolVersion,
			EnrolledAt:           enrolled.EnrolledAt.UTC().Format(time.RFC3339Nano),
			Online:               online,
			RemoteAddr:           presence.RemoteAddr,
			PublicKeyFingerprint: publicKeyFingerprint(enrolled.PublicKey),
		})
	}
	sort.Slice(items, func(i, j int) bool {
		return items[i].DeviceID < items[j].DeviceID
	})
	return items, presenceAvailable, nil
}

func publicKeyFingerprint(encodedPublicKey string) string {
	publicKey, err := base64.RawURLEncoding.DecodeString(encodedPublicKey)
	if err != nil {
		return ""
	}
	digest := sha256.Sum256(publicKey)
	return "SHA256:" + base64.RawStdEncoding.EncodeToString(digest[:])
}

// GetEnrollmentToken returns the current active enrollment token.
func (s *Server) GetEnrollmentToken() string {
	s.tokenMutex.Lock()
	defer s.tokenMutex.Unlock()
	return s.config.EnrollmentToken
}

// RotateEnrollmentToken rotates the enrollment token for memory-mode deployments.
func (s *Server) RotateEnrollmentToken() (string, error) {
	if s.config.StorageMode == "mysql" {
		return "", ErrTokenRotationUnsupported
	}
	newToken := hex.EncodeToString(randomBytes(16))
	s.tokenMutex.Lock()
	s.config.EnrollmentToken = newToken
	s.tokenMutex.Unlock()
	return newToken, nil
}

// ---------------------------------------------------------------------------
// Internal HTTP Handlers (/internal/v2/*)
// ---------------------------------------------------------------------------

func (s *Server) internalAuthMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		token := strings.TrimPrefix(authHeader, "Bearer ")
		if token == authHeader || token == "" || len(s.config.InternalToken) == 0 || !hmac.Equal([]byte(token), []byte(s.config.InternalToken)) {
			writeNetworkError(w, http.StatusUnauthorized, relayErrorAuthenticationFailed,
				"Internal management authentication failed.", "internal_auth", "")
			return
		}
		next(w, r)
	}
}

func (s *Server) internalStatusHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")

	ctx, cancel := context.WithTimeout(r.Context(), internalSnapshotTimeout)
	defer cancel()

	snapshot, err := s.StatusSnapshot(ctx)
	if err != nil {
		writeNetworkError(w, http.StatusInternalServerError, relayErrorRelayError,
			"Relay storage unavailable.", "internal_status", "")
		return
	}
	_ = json.NewEncoder(w).Encode(snapshot)
}

func (s *Server) internalDevicesHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")

	ctx, cancel := context.WithTimeout(r.Context(), internalSnapshotTimeout)
	defer cancel()

	items, presenceAvailable, err := s.ListDevices(ctx)
	if err != nil {
		writeNetworkError(w, http.StatusInternalServerError, relayErrorRelayError,
			"Relay storage unavailable.", "internal_devices", "")
		return
	}
	_ = json.NewEncoder(w).Encode(internalDevicesResponse{
		Items:             items,
		Total:             len(items),
		PresenceAvailable: presenceAvailable,
	})
}

func (s *Server) internalRevokeDeviceHandler(w http.ResponseWriter, r *http.Request) {
	deviceID := r.PathValue("deviceId")
	if deviceID == "" || len(deviceID) > 128 {
		writeNetworkError(w, http.StatusBadRequest, relayErrorInvalidArgument,
			"Device identity is invalid.", "internal_revoke", "")
		return
	}

	outcome, err := s.RevokeDevice(r.Context(), deviceID)
	if err != nil {
		switch outcome {
		case RevokeStatusTimeout:
			writeNetworkError(w, http.StatusServiceUnavailable, relayErrorRelayError,
				"Revocation operation timed out.", "internal_revoke", deviceID)
		default:
			writeNetworkError(w, http.StatusInternalServerError, relayErrorRelayError,
				"Revocation store unavailable.", "internal_revoke", deviceID)
		}
		return
	}

	switch outcome {
	case RevokeStatusNotFound:
		writeNetworkError(w, http.StatusNotFound, relayErrorInvalidArgument,
			"Device not found.", "internal_revoke", deviceID)
		return
	case RevokeStatusCapacity:
		writeNetworkError(w, http.StatusTooManyRequests, relayErrorRelayError,
			"Revocation capacity reached.", "internal_revoke", deviceID)
		return
	case RevokeStatusOK:
		w.WriteHeader(http.StatusNoContent)
	}
}

func (s *Server) internalTokenHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"enrollment_token": s.GetEnrollmentToken(),
	})
}

func (s *Server) internalRotateTokenHandler(w http.ResponseWriter, _ *http.Request) {
	newToken, err := s.RotateEnrollmentToken()
	if err != nil {
		if errors.Is(err, ErrTokenRotationUnsupported) {
			writeNetworkError(w, http.StatusConflict, relayErrorInvalidArgument,
				"Persistent deployments must rotate RELAY_ENROLLMENT_TOKEN and restart all Relay instances.",
				"internal_rotate_token", "")
			return
		}
		writeNetworkError(w, http.StatusInternalServerError, relayErrorRelayError,
			"Failed to rotate enrollment token.", "internal_rotate_token", "")
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"enrollment_token": newToken,
	})
}

// internalTelemetryAttestationHandler validates a device's proof of the
// existing Relay enrollment. It returns enrollment metadata only; Relay never
// writes to the Analytics store and never returns a telemetry secret.
func (s *Server) internalTelemetryAttestationHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		writeNetworkError(w, http.StatusMethodNotAllowed, relayErrorInvalidArgument,
			"Method not allowed.", "internal_telemetry_attest", "")
		return
	}
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, 64*1024)
	var request internalTelemetryAttestationRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeNetworkError(w, http.StatusBadRequest, relayErrorInvalidArgument,
			"Telemetry attestation request is invalid.", "internal_telemetry_attest", "")
		return
	}
	if pathDeviceID := r.PathValue("deviceId"); pathDeviceID != "" && pathDeviceID != request.DeviceID {
		writeNetworkError(w, http.StatusUnauthorized, relayErrorAuthenticationFailed,
			"Relay device authentication failed.", "internal_telemetry_attest", "")
		return
	}

	response, err := s.validateTelemetryAttestation(r.Context(), request)
	if err != nil {
		if errors.Is(err, errTelemetryAttestationUnavailable) {
			writeNetworkErrorRetry(w, http.StatusServiceUnavailable, relayErrorRelayError,
				"Relay telemetry attestation is unavailable.", "internal_telemetry_attest", request.DeviceID,
				retryWithBackoff, 0)
			return
		}
		writeNetworkError(w, http.StatusUnauthorized, relayErrorAuthenticationFailed,
			"Relay device authentication failed.", "internal_telemetry_attest", request.DeviceID)
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(response)
}

// validateTelemetryAttestation is deliberately separate from the HTTP
// handler so the internal capability follows the same credential, identity,
// freshness, enrollment-generation, revocation, and nonce rules as the device
// WebSocket admission path.
func (s *Server) validateTelemetryAttestation(ctx context.Context, request internalTelemetryAttestationRequest) (internalTelemetryAttestationResponse, error) {
	if request.DeviceID == "" || len(request.DeviceID) > 128 || strings.TrimSpace(request.DeviceID) != request.DeviceID ||
		request.Timestamp <= 0 || strings.TrimSpace(request.RelayCredential) == "" ||
		strings.TrimSpace(request.PublicKey) == "" || strings.TrimSpace(request.Nonce) == "" ||
		strings.TrimSpace(request.Signature) == "" {
		return internalTelemetryAttestationResponse{}, errTelemetryAttestationInvalid
	}

	claims, credentialPublicKey, err := verifyCredential(s.config.CredentialKey, request.RelayCredential)
	if err != nil || claims.DeviceID != request.DeviceID {
		return internalTelemetryAttestationResponse{}, errTelemetryAttestationInvalid
	}
	presentedPublicKey, err := base64.RawURLEncoding.DecodeString(request.PublicKey)
	if err != nil || len(presentedPublicKey) != ed25519.PublicKeySize ||
		base64.RawURLEncoding.EncodeToString(presentedPublicKey) != request.PublicKey ||
		!hmac.Equal(credentialPublicKey, presentedPublicKey) {
		return internalTelemetryAttestationResponse{}, errTelemetryAttestationInvalid
	}

	if !refreshProofTimestampIsFresh(request.Timestamp, time.Now()) {
		return internalTelemetryAttestationResponse{}, errTelemetryAttestationInvalid
	}
	nonceBytes, err := base64.RawURLEncoding.DecodeString(request.Nonce)
	if err != nil || len(nonceBytes) != 32 || base64.RawURLEncoding.EncodeToString(nonceBytes) != request.Nonce {
		return internalTelemetryAttestationResponse{}, errTelemetryAttestationInvalid
	}
	transcriptPath := request.TranscriptPath
	if transcriptPath == "" {
		transcriptPath = PathPublicTelemetryEnroll
	}
	if transcriptPath != PathPublicTelemetryEnroll && transcriptPath != PathPublicTelemetryRotate {
		return internalTelemetryAttestationResponse{}, errTelemetryAttestationInvalid
	}
	proofPayload := authenticatedProofPayload(http.MethodPost, transcriptPath, request.Timestamp, request.Nonce)
	if err := verifyDeviceProof(credentialPublicKey, proofPayload, request.Signature); err != nil {
		return internalTelemetryAttestationResponse{}, errTelemetryAttestationInvalid
	}

	opCtx, cancel := context.WithTimeout(ctx, deviceSecurityOperationTimeout)
	defer cancel()
	unlock, locked := s.lockDeviceContext(opCtx, request.DeviceID)
	if !locked {
		return internalTelemetryAttestationResponse{}, errTelemetryAttestationUnavailable
	}
	defer unlock()

	now := time.Now()
	if s.store == nil || s.cache == nil {
		return internalTelemetryAttestationResponse{}, errTelemetryAttestationUnavailable
	}
	revoked, err := s.store.IsRevoked(opCtx, request.DeviceID, now)
	if err != nil {
		return internalTelemetryAttestationResponse{}, errTelemetryAttestationUnavailable
	}
	device, err := s.store.GetEnrollment(opCtx, request.DeviceID)
	if err != nil {
		return internalTelemetryAttestationResponse{}, errTelemetryAttestationUnavailable
	}
	if revoked || device == nil || device.ProtocolVersion != s.config.ProtocolVersion ||
		device.PublicKey != request.PublicKey || claims.EnrollmentGeneration != device.EnrolledAt.UnixMicro() {
		return internalTelemetryAttestationResponse{}, errTelemetryAttestationInvalid
	}

	nonceExpiresAt := time.Unix(request.Timestamp, 0).Add(refreshProofFreshness).Add(refreshNonceSlack)
	replayed, err := s.cache.ConsumeNonce(opCtx, request.DeviceID, request.Nonce, nonceExpiresAt)
	if err != nil {
		return internalTelemetryAttestationResponse{}, errTelemetryAttestationUnavailable
	}
	if replayed {
		return internalTelemetryAttestationResponse{}, errTelemetryAttestationInvalid
	}
	return internalTelemetryAttestationResponse{
		DeviceID:             device.DeviceID,
		EnrollmentGeneration: device.EnrolledAt.UnixMicro(),
		ProtocolVersion:      device.ProtocolVersion,
	}, nil
}
