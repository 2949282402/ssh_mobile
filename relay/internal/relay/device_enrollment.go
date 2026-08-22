package relay

import (
	"context"
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
	// 写入 enrollment + 清 nonce 是同设备复合单元，用 per-device 分片锁串行化，
	// 避免与并发 revoke 交错。
	unlock := s.lockDevice(deviceID)
	defer unlock()
	result, err := s.store.PutEnrollment(context.Background(), &EnrolledDevice{
		DeviceID:        deviceID,
		PublicKey:       publicKey,
		Platform:        platform,
		ProtocolVersion: protocolVersion,
		EnrolledAt:      enrolledAt,
	})
	if err == nil && result == enrollmentOK {
		_ = s.cache.ClearDeviceNonces(context.Background(), deviceID)
	}
	if err != nil {
		// 内存实现永不返回错误；Phase 1 落库失败时在此收敛为拒绝写入。
		return enrollmentResourceLimit
	}
	if result == enrollmentOK {
		s.hub.disconnectDevice(deviceID)
		// 重新 enroll 抢占旧连接：本实例直接断开，其它实例据此踢掉旧连接。
		if err := s.cache.Publish(context.Background(), RelayEvent{
			Type:     eventDeviceKicked,
			DeviceID: deviceID,
			Time:     time.Now().UnixMilli(),
		}); err != nil {
			s.logger.Warn("failed to publish re-enroll event; other instances may keep the old connection",
				"device_id", deviceID, "error", err)
		}
	}
	return result
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
	ctx := r.Context()
	// 认证是「吊销检查 + enrollment 读取 + nonce 消费」的复合单元，用该设备的
	// per-device 分片锁串行化，避免认证与并发 revoke/re-enroll 交错（比如吊销与
	// 认证竞态放行已吊销设备）。
	unlock := s.lockDevice(claims.DeviceID)
	revoked, storeErr := s.store.IsRevoked(ctx, claims.DeviceID, time.Now())
	device, getErr := s.store.GetEnrollment(ctx, claims.DeviceID)
	keyMatches := device != nil && device.PublicKey == base64.RawURLEncoding.EncodeToString(publicKey)
	replayed := false
	var nonceErr error
	if storeErr == nil && getErr == nil && !revoked && keyMatches {
		replayed, nonceErr = s.cache.ConsumeNonce(ctx, claims.DeviceID, nonce, time.Unix(claims.ExpiresAt, 0))
	}
	unlock()
	if nonceErr != nil {
		// Replay protection is part of the authentication decision.  If the cache
		// cannot record the nonce, accepting the request would turn a transient
		// Redis outage into a replay window, so authentication must fail closed.
		s.logger.Warn("replay-protection cache unavailable during authentication; rejecting",
			"device_id", claims.DeviceID, "error", nonceErr)
	}
	if storeErr != nil || getErr != nil || nonceErr != nil || revoked || !keyMatches || replayed {
		// 内存实现不返回错误；存储故障时在此 fail closed，与吊销/不匹配同等拒绝。
		return credentialClaims{}, nil, relayErrorAuthenticationFailed, false
	}
	return claims, publicKey, relayErrorUnspecified, true
}

// admitAuthenticatedDevice serializes the interval between successful proof
// authentication and socket admission with admin revocation/re-enrollment.
// authenticatedRequest intentionally releases its lock after consuming the
// nonce; callers must take this second, admission-scoped lock before upgrading
// or registering a socket.  The enrollment/revocation re-check closes the
// TOCTOU window where revoke could otherwise complete after authentication but
// before a new control/data socket became reachable.
func (s *Server) admitAuthenticatedDevice(ctx context.Context, claims credentialClaims, publicKey []byte) (func(), relayErrorCode, bool) {
	unlock := s.lockDevice(claims.DeviceID)
	if claims.ExpiresAt <= time.Now().Unix() {
		unlock()
		return nil, relayErrorCredentialExpired, false
	}
	revoked, revokeErr := s.store.IsRevoked(ctx, claims.DeviceID, time.Now())
	device, enrollmentErr := s.store.GetEnrollment(ctx, claims.DeviceID)
	keyMatches := device != nil && device.PublicKey == base64.RawURLEncoding.EncodeToString(publicKey)
	if revokeErr != nil || enrollmentErr != nil || revoked || !keyMatches {
		unlock()
		return nil, relayErrorAuthenticationFailed, false
	}
	return unlock, relayErrorUnspecified, true
}

func (s *Server) validEnrollmentToken(token string) bool {
	s.tokenMutex.Lock()
	expected := s.config.EnrollmentToken
	s.tokenMutex.Unlock()
	return token != "" && hmac.Equal([]byte(token), []byte(expected))
}
