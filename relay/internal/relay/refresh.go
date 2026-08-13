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
// 重放防护共用同一 nonce 存储（proofNonces）与上限（每设备 128 个活跃 nonce）。
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

	s.devicesMutex.Lock()
	device, enrolled := s.enrolledDevices[request.DeviceID]
	s.devicesMutex.Unlock()
	if !enrolled {
		// relay 重启后 enrollment 丢失：客户端必须重新 enroll，而不是静默循环。
		writeNetworkError(w, http.StatusNotFound, relayErrorInvalidArgument, "Relay device is not enrolled; re-enroll with an enrollment token.", "refresh_credential", request.DeviceID)
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
	s.devicesMutex.Lock()
	replayed := s.consumeProofNonceLocked(request.DeviceID, request.Nonce, time.Now().Add(refreshNonceTTL))
	s.devicesMutex.Unlock()
	if replayed {
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
