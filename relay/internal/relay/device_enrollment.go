package relay

import (
	"crypto/ed25519"
	"crypto/hmac"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
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
	relayErrorCredentialExpired    relayErrorCode = 12
	relayErrorIdentityConflict     relayErrorCode = 13
)

// retryDisposition 指示客户端在收到设备平面错误后应如何重试。
type retryDisposition uint32

const (
	retryUnspecified                retryDisposition = 0
	retryNoRetry                    retryDisposition = 1
	retryWithBackoff                retryDisposition = 2
	retryAfter                      retryDisposition = 3
	retryRefreshCredentialThenRetry retryDisposition = 4
)

// enrollResourceRetryAfterSeconds 是 enrollment 资源耗尽时的重试提示（秒）。
const enrollResourceRetryAfterSeconds uint32 = 30

type networkErrorResponse struct {
	Code              relayErrorCode   `json:"code"`
	Message           string           `json:"message"`
	Operation         string           `json:"operation"`
	PeerID            string           `json:"peer_id,omitempty"`
	RetryDisposition  retryDisposition `json:"retry_disposition,omitempty"`
	RetryAfterSeconds uint32           `json:"retry_after_seconds,omitempty"`
}

func writeNetworkError(w http.ResponseWriter, status int, code relayErrorCode, message, operation, peerID string) {
	writeNetworkErrorRetry(w, status, code, message, operation, peerID, retryUnspecified, 0)
}

// writeNetworkErrorRetry 在 writeNetworkError 的基础上携带可选的重试策略。零值
// retryDisposition（retryUnspecified）与 retryAfterSeconds 会因 omitempty 被省略，
// 保持既有错误响应向后兼容。
func writeNetworkErrorRetry(w http.ResponseWriter, status int, code relayErrorCode, message, operation, peerID string, retry retryDisposition, retryAfterSeconds uint32) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(networkErrorResponse{
		Code:              code,
		Message:           message,
		Operation:         operation,
		PeerID:            peerID,
		RetryDisposition:  retry,
		RetryAfterSeconds: retryAfterSeconds,
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
	switch s.replaceEnrollment(request.DeviceID, request.PublicKey, request.Platform, request.ProtocolVersion, now) {
	case enrollmentIdentityConflict:
		// 与 admin 面既有的 conflict 分类（adminErrorConflict）语义一致：在既有
		// enrollment 之下更换了身份材料，必须显式解决而非静默覆盖。
		writeNetworkError(w, http.StatusConflict, relayErrorIdentityConflict, "Relay device identity conflicts with an existing enrollment.", "enroll_relay", request.DeviceID)
		return
	case enrollmentResourceLimit:
		w.Header().Set("Retry-After", strconv.FormatUint(uint64(enrollResourceRetryAfterSeconds), 10))
		writeNetworkErrorRetry(w, http.StatusTooManyRequests, relayErrorRelayError, "Relay resource limit reached.", "enroll_relay", request.DeviceID, retryAfter, enrollResourceRetryAfterSeconds)
		return
	}
	writeEnrollmentResponse(w, credential, now, s.config.CredentialTTL, request.ProtocolVersion)
}

// enrollmentResult 描述 replaceEnrollment 的结果，供 enroll 处理器区分成功、身份
// 冲突与资源耗尽三种结局。
type enrollmentResult int

const (
	enrollmentOK enrollmentResult = iota
	enrollmentIdentityConflict
	enrollmentResourceLimit
)

// replaceEnrollment 原子地检查并写入设备 enrollment。同一 device_id 使用不同的
// 公钥时返回 enrollmentIdentityConflict 且不覆盖、不断开；相同公钥的重复注册刷新
// EnrolledAt（即刷新凭据 TTL 上界）。MaxEnrolledDevices 仅约束新 device_id。
func (s *Server) replaceEnrollment(deviceID, publicKey, platform string, protocolVersion uint32, enrolledAt time.Time) enrollmentResult {
	s.devicesMutex.Lock()
	if existing, exists := s.enrolledDevices[deviceID]; exists {
		if existing.PublicKey != publicKey {
			s.devicesMutex.Unlock()
			return enrollmentIdentityConflict
		}
	} else if len(s.enrolledDevices) >= s.config.MaxEnrolledDevices {
		s.devicesMutex.Unlock()
		return enrollmentResourceLimit
	}
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
	return enrollmentOK
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

func (s *Server) authenticatedRequest(r *http.Request) (credentialClaims, []byte, relayErrorCode, bool) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	claims, publicKey, err := verifyCredential(s.config.CredentialKey, token)
	if err != nil {
		if errors.Is(err, errCredentialExpired) {
			return credentialClaims{}, nil, relayErrorCredentialExpired, false
		}
		return credentialClaims{}, nil, relayErrorAuthenticationFailed, false
	}
	nonce := r.Header.Get("X-Relay-Nonce")
	nonceBytes, err := base64.RawURLEncoding.DecodeString(nonce)
	if err != nil || len(nonceBytes) != 32 {
		return credentialClaims{}, nil, relayErrorAuthenticationFailed, false
	}
	signature := r.Header.Get("X-Relay-Signature")
	proofPayload := r.Method + "\n" + r.URL.Path + "\n" + nonce
	if err := verifyDeviceProof(publicKey, proofPayload, signature); err != nil {
		return credentialClaims{}, nil, relayErrorAuthenticationFailed, false
	}
	s.devicesMutex.Lock()
	revoked := false
	if entry, isRevoked := s.revokedDevices[claims.DeviceID]; isRevoked {
		if time.Now().Before(entry.expiresAt) {
			revoked = true
		} else {
			// The tombstone's recorded expiry is an upper bound on the
			// credential expiry, so once it has passed the credential is
			// already rejected by verifyCredential; dropping the stale
			// tombstone cannot reauthorize a still-revoked credential.
			delete(s.revokedDevices, claims.DeviceID)
		}
	}
	device, enrolled := s.enrolledDevices[claims.DeviceID]
	keyMatches := enrolled && device.PublicKey == base64.RawURLEncoding.EncodeToString(publicKey)
	replayed := false
	if !revoked && keyMatches {
		replayed = s.consumeProofNonceLocked(claims.DeviceID, nonce, time.Unix(claims.ExpiresAt, 0))
	}
	s.devicesMutex.Unlock()
	if revoked || !keyMatches || replayed {
		return credentialClaims{}, nil, relayErrorAuthenticationFailed, false
	}
	return claims, publicKey, relayErrorUnspecified, true
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
