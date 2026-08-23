// refreshCredential：在既有 enrollment 上签发新的短期凭据，无需 enrollment token。
//
// 该端点供已 enrolled 的设备在凭据过期前刷新凭据，也是 relay 重启后客户端重新
// 建立认证的唯一路径：设备仍在 enrollment 中时返回新凭据，enrollment 已丢失时
// 返回 404，客户端必须重新走 enrollment（不能静默循环重试 refresh）。

package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strconv"
	"time"
)

// refreshProofFreshness 是 refresh 证明的最大时钟偏差。上下边界均包含；
// nonce 再多保留 1 秒，使下边界的请求在秒精度时钟下仍能原子消费。
const (
	refreshProofFreshness = 5 * time.Minute
	refreshNonceSlack     = time.Second
)

type refreshRequest struct {
	DeviceID  string `json:"device_id"`
	PublicKey string `json:"public_key"`
	Timestamp int64  `json:"timestamp"`
	Nonce     string `json:"nonce"`
	Signature string `json:"signature"`
}

func refreshProofTimestampIsFresh(timestamp int64, now time.Time) bool {
	windowSeconds := int64(refreshProofFreshness / time.Second)
	nowSeconds := now.Unix()
	return timestamp >= nowSeconds-windowSeconds && timestamp <= nowSeconds+windowSeconds
}

func refreshProofPayload(timestamp int64, nonce string) string {
	return "POST\n/v1/devices/refresh\n" + strconv.FormatInt(timestamp, 10) + "\n" + nonce
}

func (s *Server) refresh(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	var request refreshRequest
	if json.NewDecoder(r.Body).Decode(&request) != nil {
		writeNetworkError(w, http.StatusBadRequest, relayErrorInvalidArgument, "Refresh request is invalid.", "refresh_credential", "")
		return
	}
	if request.DeviceID == "" || len(request.DeviceID) > 128 {
		writeNetworkError(w, http.StatusBadRequest, relayErrorInvalidArgument, "Device identity is invalid.", "refresh_credential", request.DeviceID)
		return
	}
	presentedKey, err := base64.RawURLEncoding.DecodeString(request.PublicKey)
	if err != nil || len(presentedKey) != ed25519.PublicKeySize {
		writeNetworkError(w, http.StatusBadRequest, relayErrorInvalidArgument, "Device public key is invalid.", "refresh_credential", request.DeviceID)
		return
	}
	nonceBytes, err := base64.RawURLEncoding.DecodeString(request.Nonce)
	if err != nil || len(nonceBytes) != 32 {
		writeNetworkError(w, http.StatusBadRequest, relayErrorInvalidArgument, "Device nonce is invalid.", "refresh_credential", request.DeviceID)
		return
	}
	if request.Timestamp <= 0 {
		writeNetworkError(w, http.StatusBadRequest, relayErrorInvalidArgument, "Refresh timestamp is invalid.", "refresh_credential", request.DeviceID)
		return
	}
	now := time.Now()
	if !refreshProofTimestampIsFresh(request.Timestamp, now) {
		writeNetworkError(w, http.StatusUnauthorized, relayErrorAuthenticationFailed, "Relay device authentication failed.", "refresh_credential", request.DeviceID)
		return
	}

	// refresh 的「读 enrollment → 查吊销 → 消费 nonce」是同设备复合单元：与
	// revoke/enroll 在同一条 per-device 分片锁上串行，避免吊销与 refresh 竞态
	// （IsRevoked 通过后、凭据签发前被 revoke 抢先，向已吊销设备续发新凭据）。
	ctx, cancel := context.WithTimeout(r.Context(), deviceSecurityOperationTimeout)
	defer cancel()
	unlock, locked := s.lockDeviceContext(ctx, request.DeviceID)
	if !locked {
		writeNetworkErrorRetry(w, http.StatusServiceUnavailable, relayErrorRelayError,
			"Relay device security operation timed out.", "refresh_credential", request.DeviceID,
			retryWithBackoff, 0)
		return
	}
	defer unlock()

	device, err := s.store.GetEnrollment(ctx, request.DeviceID)
	if err != nil {
		// 存储故障：fail closed，客户端可稍后重试 refresh（内存实现永不返回错误）。
		writeNetworkError(w, http.StatusInternalServerError, relayErrorRelayError, "Relay storage is unavailable.", "refresh_credential", request.DeviceID)
		return
	}
	if device == nil {
		// relay 重启后 enrollment 丢失：客户端必须重新 enroll，而不是静默循环。
		writeNetworkError(w, http.StatusNotFound, relayErrorInvalidArgument, "Relay device is not enrolled; re-enroll with an enrollment token.", "refresh_credential", request.DeviceID)
		return
	}
	// 纵深防御：即使 enrollment 因并发/删除失败而残留，只要吊销 tombstone 在有效期
	// 内就不得续发新凭据（否则被吊销设备可通过 refresh 重新取得有效凭据）。
	revoked, revokeErr := s.store.IsRevoked(ctx, request.DeviceID, now)
	if revokeErr != nil {
		writeNetworkError(w, http.StatusInternalServerError, relayErrorRelayError, "Relay storage is unavailable.", "refresh_credential", request.DeviceID)
		return
	}
	if revoked {
		writeNetworkError(w, http.StatusUnauthorized, relayErrorAuthenticationFailed, "Relay device authentication failed.", "refresh_credential", request.DeviceID)
		return
	}
	storedKey, err := base64.RawURLEncoding.DecodeString(device.PublicKey)
	if err != nil || len(storedKey) != ed25519.PublicKeySize {
		writeNetworkError(w, http.StatusInternalServerError, relayErrorRelayError, "Relay device identity is invalid.", "refresh_credential", request.DeviceID)
		return
	}
	// 身份绑定：刷新请求携带的公钥必须与 enrollment 中记录的公钥一致。
	if !bytes.Equal(presentedKey, storedKey) {
		writeNetworkError(w, http.StatusUnauthorized, relayErrorAuthenticationFailed, "Relay device authentication failed.", "refresh_credential", request.DeviceID)
		return
	}
	proofPayload := refreshProofPayload(request.Timestamp, request.Nonce)
	if err := verifyDeviceProof(storedKey, proofPayload, request.Signature); err != nil {
		writeNetworkError(w, http.StatusUnauthorized, relayErrorAuthenticationFailed, "Relay device authentication failed.", "refresh_credential", request.DeviceID)
		return
	}
	nonceExpiresAt := time.Unix(request.Timestamp, 0).Add(refreshProofFreshness).Add(refreshNonceSlack)
	replayed, nonceErr := s.cache.ConsumeNonce(ctx, request.DeviceID, request.Nonce, nonceExpiresAt)
	if nonceErr != nil {
		// A signed refresh request is replayable unless this write succeeds. Cache
		// failure therefore fails closed; issuing a credential here would turn a
		// Redis outage or OOM into a credential-minting replay window.
		s.logger.Error("replay-protection cache unavailable during refresh",
			"device_id", request.DeviceID, "error", nonceErr)
		writeNetworkErrorRetry(w, http.StatusServiceUnavailable, relayErrorRelayError,
			"Relay replay protection is unavailable.", "refresh_credential", request.DeviceID,
			retryWithBackoff, 0)
		return
	}
	if replayed {
		writeNetworkError(w, http.StatusUnauthorized, relayErrorAuthenticationFailed, "Relay device authentication failed.", "refresh_credential", request.DeviceID)
		return
	}
	credential, err := issueCredential(s.config.CredentialKey, request.DeviceID, storedKey, device.EnrolledAt.UnixMicro(), s.config.CredentialTTL)
	if err != nil {
		writeNetworkError(w, http.StatusInternalServerError, relayErrorRelayError, "Relay credential issuance failed.", "refresh_credential", request.DeviceID)
		return
	}
	writeEnrollmentResponse(w, credential, time.Now(), s.config.CredentialTTL, device.ProtocolVersion)
}
