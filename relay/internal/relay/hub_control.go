// v1 Relay hub 控制信封校验与会话状态转发。
//
// 控制信封只负责会话生命周期，Relay 不读取端到端加密数据内容。

package relay

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

// routeControl 校验并转发一个 JSON 控制信封。
func (h *hub) routeControl(sender *peer, data []byte) {
	if !sender.allowFrame(len(data)) || len(data) > maxControlFrameBytes {
		return
	}
	h.mutex.Lock()
	isCurrent := h.peers[sender.deviceID] == sender
	h.mutex.Unlock()
	if !isCurrent {
		return
	}
	var frame controlFrame
	if json.Unmarshal(data, &frame) != nil {
		return
	}

	// 处理 heartbeat ping。
	if frame.Type == "heartbeat" {
		if h.presence != nil {
			// 给 lease I/O 一个短 deadline：Redis 卡顿时不能无限阻塞 read
			// goroutine（它还负责数据帧转发）。超时视为 ownership 未知，
			// fail-open 保持连接，下次心跳重试。
			leaseCtx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
			ok, err := h.presence.RenewPresence(leaseCtx, sender.deviceID, sender.connectionID, h.presenceFor(sender), h.presenceTTL)
			cancel()
			if err != nil {
				// Redis 抖动或超时：不中断连接，presence 下次心跳再对齐。
			} else if !ok {
				// 租约已被其它连接抢占（通常是另一实例的新连接）：本连接已被
				// 取代，自愈关闭且不回 ack，让设备重连收敛到唯一的在线连接。
				closePeer(sender)
				return
			}
			// Renew 可能与该 peer 的 remove/disconnect 竞态：续租落在已死亡
			// peer 上会复生它的租约。重新核对本地 currency，非 current 则撤销
			// 这次续租并关闭（否则残留在线状态最多一个 presence TTL）。
			h.mutex.Lock()
			isCurrent := h.peers[sender.deviceID] == sender
			h.mutex.Unlock()
			if !isCurrent {
				_, _ = h.presence.ReleasePresence(context.Background(), sender.deviceID, sender.connectionID)
				closePeer(sender)
				return
			}
		}
		resp, _ := json.Marshal(controlFrame{
			Type:      "heartbeat_ack",
			Timestamp: time.Now().UnixMilli(),
		})
		if !sender.enqueue(outboundFrame{websocket.TextMessage, resp}) {
			go sender.socket.Close()
		}
		return
	}

	// 处理对端查询。
	if frame.Type == "lookup" {
		h.mutex.Lock()
		_, isOnline := h.peers[frame.TargetID]
		h.mutex.Unlock()

		resp, _ := json.Marshal(controlFrame{
			Type:     "lookup_response",
			TargetID: frame.TargetID,
			Online:   &isOnline,
		})
		if !sender.enqueue(outboundFrame{websocket.TextMessage, resp}) {
			go sender.socket.Close()
		}
		return
	}

	if frame.Type == "channel_message" || frame.Type == "channel_ack" || frame.Type == "crypto_handshake" {
		h.routeChannelControl(sender, frame)
		return
	}
	if frame.Type == "candidate_offer" || frame.Type == "candidate_answer" {
		h.routeCandidateControl(sender, frame)
		return
	}
	if strings.HasPrefix(frame.Type, "webrtc_") {
		h.routeWebRTCControl(sender, frame)
		return
	}

	switch frame.Type {
	case "offer", "accept", "resume", "complete", "complete_ack", "cancel":
	default:
		return
	}
	if len(frame.SessionID) != 32 {
		return
	}
	if frame.SessionID != strings.ToLower(frame.SessionID) {
		return
	}
	if _, err := hex.DecodeString(frame.SessionID); err != nil {
		return
	}

	h.mutex.Lock()
	defer h.mutex.Unlock()
	if frame.Type == "offer" {
		if frame.TargetID == "" ||
			frame.TargetID == sender.deviceID ||
			frame.Payload == "" ||
			h.peers[frame.TargetID] == nil {
			return
		}
		if _, err := base64.RawURLEncoding.DecodeString(frame.Payload); err != nil {
			return
		}
		if _, exists := h.transferSessions[frame.SessionID]; exists {
			return
		}
		if len(h.transferSessions) >= h.config.MaxTransferSessions {
			return
		}
		h.transferSessions[frame.SessionID] = session{
			sender:    sender.deviceID,
			receiver:  frame.TargetID,
			expiresAt: time.Now().Add(h.config.SessionTTL),
		}
	} else {
		current, exists := h.transferSessions[frame.SessionID]
		if !exists ||
			time.Now().After(current.expiresAt) ||
			(current.sender != sender.deviceID && current.receiver != sender.deviceID) {
			if exists && time.Now().After(current.expiresAt) {
				delete(h.transferSessions, frame.SessionID)
			}
			return
		}
		switch frame.Type {
		case "accept":
			if current.receiver != sender.deviceID || current.accepted || current.completed {
				return
			}
			current.accepted = true
		case "resume":
			if current.receiver != sender.deviceID || current.completed {
				return
			}
			current.accepted = true
		case "complete":
			if current.sender != sender.deviceID || !current.accepted || current.completed {
				return
			}
			current.completed = true
		case "complete_ack":
			if current.receiver != sender.deviceID || !current.completed {
				return
			}
		case "cancel":
			// 任一参与方都可以取消会话。
		default:
			return
		}
		current.expiresAt = time.Now().Add(h.config.SessionTTL)
		h.transferSessions[frame.SessionID] = current
	}
	current, ok := h.transferSessions[frame.SessionID]
	if !ok {
		return
	}
	targetID := current.receiver
	if sender.deviceID == current.receiver {
		targetID = current.sender
	}
	target := h.peers[targetID]
	if target != nil {
		forwarded, err := json.Marshal(controlFrame{
			Type:      frame.Type,
			SessionID: frame.SessionID,
			SenderID:  sender.deviceID,
			Payload:   frame.Payload,
		})
		if err != nil || !target.enqueue(outboundFrame{websocket.TextMessage, forwarded}) {
			go target.socket.Close()
		}
	}
	if frame.Type == "cancel" || frame.Type == "complete_ack" {
		delete(h.transferSessions, frame.SessionID)
	}
}

// routeChannelControl 转发不透明 Delivery 信封。它不创建文件传输会话，
// 因而不会让 ACK 或消息状态被 Relay 的文件 session 生命周期错误绑定。
func (h *hub) routeChannelControl(sender *peer, frame controlFrame) {
	if len(frame.SessionID) != 32 ||
		frame.SessionID != strings.ToLower(frame.SessionID) ||
		frame.TargetID == "" ||
		frame.TargetID == sender.deviceID ||
		frame.Payload == "" {
		return
	}
	if _, err := hex.DecodeString(frame.SessionID); err != nil {
		return
	}
	decoded, err := base64.RawURLEncoding.DecodeString(frame.Payload)
	if err != nil || len(decoded) == 0 || len(decoded) > maxChannelPayloadBytes {
		return
	}
	h.mutex.Lock()
	isCurrent := h.peers[sender.deviceID] == sender
	target := h.peers[frame.TargetID]
	h.mutex.Unlock()
	if !isCurrent || target == nil {
		return
	}
	forwarded, err := json.Marshal(controlFrame{
		Type:      frame.Type,
		SessionID: frame.SessionID,
		SenderID:  sender.deviceID,
		Payload:   frame.Payload,
	})
	if err != nil || !target.enqueue(outboundFrame{websocket.TextMessage, forwarded}) {
		go target.socket.Close()
	}
}

// routeCandidateControl 转发 ICE-like candidate Offer/Answer。Candidate
// payload 只由设备端解释，Relay 仍不读取 endpoint 或 generation 的语义。
func (h *hub) routeCandidateControl(sender *peer, frame controlFrame) {
	if len(frame.SessionID) != 32 ||
		frame.SessionID != strings.ToLower(frame.SessionID) ||
		frame.TargetID == "" ||
		frame.TargetID == sender.deviceID ||
		frame.Payload == "" {
		return
	}
	if _, err := hex.DecodeString(frame.SessionID); err != nil {
		return
	}
	decoded, err := base64.RawURLEncoding.DecodeString(frame.Payload)
	if err != nil || len(decoded) == 0 || len(decoded) > maxCandidatePayloadBytes {
		return
	}
	h.mutex.Lock()
	isCurrent := h.peers[sender.deviceID] == sender
	target := h.peers[frame.TargetID]
	h.mutex.Unlock()
	if !isCurrent || target == nil {
		return
	}
	forwarded, err := json.Marshal(controlFrame{
		Type:      frame.Type,
		SessionID: frame.SessionID,
		SenderID:  sender.deviceID,
		Payload:   frame.Payload,
	})
	if err != nil || !target.enqueue(outboundFrame{websocket.TextMessage, forwarded}) {
		go target.socket.Close()
	}
}

// routeWebRTCControl 转发 WebRTC SDP/ICE 控制面信令，Relay 不解析媒体或
// SDP 内容，也不把它绑定到文件传输 session。
func (h *hub) routeWebRTCControl(sender *peer, frame controlFrame) {
	if frame.Type != "webrtc_offer" &&
		frame.Type != "webrtc_answer" &&
		frame.Type != "webrtc_ice_candidate" &&
		frame.Type != "webrtc_ice_restart" &&
		frame.Type != "webrtc_close" {
		return
	}
	if len(frame.SessionID) != 32 ||
		frame.SessionID != strings.ToLower(frame.SessionID) ||
		frame.TargetID == "" ||
		frame.TargetID == sender.deviceID ||
		frame.Payload == "" {
		return
	}
	if _, err := hex.DecodeString(frame.SessionID); err != nil {
		return
	}
	decoded, err := base64.RawURLEncoding.DecodeString(frame.Payload)
	if err != nil || len(decoded) == 0 || len(decoded) > maxRealtimeSignalPayloadBytes {
		return
	}
	h.mutex.Lock()
	isCurrent := h.peers[sender.deviceID] == sender
	target := h.peers[frame.TargetID]
	h.mutex.Unlock()
	if !isCurrent || target == nil {
		return
	}
	forwarded, err := json.Marshal(controlFrame{
		Type:      frame.Type,
		SessionID: frame.SessionID,
		SenderID:  sender.deviceID,
		Payload:   frame.Payload,
	})
	if err != nil || !target.enqueue(outboundFrame{websocket.TextMessage, forwarded}) {
		go target.socket.Close()
	}
}
