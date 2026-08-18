// v2 Relay 控制面（GET /v2/control，设计 §24/§32/§33）。
//
// 控制面连接是一条长期存活的 WebSocket，只承载 protobuf 二进制 RelayFrame（每帧 =
// [4-byte BE 长度][RelayFrame]，codec.DecodeControl）。它复用 hub 的 peer 表与
// presence 租约：/v2/control 连接经 hub.add 入表、占据设备 presence 租约、受服务端
// 心跳监视器与 sweeper 管辖。控制面纯净性：RelayDataFrame（或空 kind 帧）在这条
// 路由上是协议违规，直接关闭。
//
// 每条控制面连接的帧分派见 routeControlV2。服务端→客户端的方向性消息（Ready/
// HeartbeatAck/DiscoveryAck/ResolvePeerResponse/RelayReserveResponse/
// IncomingRelayReservation，以及 PresenceHintSnapshot/PeerAvailableHint/
// PeerUnavailableHint 三帧 presence 提示）若由客户端反向发送，一律按控制面纯净性判
// 协议违规——回一帧 ProtocolError 后关闭连接，绝不原样广播。

package relay

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

// v2AttemptLifetime 是 v2Attempt 路由注册表条目的存活上限：覆盖一次 ConnectivityAttempt
// 的完整 offer→answer 窗口（设计 §12 单次 attempt 一次性状态）。
const v2AttemptLifetime = 30 * time.Second

// v2Attempt 记录一条已转发的 ConnectivityOffer 的发起方，供 ConnectivityAnswer /
// ProtocolError 按 attempt_id 回路由。条目带过期时间，由 hub.prune 惰性清理。
type v2Attempt struct {
	initiator string
	expiresAt time.Time
}

// ---------------------------------------------------------------------------
// HTTP：GET /v2/control
// ---------------------------------------------------------------------------

// connectControlV2 处理 /v2/control 升级：bearer 认证（authenticatedRequest），
// 升级后服务端先发 Ready（protocol_version=2 + heartbeat/ttl 等），随后按 v2 控制面
// 读循环运行。Ready 在 hub.add 之前入队，保证它是客户端收到的第一帧。
func (s *Server) connectControlV2(w http.ResponseWriter, r *http.Request) {
	claims, _, code, ok := s.authenticatedRequest(r)
	if !ok {
		retry := retryUnspecified
		if code == relayErrorCredentialExpired {
			retry = retryRefreshCredentialThenRetry
		}
		writeNetworkErrorRetry(w, http.StatusUnauthorized, code,
			"Relay control-plane authentication failed.", "connect_relay_v2", "", retry, 0)
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
		relayHost:          r.Host,
	}
	ready, err := v2.EncodeFrame(&v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_Ready{Ready: &v2.Ready{
			ProtocolVersion:    v2.RELAY_V2_VERSION,
			DeviceId:           claims.DeviceID,
			ServerTimeMs:       time.Now().UnixMilli(),
			HeartbeatIntervalS: v2.HEARTBEAT_INTERVAL_S,
			PresenceTtlS:       v2.PRESENCE_TTL_S,
		}},
	})
	if err != nil {
		_ = connection.Close()
		return
	}
	// 先入队 Ready 再 add：write goroutine 从 outbound 先写它，客户端收到的第一帧
	// 一定是 Ready（随后任何 heartbeat ack 都在它之后）。
	if !peer.enqueue(outboundFrame{websocket.BinaryMessage, ready}) {
		_ = connection.Close()
		return
	}
	if !s.hub.add(peer) {
		_ = connection.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "connection limit"), time.Now().Add(time.Second))
		_ = connection.Close()
		return
	}
}

// ---------------------------------------------------------------------------
// 帧分派
// ---------------------------------------------------------------------------

// routeControlV2 解码并分派一条 /v2/control 二进制帧。返回 false 表示应关闭连接
// （帧级协议违规）。解码/版本/边界违规先用同步写冲刷一帧 ProtocolError 再关闭——
// 不能走 outbound 异步队列，否则 read goroutine 的 defer closePeer 会在 write
// goroutine 冲刷前关掉 socket，ProtocolError 丢失。
func (h *hub) routeControlV2(sender *peer, data []byte) bool {
	// 每帧重核 currency（v1 routeControl 的同款守卫）：被取代/撤销的控制连接，其 read
	// goroutine 仍可能读到一帧在途数据（closePeer 之后、socket 关闭之前）。若不拦截，
	// 这条陈旧连接仍能分派 ConnectivityOffer/RelayReserveRequest/RealtimeSignal。
	// 返回 false 让 hub.read 关闭这条连接。速率限制检查在其后（两者都保留）。
	h.mutex.Lock()
	isCurrent := h.peers[sender.deviceID] == sender
	h.mutex.Unlock()
	if !isCurrent {
		return false
	}
	if !sender.allowFrame(len(data)) {
		h.sendV2ProtocolErrorSync(sender, 0, v2.ErrorCode_ERROR_CODE_RATE_LIMITED, "control frame rate limit exceeded")
		return false
	}
	frame, err := v2.DecodeControl(data)
	if err != nil {
		code := v2.ErrorCodeOf(err)
		if code == v2.ErrorCode_ERROR_CODE_UNSPECIFIED {
			code = v2.ErrorCode_ERROR_CODE_MALFORMED_FRAME
		}
		h.sendV2ProtocolErrorSync(sender, 0, code, err.Error())
		return false
	}
	if frame.Kind == nil {
		// 空 kind 帧（例如把 RelayDataFrame 的载荷当 RelayFrame 解码、或未知 oneof
		// 之外的裸版本帧）是控制面纯净性违规。
		h.sendV2ProtocolErrorSync(sender, 0, v2.ErrorCode_ERROR_CODE_PROTOCOL, "empty control frame is a protocol violation")
		return false
	}
	switch kind := frame.Kind.(type) {
	case *v2.RelayFrame_Heartbeat:
		h.handleHeartbeatV2(sender, kind.Heartbeat)
	case *v2.RelayFrame_DiscoveryPublish:
		h.handleDiscoveryPublishV2(sender, kind.DiscoveryPublish)
	case *v2.RelayFrame_ResolvePeerRequest:
		h.handleResolvePeerRequestV2(sender, kind.ResolvePeerRequest)
	case *v2.RelayFrame_ConnectivityOffer:
		h.handleConnectivityOfferV2(sender, kind.ConnectivityOffer)
	case *v2.RelayFrame_ConnectivityAnswer:
		h.handleConnectivityAnswerV2(sender, kind.ConnectivityAnswer)
	case *v2.RelayFrame_PresenceHintSnapshot, *v2.RelayFrame_PeerAvailableHint, *v2.RelayFrame_PeerUnavailableHint:
		// PresenceHintSnapshot/PeerAvailableHint/PeerUnavailableHint 都是服务端→客户端
		// 方向（服务端由 broadcastPeerHintV2 从权威 presence/discovery 状态构造）。
		// 已认证的客户端反向原样发送这些帧，可伪装任意设备的在线/离线提示广播给整个
		// fleet，因此按控制面纯净性同其它服务端方向帧一样判违规并关闭连接。
		h.sendV2ProtocolErrorSync(sender, 0, v2.ErrorCode_ERROR_CODE_PROTOCOL,
			"client must not send server-direction control frames")
		return false
	case *v2.RelayFrame_RelayReserveRequest:
		h.handleRelayReserveRequestV2(sender, kind.RelayReserveRequest)
	case *v2.RelayFrame_RealtimeSignal:
		h.handleRealtimeSignalV2(sender, kind.RealtimeSignal)
	case *v2.RelayFrame_ProtocolError:
		h.handleProtocolErrorV2(sender, frame)
	default:
		// Ready/HeartbeatAck/DiscoveryAck/ResolvePeerResponse/RelayReserveResponse/
		// IncomingRelayReservation 都是服务端→客户端方向，合法的 v2 客户端绝不会反向
		// 发送。这些 oneof tag（尤其 10/12）与 RelayDataFrame 的 connect/ack 重叠——
		// 数据面帧被错投到控制面会伪装成这些方向帧，因此按控制面纯净性直接判违规关闭。
		h.sendV2ProtocolErrorSync(sender, 0, v2.ErrorCode_ERROR_CODE_PROTOCOL,
			"client must not send server-direction control frames")
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// 消息处理
// ---------------------------------------------------------------------------

// handleHeartbeatV2 刷新服务端心跳监视器时间、CAS 续租 presence（并续 discovery
// TTL）、租约被抢时自愈关闭，最后回 HeartbeatAck。
func (h *hub) handleHeartbeatV2(sender *peer, hb *v2.Heartbeat) {
	h.mutex.Lock()
	sender.lastHeartbeat = time.Now()
	h.mutex.Unlock()
	if h.presence != nil {
		leaseCtx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
		ok, err := h.presence.RenewPresence(leaseCtx, sender.deviceID, sender.connectionID, h.presenceFor(sender), h.presenceTTL)
		cancel()
		if err != nil {
			// Redis 抖动或超时：fail-open，下次心跳重试。
		} else if !ok {
			// 租约已被其它连接抢占：本连接已被取代，自愈关闭且不回 ack。
			closePeer(sender)
			return
		}
		discCtx, dcancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
		_, _ = h.presence.RenewDiscovery(discCtx, sender.deviceID, sender.connectionID, h.presenceTTL)
		dcancel()
		// 续租后重新核对 currency，防复活已死亡 peer 的租约。
		h.mutex.Lock()
		isCurrent := h.peers[sender.deviceID] == sender
		h.mutex.Unlock()
		if !isCurrent {
			_, _ = h.presence.ReleasePresence(context.Background(), sender.deviceID, sender.connectionID)
			closePeer(sender)
			return
		}
	}
	h.sendV2Frame(sender, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_HeartbeatAck{HeartbeatAck: &v2.HeartbeatAck{
			RequestId:    hb.RequestId,
			ServerTimeMs: time.Now().UnixMilli(),
		}},
	})
}

// handleDiscoveryPublishV2 调用 Step-3 的可靠发布原语 publishDiscoveryV2：落盘
// discovery、广播 peer_online/peer_updated，并向发布客户端回 DiscoveryAck。失败按
// 冻结错误模型映射 ProtocolError（EPOCH_CONFLICT / REVISION_STALE / CONTROL_UNAVAILABLE）。
func (h *hub) handleDiscoveryPublishV2(sender *peer, pub *v2.DiscoveryPublish) {
	ack, err := h.publishDiscoveryV2(pub.RequestId, sender.deviceID, sender.connectionID, pub.Snapshot)
	if err != nil {
		code := v2.ErrorCode_ERROR_CODE_CONTROL_UNAVAILABLE
		switch {
		case errors.Is(err, errDiscoveryRevisionStale),
			errors.Is(err, errDiscoveryRevisionImmutable),
			errors.Is(err, errDiscoveryNoRevision):
			code = v2.ErrorCode_ERROR_CODE_REVISION_STALE
		case errors.Is(err, errDiscoveryNotOwner):
			code = v2.ErrorCode_ERROR_CODE_EPOCH_CONFLICT
		}
		h.sendV2ProtocolError(sender, pub.RequestId, code, err.Error())
		return
	}
	h.sendV2Frame(sender, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_DiscoveryAck{DiscoveryAck: ack},
	})
}

// handleResolvePeerRequestV2 用权威 4-state resolve（设计 §10）判定目标可连性：
// READY 携带 discovery；OFFLINE/NOT_READY/UNKNOWN 分别回状态并附 retry_after_ms 提示。
func (h *hub) handleResolvePeerRequestV2(sender *peer, req *v2.ResolvePeerRequest) {
	ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	result := h.resolvePeer(ctx, req.TargetDeviceId)
	cancel()
	resp := &v2.ResolvePeerResponse{RequestId: req.RequestId, Status: result.status}
	switch result.status {
	case v2.ResolveStatus_RESOLVE_STATUS_READY:
		resp.Discovery = discoveryToV2(result.discovery)
	case v2.ResolveStatus_RESOLVE_STATUS_NOT_READY:
		resp.RetryAfterMs = v2.RESOLVE_RETRY_HINT_NOT_READY_MS
	case v2.ResolveStatus_RESOLVE_STATUS_UNKNOWN:
		resp.RetryAfterMs = v2.RESOLVE_RETRY_HINT_UNKNOWN_MS
	}
	h.sendV2Frame(sender, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_ResolvePeerResponse{ResolvePeerResponse: resp},
	})
}

// handleConnectivityOfferV2 按 offer 自带的显式 target_device_id 转发
// （设计 §14：A ConnectivityOffer(target=B) → B）。转发前服务端用 A 当前已发布的
// discovery 覆盖 initiator_snapshot，并登记 attempt_id → initiator，供对端
// ConnectivityAnswer / ProtocolError 回路由。
func (h *hub) handleConnectivityOfferV2(sender *peer, offer *v2.ConnectivityOffer) {
	targetID := offer.TargetDeviceId
	if targetID == "" || targetID == sender.deviceID {
		h.sendV2ProtocolError(sender, offer.RequestId, v2.ErrorCode_ERROR_CODE_PEER_NOT_READY,
			"connectivity offer requires a different target device")
		return
	}
	// 服务端用 A 的已发布 discovery 覆盖 offer 里的 initiator_snapshot（§14：B 从
	// offer 拿到 A 当前完整 Discovery，offer/answer 不再承担 discovery 同步职责）。
	if h.presence != nil {
		dctx, dcancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
		d, ok, err := h.presence.GetDiscovery(dctx, sender.deviceID)
		dcancel()
		if err == nil && ok && d.ready() {
			offer.InitiatorSnapshot = discoveryToV2(d)
		}
	}
	// 发起方身份以服务端认证为准：客户端可任意填写 initiator_device_id（伪造为其它设备），
	// 服务端在转发前强制覆盖为发送者，防止对端把被伪装的设备记为协商发起方。
	offer.InitiatorDeviceId = sender.deviceID
	h.mutex.Lock()
	if h.v2Attempts == nil {
		h.v2Attempts = make(map[string]v2Attempt)
	}
	h.v2Attempts[offer.AttemptId] = v2Attempt{initiator: sender.deviceID, expiresAt: time.Now().Add(v2AttemptLifetime)}
	target := h.peers[targetID]
	h.mutex.Unlock()
	if target == nil {
		h.sendV2ProtocolError(sender, offer.RequestId, v2.ErrorCode_ERROR_CODE_PEER_OFFLINE,
			"target peer is not connected on the v2 control plane")
		return
	}
	h.sendV2Frame(target, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_ConnectivityOffer{ConnectivityOffer: offer},
	})
}

// handleConnectivityAnswerV2 把 B 的 ConnectivityAnswer 按 attempt_id 回路由给发起方
// A（attempt 一次性，转发后即删除注册）。
func (h *hub) handleConnectivityAnswerV2(sender *peer, ans *v2.ConnectivityAnswer) {
	h.mutex.Lock()
	attempt, ok := h.v2Attempts[ans.AttemptId]
	if ok {
		delete(h.v2Attempts, ans.AttemptId)
	}
	initiator := (*peer)(nil)
	if ok && attempt.initiator != "" && attempt.initiator != sender.deviceID {
		initiator = h.peers[attempt.initiator]
	}
	h.mutex.Unlock()
	if !ok || initiator == nil {
		h.sendV2ProtocolError(sender, ans.RequestId, v2.ErrorCode_ERROR_CODE_PROTOCOL, "unknown attempt_id")
		return
	}
	h.sendV2Frame(initiator, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_ConnectivityAnswer{ConnectivityAnswer: ans},
	})
}

// handleRealtimeSignalV2 转发 WebRTC 风格的信令（不透明 payload，Relay 不解析）到
// target_device_id 的 v2 控制面连接。sender_device_id 始终由认证连接覆盖，接收端
// 只能据此识别远端 peer，绝不能把 target_device_id 当作发送方。
func (h *hub) handleRealtimeSignalV2(sender *peer, sig *v2.RealtimeSignal) {
	if sig.TargetDeviceId == "" || sig.TargetDeviceId == sender.deviceID {
		h.sendV2ProtocolError(sender, sig.RequestId, v2.ErrorCode_ERROR_CODE_PROTOCOL, "invalid realtime target")
		return
	}
	h.mutex.Lock()
	target := h.peers[sig.TargetDeviceId]
	h.mutex.Unlock()
	if target == nil {
		h.sendV2ProtocolError(sender, sig.RequestId, v2.ErrorCode_ERROR_CODE_PEER_OFFLINE, "target peer is not connected on the v2 control plane")
		return
	}
	// 客户端提供的 sender_device_id 仅是提示字段；认证连接身份是唯一可信来源。
	sig.SenderDeviceId = sender.deviceID
	h.sendV2Frame(target, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_RealtimeSignal{RealtimeSignal: sig},
	})
}

// handleProtocolErrorV2 把带 attempt_id 的 ProtocolError 转发给该 attempt 的发起方
// （例如 B 对 A 的 offer 返回 PEER_NOT_READY）；无 attempt_id 或找不到发起方则丢弃。
func (h *hub) handleProtocolErrorV2(sender *peer, frame *v2.RelayFrame) {
	pe := frame.GetProtocolError()
	if pe == nil || pe.AttemptId == "" {
		return
	}
	h.mutex.Lock()
	attempt, ok := h.v2Attempts[pe.AttemptId]
	target := (*peer)(nil)
	if ok {
		target = h.peers[attempt.initiator]
	}
	h.mutex.Unlock()
	if ok && target != nil && target != sender {
		h.sendV2Frame(target, frame)
	}
}

// handleRelayReserveRequestV2 创建一条 relay-data reservation（设计 §25）：
//  1. 目标必须 READY（权威 resolve，绝不 fail-open）。
//  2. 生成 16-byte hex reservation_id、两个独立 32-byte local_token，存活秒数夹到
//     [15,120]；落盘共享状态（Redis relay:reservation:{id}，TTL=expires_at）。
//  3. 给 A 回 RelayReserveResponse（含自包含 relay_data_endpoint），并给 B 推
//     IncomingRelayReservation——B 在 v2 控制面连接时才能收到。
func (h *hub) handleRelayReserveRequestV2(sender *peer, req *v2.RelayReserveRequest) {
	if req.TargetDeviceId == "" || req.TargetDeviceId == sender.deviceID {
		h.sendV2ProtocolError(sender, req.RequestId, v2.ErrorCode_ERROR_CODE_PEER_NOT_READY, "invalid reservation target")
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	result := h.resolvePeer(ctx, req.TargetDeviceId)
	cancel()
	if result.status != v2.ResolveStatus_RESOLVE_STATUS_READY {
		code := v2.ErrorCode_ERROR_CODE_PEER_OFFLINE
		if result.status == v2.ResolveStatus_RESOLVE_STATUS_NOT_READY {
			code = v2.ErrorCode_ERROR_CODE_PEER_NOT_READY
		}
		h.sendV2ProtocolError(sender, req.RequestId, code, "reservation target is not ready")
		return
	}
	if h.presence == nil {
		h.sendV2ProtocolError(sender, req.RequestId, v2.ErrorCode_ERROR_CODE_RESERVATION_FAILED, "reservation store unavailable")
		return
	}
	lifetime := clampReservationLifetime(req.DesiredLifetimeS)
	reservationID := hex.EncodeToString(randomBytes(v2.RESERVATION_ID_BYTES))
	initiatorToken := randomBytes(v2.RESERVATION_TOKEN_BYTES)
	responderToken := randomBytes(v2.RESERVATION_TOKEN_BYTES)
	now := time.Now()
	expiresAtMs := now.Add(time.Duration(lifetime) * time.Second).UnixMilli()
	// relay_data_endpoint 必须从服务端配置的公共源构造（RELAY_PUBLIC_URL，未配置时从
	// 监听地址派生），绝不使用客户端提供的 Host 头：Host 头攻击者可控，用它构造端点会
	// 把对端 B 的 32-byte ResponderToken 引导到攻击者选择的地址。
	endpoint := fmt.Sprintf("%s/v2/relay/%s", relayDataEndpointOrigin(h.config), reservationID)
	res := Reservation{
		ReservationID:     reservationID,
		AttemptID:         req.AttemptId,
		InitiatorDeviceID: sender.deviceID,
		ResponderDeviceID: req.TargetDeviceId,
		RelayDataEndpoint: endpoint,
		InitiatorToken:    initiatorToken,
		ResponderToken:    responderToken,
		ExpiresAtMs:       expiresAtMs,
		LifetimeS:         lifetime,
	}
	cctx, ccancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	err := h.presence.CreateReservation(cctx, res)
	ccancel()
	if err != nil {
		h.sendV2ProtocolError(sender, req.RequestId, v2.ErrorCode_ERROR_CODE_RESERVATION_FAILED, err.Error())
		return
	}
	// 给 A 回 RelayReserveResponse。
	h.sendV2Frame(sender, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_RelayReserveResponse{RelayReserveResponse: &v2.RelayReserveResponse{
			RequestId:         req.RequestId,
			AttemptId:         req.AttemptId,
			ReservationId:     reservationID,
			RelayDataEndpoint: endpoint,
			ExpiresAtMs:       expiresAtMs,
			LocalToken:        initiatorToken,
		}},
	})
	// 给 B 推 IncomingRelayReservation（B 在线时才推）。
	h.mutex.Lock()
	responder := h.peers[req.TargetDeviceId]
	h.mutex.Unlock()
	if responder != nil {
		h.sendV2Frame(responder, &v2.RelayFrame{
			Version: v2.RELAY_V2_VERSION,
			Kind: &v2.RelayFrame_IncomingRelayReservation{IncomingRelayReservation: &v2.IncomingRelayReservation{
				AttemptId:         req.AttemptId,
				ReservationId:     reservationID,
				InitiatorDeviceId: sender.deviceID,
				RelayDataEndpoint: endpoint,
				ExpiresAtMs:       expiresAtMs,
				LocalToken:        responderToken,
			}},
		})
	}
}

// ---------------------------------------------------------------------------
// 帧发送辅助
// ---------------------------------------------------------------------------

// sendV2Frame 编码并投递一帧 v2 控制帧给指定 peer。编码失败或对端积压/已关闭时定向
// 关闭对端。
func (h *hub) sendV2Frame(peer *peer, frame *v2.RelayFrame) {
	data, err := v2.EncodeFrame(frame)
	if err != nil {
		return
	}
	if !peer.enqueue(outboundFrame{websocket.BinaryMessage, data}) {
		go peer.socket.Close()
	}
}

// sendV2ProtocolError 向 peer 回一条 ProtocolError（request_id 回显失败请求，
// 0 表示服务端主动）。异步入队，用于非致命的错误通知。
func (h *hub) sendV2ProtocolError(peer *peer, requestID uint64, code v2.ErrorCode, message string) {
	h.sendV2Frame(peer, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_ProtocolError{ProtocolError: &v2.ProtocolError{
			RequestId: requestID,
			Code:      code,
			Message:   message,
		}},
	})
}

// sendV2ProtocolErrorSync 在 peer.writeMutex 下同步写一条 ProtocolError，用于协议
// 违规后立即关连接的场景：read goroutine 先冲刷错误帧再让 defer 关闭 socket，保证
// 客户端能收到错误码（区别于异步 enqueue 可能被 closePeer 抢先丢弃）。
func (h *hub) sendV2ProtocolErrorSync(peer *peer, requestID uint64, code v2.ErrorCode, message string) {
	data, err := v2.EncodeFrame(&v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_ProtocolError{ProtocolError: &v2.ProtocolError{
			RequestId: requestID,
			Code:      code,
			Message:   message,
		}},
	})
	if err != nil {
		return
	}
	peer.writeMutex.Lock()
	defer peer.writeMutex.Unlock()
	_ = peer.socket.SetWriteDeadline(time.Now().Add(5 * time.Second))
	_ = peer.socket.WriteMessage(websocket.BinaryMessage, data)
}

// broadcastV2 把一帧 v2 控制帧推给除 exceptDeviceID 外的所有本地 v2 控制面 peer。
// 按 h.broadcast 的「锁内快照、锁外 enqueue」模式执行；enqueue 失败定向关闭。
func (h *hub) broadcastV2(exceptDeviceID string, frame *v2.RelayFrame) {
	data, err := v2.EncodeFrame(frame)
	if err != nil {
		return
	}
	h.mutex.Lock()
	peers := make([]*peer, 0, len(h.peers))
	for deviceID, p := range h.peers {
		if deviceID != exceptDeviceID {
			peers = append(peers, p)
		}
	}
	h.mutex.Unlock()
	for _, p := range peers {
		if !p.enqueue(outboundFrame{websocket.BinaryMessage, data}) {
			go p.socket.Close()
		}
	}
}

// discoveryToV2 把共享存储的 Discovery 反解成冻结契约的 DiscoverySnapshot，供
// ResolvePeerResponse（READY）与 ConnectivityOffer 的 initiator_snapshot 使用。
// candidates 以 base64 存储，这里解码回不透明字节；capabilities 以数字字符串存储，
// 解析回 TransportCapability 枚举。
func discoveryToV2(d Discovery) *v2.DiscoverySnapshot {
	s := &v2.DiscoverySnapshot{
		RuntimeEpoch:  &v2.RuntimeEpoch{High: d.RuntimeEpochHigh, Low: d.RuntimeEpochLow},
		Revision:      d.Revision,
		PublishedAtMs: d.UpdatedAt.UnixMilli(),
	}
	for _, capability := range d.Capabilities {
		if n, err := strconv.ParseUint(capability, 10, 32); err == nil {
			s.TransportCapabilities = append(s.TransportCapabilities, v2.TransportCapability(n))
		}
	}
	if len(d.Candidates) > 0 {
		bundle := &v2.CandidateBundle{}
		for _, candidate := range d.Candidates {
			if raw, err := base64.StdEncoding.DecodeString(candidate); err == nil {
				bundle.Candidates = append(bundle.Candidates, raw)
			}
		}
		s.CandidateBundle = bundle
	}
	return s
}
