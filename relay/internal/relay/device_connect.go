package relay

import (
	"encoding/hex"
	"encoding/json"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
)

func (s *Server) connect(w http.ResponseWriter, r *http.Request) {
	s.upgradeDevice(w, r)
}

func (s *Server) upgradeDevice(w http.ResponseWriter, r *http.Request) {
	claims, _, code, ok := s.authenticatedRequest(r)
	if !ok {
		retry := retryUnspecified
		if code == relayErrorCredentialExpired {
			retry = retryRefreshCredentialThenRetry
		}
		writeNetworkErrorRetry(w, http.StatusUnauthorized, code, "Relay device authentication failed.", "connect_relay", "", retry, 0)
		return
	}
	connection, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	peer := &peer{
		deviceID:           claims.DeviceID,
		connectionID:       hex.EncodeToString(randomBytes(12)),
		socket:             connection,
		outbound:           make(chan outboundFrame, s.config.MaxPendingFramesPerDevice),
		done:               make(chan struct{}),
		maxPendingFrames:   s.config.MaxPendingFramesPerDevice,
		maxPendingBytes:    s.config.MaxPendingBytesPerDevice,
		maxFramesPerSecond: s.config.MaxFramesPerSecondPerDevice,
		maxBytesPerSecond:  s.config.MaxBytesPerSecondPerDevice,
	}
	if !s.hub.add(peer) {
		_ = connection.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "connection limit"), time.Now().Add(time.Second))
		_ = connection.Close()
		return
	}
	ready, _ := json.Marshal(controlFrame{
		Type:            "ready",
		DeviceID:        claims.DeviceID,
		Timestamp:       time.Now().UnixMilli(),
		ProtocolVersion: 1,
	})
	if !peer.enqueue(outboundFrame{websocket.TextMessage, ready}) {
		s.hub.remove(peer)
		return
	}
	// presence_snapshot 不在连接路径下发：按明确版 §8，设备需先上传 discovery_update
	// 证明就绪才被纳入推送发现；快照在 handleDiscoveryUpdate 首次真实上报时发给该设备
	// （见 hub_control.go sendPresenceSnapshot），同时把 peer_online 广播给其它在线设备。
	// 这样 ready 之后的帧序列保持最小（仅后续推送帧），不打断既有设备端帧序假设。
}
