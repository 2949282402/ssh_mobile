// v1 Relay hub 控制信封校验与会话状态转发。
//
// 控制信封只负责会话生命周期，Relay 不读取端到端加密数据内容。

package relay

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

// routeControl 校验并转发一个 JSON 控制信封。
func (h *hub) routeControl(sender *peer, data []byte) {
	if !sender.allowFrame() || len(data) > maxControlFrameBytes {
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
		if _, exists := h.sessions[frame.SessionID]; exists {
			return
		}
		h.sessions[frame.SessionID] = session{
			sender:    sender.deviceID,
			receiver:  frame.TargetID,
			expiresAt: time.Now().Add(h.config.SessionTTL),
		}
	} else {
		current, exists := h.sessions[frame.SessionID]
		if !exists ||
			time.Now().After(current.expiresAt) ||
			(current.sender != sender.deviceID && current.receiver != sender.deviceID) {
			if exists && time.Now().After(current.expiresAt) {
				delete(h.sessions, frame.SessionID)
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
		h.sessions[frame.SessionID] = current
	}
	current, ok := h.sessions[frame.SessionID]
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
		delete(h.sessions, frame.SessionID)
	}
}
