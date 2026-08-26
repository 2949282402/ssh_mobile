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
	"sync"
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

// deviceSecurityOperationTimeout is one total service budget for a durable
// device-plane security decision while its admission stripe is held. A client
// that never disconnects and a half-open dependency must not pin every device
// hashing to that stripe indefinitely.
const deviceSecurityOperationTimeout = 5 * time.Second

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

// expectedProtocolVersion binds an enroll route to one exact device protocol version.
type expectedProtocolVersion uint32

// enroll handles POST /v2/devices/enroll endpoint.
func (s *Server) enroll(w http.ResponseWriter, r *http.Request) {
	s.enrollWithExpectedProtocolVersion(w, r, expectedProtocolVersion(s.config.ProtocolVersion))
}

func (s *Server) enrollWithExpectedProtocolVersion(w http.ResponseWriter, r *http.Request, expected expectedProtocolVersion) {
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
	if request.ProtocolVersion != uint32(expected) {
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
	now := time.Now()
	result, generation := s.replaceEnrollmentContext(r.Context(), request.DeviceID, request.PublicKey, request.Platform, request.ProtocolVersion, now)
	switch result {
	case enrollmentIdentityConflict:
		// 与管理面既有的 conflict 分类语义一致：在既有 enrollment 之下更换了
		// 身份材料，必须显式解决而非静默覆盖。
		writeNetworkError(w, http.StatusConflict, relayErrorIdentityConflict, "Relay device identity conflicts with an existing enrollment.", "enroll_relay", request.DeviceID)
		return
	case enrollmentResourceLimit:
		w.Header().Set("Retry-After", strconv.FormatUint(uint64(enrollResourceRetryAfterSeconds), 10))
		writeNetworkErrorRetry(w, http.StatusTooManyRequests, relayErrorRelayError, "Relay resource limit reached.", "enroll_relay", request.DeviceID, retryAfter, enrollResourceRetryAfterSeconds)
		return
	case enrollmentUnavailable:
		writeNetworkErrorRetry(w, http.StatusServiceUnavailable, relayErrorRelayError, "Relay enrollment storage is unavailable.", "enroll_relay", request.DeviceID, retryWithBackoff, 0)
		return
	}
	credential, err := issueCredential(s.config.CredentialKey, request.DeviceID, publicKey, generation, s.config.CredentialTTL)
	if err != nil {
		writeNetworkError(w, http.StatusInternalServerError, relayErrorRelayError, "Relay credential issuance failed.", "enroll_relay", request.DeviceID)
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
	enrollmentUnavailable
)

// replaceEnrollment 原子地检查并写入设备 enrollment。同一 device_id 使用不同的
// 公钥时返回 enrollmentIdentityConflict 且不覆盖、不断开；相同公钥的重复注册刷新
// EnrolledAt（即刷新凭据 TTL 上界）。MaxEnrolledDevices 仅约束新 device_id。
func (s *Server) replaceEnrollment(deviceID, publicKey, platform string, protocolVersion uint32, enrolledAt time.Time) enrollmentResult {
	result, _ := s.replaceEnrollmentContext(context.Background(), deviceID, publicKey, platform, protocolVersion, enrolledAt)
	return result
}

// replaceEnrollmentContext writes one monotonic enrollment generation and
// invalidates the prior generation's live sockets. Replay nonces deliberately
// survive same-key re-enrollment: clearing them would make a recently consumed
// signed refresh request replayable again.
func (s *Server) replaceEnrollmentContext(parent context.Context, deviceID, publicKey, platform string, protocolVersion uint32, enrolledAt time.Time) (enrollmentResult, int64) {
	ctx, cancel := context.WithTimeout(parent, deviceSecurityOperationTimeout)
	defer cancel()
	unlock, locked := s.lockDeviceContext(ctx, deviceID)
	if !locked {
		return enrollmentUnavailable, 0
	}
	device := &EnrolledDevice{
		DeviceID:        deviceID,
		PublicKey:       publicKey,
		Platform:        platform,
		ProtocolVersion: protocolVersion,
		EnrolledAt:      enrolledAt,
	}
	result, err := s.store.PutEnrollment(ctx, device)
	if err != nil {
		unlock()
		return enrollmentUnavailable, 0
	}
	if result == enrollmentOK {
		generation := device.EnrolledAt.UnixMicro()
		if generation <= 0 {
			unlock()
			return enrollmentUnavailable, 0
		}
		// Close data before the hub's bounded shared-presence cleanup so Redis
		// latency cannot keep an old transfer alive after the durable generation
		// has advanced.
		s.relayData.closeDevice(deviceID)
		s.hub.disconnectDevice(deviceID)
		unlock()
		// 重新 enroll 抢占旧连接：本实例直接断开，其它实例据此踢掉旧连接。
		publishCtx, publishCancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
		err = s.cache.Publish(publishCtx, RelayEvent{
			Type:                 eventDeviceKicked,
			DeviceID:             deviceID,
			EnrollmentGeneration: generation,
			Time:                 time.Now().UnixMilli(),
		})
		publishCancel()
		if err != nil {
			s.logger.Warn("failed to publish re-enroll event; other instances may keep the old connection",
				"device_id", deviceID, "error", err)
		}
		return enrollmentOK, generation
	}
	unlock()
	return result, 0
}

func writeEnrollmentResponse(w http.ResponseWriter, credential string, serverTime time.Time, ttl time.Duration, protocolVersion uint32) {
	w.Header().Set("Cache-Control", "no-store")
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
	timestampValue := r.Header.Get("X-Relay-Timestamp")
	timestamp, err := strconv.ParseInt(timestampValue, 10, 64)
	now := time.Now()
	if err != nil || timestamp <= 0 || timestampValue != strconv.FormatInt(timestamp, 10) || !refreshProofTimestampIsFresh(timestamp, now) {
		return credentialClaims{}, nil, relayErrorAuthenticationFailed, false
	}
	nonce := r.Header.Get("X-Relay-Nonce")
	nonceBytes, err := base64.RawURLEncoding.DecodeString(nonce)
	if err != nil || len(nonceBytes) != 32 {
		return credentialClaims{}, nil, relayErrorAuthenticationFailed, false
	}
	signature := r.Header.Get("X-Relay-Signature")
	proofPayload := authenticatedProofPayload(r.Method, r.URL.Path, timestamp, nonce)
	if err := verifyDeviceProof(publicKey, proofPayload, signature); err != nil {
		return credentialClaims{}, nil, relayErrorAuthenticationFailed, false
	}
	ctx, cancel := context.WithTimeout(r.Context(), deviceSecurityOperationTimeout)
	defer cancel()
	// 认证是「吊销检查 + enrollment 读取 + nonce 消费」的复合单元，用该设备的
	// per-device 分片锁串行化，避免认证与并发 revoke/re-enroll 交错（比如吊销与
	// 认证竞态放行已吊销设备）。
	unlock, locked := s.lockDeviceContext(ctx, claims.DeviceID)
	if !locked {
		return credentialClaims{}, nil, relayErrorAuthenticationFailed, false
	}
	revoked, storeErr := s.store.IsRevoked(ctx, claims.DeviceID, now)
	device, getErr := s.store.GetEnrollment(ctx, claims.DeviceID)
	keyMatches := device != nil && device.PublicKey == base64.RawURLEncoding.EncodeToString(publicKey)
	generationMatches := device != nil && claims.EnrollmentGeneration == device.EnrolledAt.UnixMicro()
	protocolMatches := device != nil && device.ProtocolVersion == s.config.ProtocolVersion
	replayed := false
	var nonceErr error
	if storeErr == nil && getErr == nil && !revoked && keyMatches && generationMatches && protocolMatches {
		nonceExpiresAt := time.Unix(timestamp, 0).Add(refreshProofFreshness).Add(refreshNonceSlack)
		replayed, nonceErr = s.cache.ConsumeNonce(ctx, claims.DeviceID, nonce, nonceExpiresAt)
	}
	unlock()
	if nonceErr != nil {
		// Replay protection is part of the authentication decision.  If the cache
		// cannot record the nonce, accepting the request would turn a transient
		// Redis outage into a replay window, so authentication must fail closed.
		s.logger.Warn("replay-protection cache unavailable during authentication; rejecting",
			"device_id", claims.DeviceID, "error", nonceErr)
	}
	if storeErr != nil || getErr != nil || nonceErr != nil || revoked || !keyMatches || !generationMatches || !protocolMatches || replayed {
		// 内存实现不返回错误；存储故障时在此 fail closed，与吊销/不匹配同等拒绝。
		return credentialClaims{}, nil, relayErrorAuthenticationFailed, false
	}
	return claims, publicKey, relayErrorUnspecified, true
}

// authenticatedProofPayload binds every v2 WebSocket proof to its method,
// route, signed Unix-seconds timestamp, and single-use nonce. The transcript
// deliberately has no trailing newline and is shared by Control and RelayData.
func authenticatedProofPayload(method, path string, timestamp int64, nonce string) string {
	return method + "\n" + path + "\n" + strconv.FormatInt(timestamp, 10) + "\n" + nonce
}

// authenticatedDeviceAdmission owns the one total deadline and device stripe
// spanning durable admission, WebSocket upgrade, non-routable staging, and the
// post-registration durable recheck. Keeping the context alive with the lock
// prevents each phase from silently resetting the five-second security budget.
type authenticatedDeviceAdmission struct {
	ctx    context.Context
	cancel context.CancelFunc
	unlock func()
	once   sync.Once
}

func (admission *authenticatedDeviceAdmission) release() {
	if admission == nil {
		return
	}
	admission.once.Do(func() {
		admission.cancel()
		admission.unlock()
	})
}

// admitAuthenticatedDevice serializes the interval between successful proof
// authentication and socket admission with revocation/re-enrollment.
// authenticatedRequest intentionally releases its lock after consuming the
// nonce; callers must retain this admission object until a staged endpoint has
// passed its second durable check and becomes reachable. The shared context is
// the complete device-security budget, including the WebSocket handshake.
func (s *Server) admitAuthenticatedDevice(ctx context.Context, claims credentialClaims, publicKey []byte) (*authenticatedDeviceAdmission, relayErrorCode, bool) {
	ctx, cancel := context.WithTimeout(ctx, deviceSecurityOperationTimeout)
	unlock, locked := s.lockDeviceContext(ctx, claims.DeviceID)
	if !locked {
		cancel()
		return nil, relayErrorAuthenticationFailed, false
	}
	admission := &authenticatedDeviceAdmission{ctx: ctx, cancel: cancel, unlock: unlock}
	code, current := s.enrollmentClaimsCurrent(ctx, claims, publicKey)
	if !current {
		admission.release()
		return nil, code, false
	}
	return admission, relayErrorUnspecified, true
}

// enrollmentClaimsCurrent performs the durable half of admission while the
// caller owns the device stripe. It is reused after socket registration to
// close the cross-instance revoke window between the first recheck and making
// the endpoint reachable.
func (s *Server) enrollmentClaimsCurrent(ctx context.Context, claims credentialClaims, publicKey []byte) (relayErrorCode, bool) {
	if claims.ExpiresAt <= time.Now().Unix() {
		return relayErrorCredentialExpired, false
	}
	revoked, revokeErr := s.store.IsRevoked(ctx, claims.DeviceID, time.Now())
	device, enrollmentErr := s.store.GetEnrollment(ctx, claims.DeviceID)
	keyMatches := device != nil && device.PublicKey == base64.RawURLEncoding.EncodeToString(publicKey)
	generationMatches := device != nil && claims.EnrollmentGeneration == device.EnrolledAt.UnixMicro()
	protocolMatches := device != nil && device.ProtocolVersion == s.config.ProtocolVersion
	if revokeErr != nil || enrollmentErr != nil || revoked || !keyMatches || !generationMatches || !protocolMatches {
		return relayErrorAuthenticationFailed, false
	}
	return relayErrorUnspecified, true
}

func (s *Server) validEnrollmentToken(token string) bool {
	s.tokenMutex.Lock()
	expected := s.config.EnrollmentToken
	s.tokenMutex.Unlock()
	return token != "" && hmac.Equal([]byte(token), []byte(expected))
}
