package relay

import (
	"crypto/ed25519"
	"crypto/hmac"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

type EnrolledDevice struct {
	DeviceID        string    `json:"device_id"`
	PublicKey       string    `json:"public_key"`
	Platform        string    `json:"platform"`
	ProtocolVersion uint32    `json:"protocol_version"`
	EnrolledAt      time.Time `json:"enrolled_at"`
}

type enrollRequest struct {
	DeviceID        string `json:"device_id"`
	PublicKey       string `json:"public_key"`
	EnrollmentToken string `json:"enrollment_token"`
	ProtocolVersion uint32 `json:"protocol_version"`
	Platform        string `json:"platform"`
}

type enrollResponse struct {
	Credential      string `json:"credential"`
	ExpiresAt       int64  `json:"expires_at"`
	ServerTime      int64  `json:"server_time"`
	ProtocolVersion uint32 `json:"protocol_version"`
}

// relayErrorCode 使用与 Dart NetworkErrorCode 对齐的稳定错误编号。
type relayErrorCode uint32

const (
	relayErrorUnspecified          relayErrorCode = 0
	relayErrorInvalidArgument      relayErrorCode = 1
	relayErrorAuthenticationFailed relayErrorCode = 2
	relayErrorProtocolError        relayErrorCode = relayErrorInvalidArgument
	relayErrorRelayError           relayErrorCode = 8
)

type networkErrorResponse struct {
	Code      relayErrorCode `json:"code"`
	Message   string         `json:"message"`
	Operation string         `json:"operation"`
	PeerID    string         `json:"peer_id,omitempty"`
}

func writeNetworkError(w http.ResponseWriter, status int, code relayErrorCode, message, operation, peerID string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(networkErrorResponse{
		Code:      code,
		Message:   message,
		Operation: operation,
		PeerID:    peerID,
	})
}

func (s *Server) enroll(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	var request enrollRequest
	if json.NewDecoder(r.Body).Decode(&request) != nil {
		writeNetworkError(w, http.StatusBadRequest, relayErrorInvalidArgument, "Enrollment request is invalid.", "enroll_relay", "")
		return
	}
	if !s.validEnrollmentToken(request.EnrollmentToken) {
		writeNetworkError(w, http.StatusUnauthorized, relayErrorAuthenticationFailed, "Relay enrollment authentication failed.", "enroll_relay", request.DeviceID)
		return
	}
	if request.DeviceID == "" || len(request.DeviceID) > 128 {
		writeNetworkError(w, http.StatusBadRequest, relayErrorInvalidArgument, "Device identity is invalid.", "enroll_relay", request.DeviceID)
		return
	}
	if request.ProtocolVersion != 1 {
		writeNetworkError(w, http.StatusBadRequest, relayErrorProtocolError, "Relay protocol version is unsupported.", "enroll_relay", request.DeviceID)
		return
	}
	if len(request.Platform) > 64 {
		writeNetworkError(w, http.StatusBadRequest, relayErrorInvalidArgument, "Device platform is invalid.", "enroll_relay", request.DeviceID)
		return
	}
	publicKey, err := base64.RawURLEncoding.DecodeString(request.PublicKey)
	if err != nil || len(publicKey) != ed25519.PublicKeySize {
		writeNetworkError(w, http.StatusBadRequest, relayErrorInvalidArgument, "Device public key is invalid.", "enroll_relay", request.DeviceID)
		return
	}
	credential, err := issueCredential(s.config.CredentialKey, request.DeviceID, publicKey, s.config.CredentialTTL)
	if err != nil {
		writeNetworkError(w, http.StatusInternalServerError, relayErrorRelayError, "Relay credential issuance failed.", "enroll_relay", request.DeviceID)
		return
	}
	now := time.Now()
	s.replaceEnrollment(request.DeviceID, request.PublicKey, request.Platform, request.ProtocolVersion, now)
	writeEnrollmentResponse(w, credential, now, s.config.CredentialTTL, request.ProtocolVersion)
}

func (s *Server) replaceEnrollment(deviceID, publicKey, platform string, protocolVersion uint32, enrolledAt time.Time) {
	s.devicesMutex.Lock()
	s.enrolledDevices[deviceID] = &EnrolledDevice{
		DeviceID:        deviceID,
		PublicKey:       publicKey,
		Platform:        platform,
		ProtocolVersion: protocolVersion,
		EnrolledAt:      enrolledAt,
	}
	delete(s.revokedDevices, deviceID)
	delete(s.proofNonces, deviceID)
	s.devicesMutex.Unlock()
	s.hub.disconnectDevice(deviceID)
}

func writeEnrollmentResponse(w http.ResponseWriter, credential string, serverTime time.Time, ttl time.Duration, protocolVersion uint32) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(enrollResponse{
		Credential:      credential,
		ExpiresAt:       serverTime.Add(ttl).Unix(),
		ServerTime:      serverTime.Unix(),
		ProtocolVersion: protocolVersion,
	})
}

func (s *Server) authenticatedRequest(r *http.Request) (credentialClaims, []byte, bool) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	claims, publicKey, err := verifyCredential(s.config.CredentialKey, token)
	if err != nil {
		return credentialClaims{}, nil, false
	}
	nonce := r.Header.Get("X-Relay-Nonce")
	nonceBytes, err := base64.RawURLEncoding.DecodeString(nonce)
	if err != nil || len(nonceBytes) != 32 {
		return credentialClaims{}, nil, false
	}
	signature := r.Header.Get("X-Relay-Signature")
	proofPayload := r.Method + "\n" + r.URL.Path + "\n" + nonce
	if err := verifyDeviceProof(publicKey, proofPayload, signature); err != nil {
		return credentialClaims{}, nil, false
	}
	s.devicesMutex.Lock()
	_, revoked := s.revokedDevices[claims.DeviceID]
	device, enrolled := s.enrolledDevices[claims.DeviceID]
	keyMatches := enrolled && device.PublicKey == base64.RawURLEncoding.EncodeToString(publicKey)
	replayed := false
	if !revoked && keyMatches {
		replayed = s.consumeProofNonceLocked(claims.DeviceID, nonce, time.Unix(claims.ExpiresAt, 0))
	}
	s.devicesMutex.Unlock()
	if revoked || !keyMatches || replayed {
		return credentialClaims{}, nil, false
	}
	return claims, publicKey, true
}

func (s *Server) consumeProofNonceLocked(deviceID, nonce string, expiresAt time.Time) bool {
	now := time.Now()
	deviceNonces := s.proofNonces[deviceID]
	if deviceNonces == nil {
		deviceNonces = make(map[string]time.Time)
		s.proofNonces[deviceID] = deviceNonces
	}
	for value, expiry := range deviceNonces {
		if now.After(expiry) {
			delete(deviceNonces, value)
		}
	}
	if _, exists := deviceNonces[nonce]; exists {
		return true
	}
	if len(deviceNonces) >= 128 {
		return true
	}
	deviceNonces[nonce] = expiresAt
	return false
}

func (s *Server) validEnrollmentToken(token string) bool {
	s.devicesMutex.Lock()
	expected := s.config.EnrollmentToken
	s.devicesMutex.Unlock()
	return token != "" && hmac.Equal([]byte(token), []byte(expected))
}
