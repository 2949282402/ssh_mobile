// v1 设备在线列表端点。GET /v1/peers 让已认证设备查询当前在线设备集合
// （presence+discovery 均有效，明确版 §13），用于客户端建立本地设备列表基线。

package relay

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"
)

type peerListEntry struct {
	PeerID string `json:"peer_id"`
}

type peerListResponse struct {
	Peers []peerListEntry `json:"peers"`
}

// authenticateBearer 校验 Bearer 凭据：只做 HMAC 校验 + 过期检查 + 公钥解码
// （verifyCredential），外加 fail-closed 的吊销检查 + enrollment 读取 + 公钥匹配
// （复刻 authenticatedRequest 的后半段，用 lockDevice 串行化）。SDK 客户端发的是
// 无状态 Bearer，不携带 nonce/signature，因此这里不做设备签名证明。
func (s *Server) authenticateBearer(r *http.Request) (credentialClaims, relayErrorCode, bool) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	claims, publicKey, err := verifyCredential(s.config.CredentialKey, token)
	if err != nil {
		if errors.Is(err, errCredentialExpired) {
			return credentialClaims{}, relayErrorCredentialExpired, false
		}
		return credentialClaims{}, relayErrorAuthenticationFailed, false
	}
	ctx := r.Context()
	unlock := s.lockDevice(claims.DeviceID)
	revoked, storeErr := s.store.IsRevoked(ctx, claims.DeviceID, time.Now())
	device, getErr := s.store.GetEnrollment(ctx, claims.DeviceID)
	keyMatches := device != nil && device.PublicKey == base64.RawURLEncoding.EncodeToString(publicKey)
	unlock()
	// 存储故障 fail-closed：与吊销/不匹配同等拒绝，保证被吊销设备无法通过本端点。
	if storeErr != nil || getErr != nil || revoked || !keyMatches {
		return credentialClaims{}, relayErrorAuthenticationFailed, false
	}
	return claims, relayErrorUnspecified, true
}

// listPeers 返回当前在线设备列表，排除调用者自身，按 device_id 排序。
// 在线判定与 lookup 一致：presence 与 discovery 均有效（ListOnlinePeers）。
// presence 缓存故障 fail-closed 返回 500（code 8），避免返回不完整列表误导客户端。
func (s *Server) listPeers(w http.ResponseWriter, r *http.Request) {
	claims, code, ok := s.authenticateBearer(r)
	if !ok {
		retry := retryUnspecified
		if code == relayErrorCredentialExpired {
			retry = retryRefreshCredentialThenRetry
		}
		writeNetworkErrorRetry(w, http.StatusUnauthorized, code, "Relay device authentication failed.", "list_peers", "", retry, 0)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), presenceLeaseTimeout)
	online, err := s.cache.ListOnlinePeers(ctx)
	cancel()
	if err != nil {
		s.logger.Warn("list peers could not query presence cache", "device_id", claims.DeviceID, "error", err)
		writeNetworkError(w, http.StatusInternalServerError, relayErrorRelayError, "Relay presence cache unavailable.", "list_peers", claims.DeviceID)
		return
	}
	deviceIDs := make([]string, 0, len(online))
	for deviceID := range online {
		if deviceID == claims.DeviceID {
			continue
		}
		deviceIDs = append(deviceIDs, deviceID)
	}
	sort.Strings(deviceIDs)
	peers := make([]peerListEntry, 0, len(deviceIDs))
	for _, deviceID := range deviceIDs {
		peers = append(peers, peerListEntry{PeerID: deviceID})
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(peerListResponse{Peers: peers})
}
