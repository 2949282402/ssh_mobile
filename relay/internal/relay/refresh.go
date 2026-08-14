// refreshCredential：在既有 enrollment 上签发新的短期凭据，无需 enrollment token。
//
// 该端点供已 enrolled 的设备在凭据过期前刷新凭据，也是 relay 重启后客户端重新
// 建立认证的唯一路径：设备仍在 enrollment 中时返回新凭据，enrollment 已丢失时
// 返回 404，客户端必须重新走 enrollment（不能静默循环重试 refresh）。

package relay

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"time"
)

// refreshNonceTTL 限制 refresh 证明 nonce 的存活时间，与 authenticatedRequest 的
// 重放防护共用同一 nonce 存储（Cache，当前为 memoryStore）与上限（每设备 128 个活跃 nonce）。
const refreshNonceTTL = 5 * time.Minute

type refreshRequest struct {
	DeviceID  string `json:"device_id"`
	PublicKey string `json:"public_key"`
	Nonce     string `json:"nonce"`
	Signature string `json:"signature"`
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

	device, err := s.store.GetEnrollment(r.Context(), request.DeviceID)
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
	revoked, revokeErr := s.store.IsRevoked(r.Context(), request.DeviceID, time.Now())
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
	proofPayload := "POST\n/v1/devices/refresh\n" + request.Nonce
	if err := verifyDeviceProof(storedKey, proofPayload, request.Signature); err != nil {
		writeNetworkError(w, http.StatusUnauthorized, relayErrorAuthenticationFailed, "Relay device authentication failed.", "refresh_credential", request.DeviceID)
		return
	}
	replayed, nonceErr := s.cache.ConsumeNonce(r.Context(), request.DeviceID, request.Nonce, time.Now().Add(refreshNonceTTL))
	if nonceErr != nil {
		// fail-open：与 /v1/connect 一致——nonce 防重放降级不阻断 refresh，
		// Ed25519 签名仍是真正的鉴权；仅日志告警。
		s.logger.Warn("replay-protection cache unavailable during refresh; degraded",
			"device_id", request.DeviceID, "error", nonceErr)
	} else if replayed {
		writeNetworkError(w, http.StatusUnauthorized, relayErrorAuthenticationFailed, "Relay device authentication failed.", "refresh_credential", request.DeviceID)
		return
	}
	credential, err := issueCredential(s.config.CredentialKey, request.DeviceID, storedKey, s.config.CredentialTTL)
	if err != nil {
		writeNetworkError(w, http.StatusInternalServerError, relayErrorRelayError, "Relay credential issuance failed.", "refresh_credential", request.DeviceID)
		return
	}
	writeEnrollmentResponse(w, credential, time.Now(), s.config.CredentialTTL, device.ProtocolVersion)
}
