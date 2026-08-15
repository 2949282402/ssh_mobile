// v1 Relay hub 控制信封校验与会话状态转发。
//
// 控制信封只负责会话生命周期，Relay 不读取端到端加密数据内容。

package relay

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"sort"
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
			// discovery 与 presence 同生命周期：心跳同时续期。续期失败 fail-open——
			// 不因 discovery 抖动关闭连接，下次心跳重试对齐。
			discCtx, dcancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
			_, _ = h.presence.RenewDiscovery(discCtx, sender.deviceID, sender.connectionID, h.presenceTTL)
			dcancel()
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
		h.lookupPeer(sender, frame.TargetID)
		return
	}

	// 处理 discovery 上传：设备就绪后上报其发现信息，relay 存储但不解析候选。
	if frame.Type == "discovery_update" {
		h.handleDiscoveryUpdate(sender, frame)
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

// lookupPeer 用 Redis 作为唯一事实来源（明确版 §13）判定 target 是否在线：presence
// 与 discovery 均有效 → online=true，并携带该设备的 generation/capabilities/
// candidates（候选只在在线时返回）。租约读取出错时 fail-open 回退到本地 h.peers
// 判定（保留已确认的退化语义：本实例内有连接即在线），限时 presenceLeaseTimeout。
func (h *hub) lookupPeer(sender *peer, targetID string) {
	isOnline := false
	var disc Discovery
	if h.presence != nil {
		ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
		_, presenceOK, presenceErr := h.presence.GetPresence(ctx, targetID)
		found, discOK, discErr := h.presence.GetDiscovery(ctx, targetID)
		cancel()
		if presenceErr == nil && discErr == nil {
			// Redis 可读：以租约为准，presence+discovery 均有效才在线。
			isOnline = presenceOK && discOK
			if isOnline {
				disc = found
			}
		} else {
			// 租约读取故障：fail-open 回退本地表，避免缓存抖动误判在线设备离线。
			h.mutex.Lock()
			_, isOnline = h.peers[targetID]
			h.mutex.Unlock()
		}
	} else {
		h.mutex.Lock()
		_, isOnline = h.peers[targetID]
		h.mutex.Unlock()
	}

	resp, _ := json.Marshal(controlFrame{
		Type:         "lookup_response",
		TargetID:     targetID,
		Online:       &isOnline,
		Generation:   disc.Generation,
		Capabilities: disc.Capabilities,
		Candidates:   disc.Candidates,
	})
	if !sender.enqueue(outboundFrame{websocket.TextMessage, resp}) {
		go sender.socket.Close()
	}
}

// handleDiscoveryUpdate 处理设备的 discovery_update：把 generation/capabilities/
// candidates 落盘到 discovery 租约（候选是设备端序列化的不透明 base64 字符串列表，
// relay 只按 maxControlFrameBytes 校验帧大小，不解析其语义——ADR-017 边界）。
// generation 相对上一份有效值有变化时，向本实例其余 peer 广播 peer_online（首次真实
// 上报，此前仅为连接建立时的占位 discovery）或 peer_updated，并 Publish 跨实例事件；
// 无变化时静默刷新（仅续期内容，不广播，避免推送给没有变化的设备）。
func (h *hub) handleDiscoveryUpdate(sender *peer, frame controlFrame) {
	if h.presence == nil {
		return
	}
	// 帧大小上限已由 routeControl 按 maxControlFrameBytes 校验。
	d := Discovery{
		DeviceID:     sender.deviceID,
		Generation:   frame.Generation,
		Capabilities: append([]string(nil), frame.Capabilities...),
		Candidates:   append([]string(nil), frame.Candidates...),
		UpdatedAt:    time.Now(),
	}
	// 先读旧值再落盘：比较 generation 需要旧值，而 TakeDiscovery 会覆盖，顺序不能反。
	// 读失败 fail-open——不拒绝上传，静默返回让设备下次重试覆盖。
	ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	old, hadOld, getErr := h.presence.GetDiscovery(ctx, sender.deviceID)
	if getErr != nil {
		cancel()
		return
	}
	err := h.presence.TakeDiscovery(ctx, sender.deviceID, sender.connectionID, d, h.presenceTTL)
	cancel()
	if err != nil {
		// 落盘失败 fail-open：保持连接，设备可随时重试上传。
		return
	}
	frameType := ""
	if !hadOld || old.Generation == 0 {
		// 首次真实上报：此前只有连接建立时的占位 discovery（generation 0）。
		frameType = framePeerOnline
	} else if old.Generation != d.Generation {
		frameType = framePeerUpdated
	}
	if frameType != "" {
		h.broadcastPeerEvent(frameType, sender.deviceID, d.Generation)
	}
	if frameType == framePeerOnline {
		// 首次真实上报：把当前在线设备快照回给上报设备，作为其本地设备列表基线。
		// 放在 discovery_update 之后（而非连接建立时）下发，与 §8 一致：设备上传
		// discovery 证明就绪后才纳入推送发现。
		h.sendPresenceSnapshot(sender)
	}
}

// sendPresenceSnapshot 向上报设备下发当前在线设备的 {device_id, generation} 快照
// （presence_snapshot）。数据来自共享缓存 ListOnlinePeers（presence+discovery 均
// 有效，明确版 §13），排除设备自身，按 device_id 排序保证确定性。缓存故障时
// fail-open：设备靠后续 peer_online/peer_updated 事件补齐列表。
func (h *hub) sendPresenceSnapshot(sender *peer) {
	ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	online, err := h.presence.ListOnlinePeers(ctx)
	cancel()
	if err != nil {
		return
	}
	peers := make([]peerSummary, 0, len(online))
	for deviceID, d := range online {
		if deviceID == sender.deviceID {
			continue
		}
		peers = append(peers, peerSummary{DeviceID: deviceID, Generation: d.Generation})
	}
	sort.Slice(peers, func(i, j int) bool { return peers[i].DeviceID < peers[j].DeviceID })
	frame, _ := json.Marshal(controlFrame{Type: framePresenceSnapshot, Peers: peers})
	if !sender.enqueue(outboundFrame{websocket.TextMessage, frame}) {
		go sender.socket.Close()
	}
}

// broadcastPeerEvent 向本实例其余 peer 广播一个推送发现帧，并 Publish 跨实例事件，
// 让其它实例在 handleRelayEvent 里做同样的本地广播。
func (h *hub) broadcastPeerEvent(frameType, deviceID string, gen uint64) {
	eventType := ""
	switch frameType {
	case framePeerOnline:
		eventType = eventPeerOnline
	case framePeerUpdated:
		eventType = eventPeerUpdated
	case framePeerOffline:
		eventType = eventPeerOffline
	}
	frame, err := json.Marshal(controlFrame{Type: frameType, DeviceID: deviceID, Generation: gen})
	if err != nil {
		return
	}
	h.broadcast(deviceID, outboundFrame{websocket.TextMessage, frame})
	if eventType != "" && h.presence != nil {
		// InstanceID 标记发布方，订阅侧据此跳过同实例回环（发布方已本地广播过）。
		_ = h.presence.Publish(context.Background(), RelayEvent{
			Type:       eventType,
			DeviceID:   deviceID,
			Generation: gen,
			InstanceID: h.instanceID,
			Time:       time.Now().UnixMilli(),
		})
	}
}
