// v1 Relay hub 控制信封校验与会话状态转发。
//
// 控制信封只负责会话生命周期，Relay 不读取端到端加密数据内容。

package relay

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ssh-mobile/relay/internal/relay/v2"
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
		// 记录服务端心跳时间：hub 心跳监视器（见 hub.go monitorHeartbeats）以此判定
		// 是否连续错过 HEARTBEAT_INTERVAL_S（20s）内的心跳，超过
		// SERVER_HEARTBEAT_MISSES_BEFORE_CLOSE（2 次）后关闭连接并释放 presence 租约。
		h.mutex.Lock()
		sender.lastHeartbeat = time.Now()
		h.mutex.Unlock()
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

// lookupPeer 用权威 4-state resolve（明确版 §10）判定 target 是否可连：只有 READY
// （presence 与 discovery 均有效、owner 一致、revision>0）才 online=true，并携带该
// 设备的 generation/capabilities/candidates（候选只在 READY 时返回）。读取故障判
// UNKNOWN，绝不再 fail-open 回退本地 h.peers 或把 presence 在线伪装成 online
// （明确版 §10 禁止「Redis 出错 → online=true generation=0」）。v1 线的响应形状
// （online *bool + generation + candidates + capabilities）保持不变，Rust v1 客户端
// 继续可解析。
func (h *hub) lookupPeer(sender *peer, targetID string) {
	ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	result := h.resolvePeer(ctx, targetID)
	cancel()
	isOnline := result.status == v2.ResolveStatus_RESOLVE_STATUS_READY
	resp, _ := json.Marshal(controlFrame{
		Type:         "lookup_response",
		TargetID:     targetID,
		Online:       &isOnline,
		Generation:   result.discovery.Generation,
		Capabilities: result.discovery.Capabilities,
		Candidates:   result.discovery.Candidates,
	})
	if !sender.enqueue(outboundFrame{websocket.TextMessage, resp}) {
		go sender.socket.Close()
	}
}

// handleDiscoveryUpdate 处理设备的 discovery_update：把 generation/capabilities/
// candidates 落盘到 discovery 租约（候选是设备端序列化的不透明 base64 字符串列表，
// relay 只按 maxControlFrameBytes 校验帧大小，不解析其语义——ADR-017 边界）。
// 设备首次可发现（此前无 discovery、或旧连接 owner 不一致的残留）广播 peer_online
// 并回发 presence_snapshot；同一连接上报新的 generation 广播 peer_updated；无变化静默
// 刷新；generation 回退拒绝。跨实例经 Publish 广播事件总线。
func (h *hub) handleDiscoveryUpdate(sender *peer, frame controlFrame) {
	if h.presence == nil {
		return
	}
	// generation 必须为正：0 会被 omitempty 从广播帧里丢弃，客户端把缺失/为 0 的
	// generation 当协议错误断连（单台误设备即可 DoS 全部在线客户端），因此直接拒绝。
	if frame.Generation == 0 {
		return
	}
	// 候选与 capabilities 加边界：设备端同一约束（candidates≤64×2048B、
	// capabilities≤64×256B），服务端同样限制，避免单台上报撑爆后续 lookup_response
	// 或 presence_snapshot 使查询客户端超限断连。
	if len(frame.Candidates) > maxDiscoveryCandidates ||
		len(frame.Capabilities) > maxDiscoveryCapabilities {
		return
	}
	for _, candidate := range frame.Candidates {
		if len(candidate) > maxDiscoveryCandidateBytes {
			return
		}
	}
	for _, capability := range frame.Capabilities {
		if len(capability) > maxDiscoveryCapabilityBytes {
			return
		}
	}
	d := Discovery{
		DeviceID:     sender.deviceID,
		Generation:   frame.Generation,
		Capabilities: append([]string(nil), frame.Capabilities...),
		Candidates:   append([]string(nil), frame.Candidates...),
		UpdatedAt:    time.Now(),
	}
	// 先核对 presence 仍在有效期：与 lookup/snapshot/sweeper 的在线判定一致
	// （presence+discovery 双有效），且必须发生在落盘之前——若 presence 已失效
	// （僵尸连接心跳停了），此时不应刷新 discovery 的 TTL（否则陈旧 discovery 残留
	// 并继续被 ListOnlinePeers 计入，直到 sweeper 30s 后清理）。presence 读取故障
	// fail-open：不拒绝上传，让设备下次心跳重试。
	ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	presence, presenceOK, presenceErr := h.presence.GetPresence(ctx, sender.deviceID)
	if presenceErr != nil {
		cancel()
		return
	}
	if !presenceOK {
		cancel()
		return
	}
	// 先读旧值再落盘：比较 generation 需要旧值，而 TakeDiscovery 会覆盖，顺序不能反。
	// 读失败 fail-open——不拒绝上传，静默返回让设备下次重试覆盖。
	old, hadOld, getErr := h.presence.GetDiscovery(ctx, sender.deviceID)
	if getErr != nil {
		cancel()
		return
	}
	// generation 单调约束限定在同一 Discovery owner 内：同一连接（ConnectionID 相同）
	// 重复上报更小值 = 客户端 bug，拒绝（回退的旧值会在 presence TTL 内被下一次合法
	// 上传覆盖）。不同 owner（重连 / 升级后的新连接）视为新的可发现 epoch，允许任意正
	// generation——否则旧版本随机大 generation 残留会拒绝升级客户端更小的 Unix-ms
	// generation，导致设备一直不可发现。
	if hadOld && old.ConnectionID == sender.connectionID {
		if d.Generation < old.Generation {
			cancel()
			return
		}
		// 同 generation 的 Discovery 不可变：同一 owner 下 generation 相同但候选/能力
		// 内容变化 = 客户端 bug（候选变化必须 generation++）。拒绝，保证「同一个
		// generation 永远对应同一份 Discovery 快照」，否则同 generation 静默覆盖且不
		// 广播 peer_updated，会让其它设备持有与服务器不一致的缓存。
		if d.Generation == old.Generation && !sameDiscoveryContent(old, d) {
			cancel()
			return
		}
		// v1 上传映射进 v2 模型：同一 owner（连接）沿用其 runtime_epoch；generation
		// 变化时 revision 严格递增（明确版 §7 的 revision 单调约束），同 generation
		// 刷新保持 revision 不变。新 owner（重连/跨实例接管）派生新的 epoch、revision
		// 从 1 开始。
		d.RuntimeEpochHigh = old.RuntimeEpochHigh
		d.RuntimeEpochLow = old.RuntimeEpochLow
		d.Revision = old.Revision
		if old.Generation != d.Generation {
			d.Revision = old.Revision + 1
			if d.Revision == 0 {
				d.Revision = 1 // uint32 回绕兜底，维持 READY 判据 revision>0。
			}
		}
	} else {
		d.RuntimeEpochHigh, d.RuntimeEpochLow = newRuntimeEpoch()
		d.Revision = 1
	}
	// 落盘前判定设备此前是否已可连接（明确版 §13 收紧版）：presence+discovery 均有效、
	// discovery 已可靠发布（ready()：revision>0，v1 由 generation 派生）、且 presence
	// 与 discovery 的 owner 一致。用于区分 peer_online（首次可发现，含重连窗口内旧连接
	// 残留 discovery 的情况——owner 不一致视为新上线）与 peer_updated（已在线仅换代）。
	wasOnline := presenceOK && hadOld && old.ready() &&
		presence.ConnectionID == old.ConnectionID
	// CAS TakeDiscovery：存储层在 Redis Lua / 内存实现里原子校验「写者仍是当前
	// presence owner」，杜绝 get-then-set 的 TOCTOU（被取代的旧连接无法把新连接的
	// discovery 覆盖回自身）。
	err := h.presence.TakeDiscovery(ctx, sender.deviceID, sender.connectionID, d, h.presenceTTL)
	if err != nil {
		cancel()
		if errors.Is(err, errDiscoveryNotOwner) {
			// 已被同设备的新连接取代（presence 已易主）：本连接是僵尸，自愈关闭，
			// 让设备重连收敛到唯一在线连接（与心跳路径 RenewPresence=false 一致）。
			closePeer(sender)
		}
		// 其它落盘失败 fail-open：保持连接，设备可随时重试上传。
		return
	}
	cancel()
	frameType := ""
	if !wasOnline {
		// 首次可发现（此前无 discovery、或只有旧连接 owner 不一致/占位的残留）：广播
		// peer_online。占位 discovery 已移除，首次上报即首次可发现，§8 由此自然成立。
		frameType = framePeerOnline
	} else if old.Generation != d.Generation {
		frameType = framePeerUpdated
	}
	if frameType != "" {
		h.broadcastPeerEvent(frameType, sender.deviceID, d.Generation)
	}
	if frameType == framePeerOnline {
		// 首次可发现：把当前在线设备快照回给上报设备，作为其本地设备列表基线。
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
	// 快照帧单独 marshal：Peers 字段不带 omitempty——空快照也必须输出 "peers":[]。
	// 若沿用 controlFrame 的 omitempty，空列表会被省略成 {"type":"presence_snapshot"}，
	// Rust 客户端 decode_event 把缺失 peers 当协议错误断连，单设备中继即陷入重连循环。
	frame, _ := json.Marshal(struct {
		Type  string        `json:"type"`
		Peers []peerSummary `json:"peers"`
	}{Type: framePresenceSnapshot, Peers: peers})
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
		// Publish 加 presenceLeaseTimeout 限时：本方法从设备 read goroutine 调用
		//（handleDiscoveryUpdate 路径），Redis 卡顿时不能像 connection.replaced
		// 那样用无限 Background 阻塞帧转发。
		pctx, pcancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
		_ = h.presence.Publish(pctx, RelayEvent{
			Type:       eventType,
			DeviceID:   deviceID,
			Generation: gen,
			InstanceID: h.instanceID,
			Time:       time.Now().UnixMilli(),
		})
		pcancel()
	}
}

// sameDiscoveryContent 比较两份 discovery 快照的候选与能力集合是否一致（无序）。
// 同 generation 必须对应同一份快照：集合比较允许候选顺序变化，但成员不能增删改。
func sameDiscoveryContent(a, b Discovery) bool {
	return sameStringSet(a.Candidates, b.Candidates) && sameStringSet(a.Capabilities, b.Capabilities)
}

// sameStringSet 无序比较两个字符串切片是否构成相同集合（允许顺序不同）。
func sameStringSet(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	counts := make(map[string]int, len(a))
	for _, value := range a {
		counts[value]++
	}
	for _, value := range b {
		if counts[value] == 0 {
			return false
		}
		counts[value]--
	}
	return true
}
