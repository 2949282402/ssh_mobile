// Device-lifecycle events carried over the Redis Pub/Sub event bus, plus the
// periodic revocation reconciliation that bounds the missed-event window.
//
// Relay Control and Relay Data are single-instance in this phase; there is no
// Global Control Routing or Relay Data Node Selection (design §26). Redis is the
// shared-live-state layer: the event bus is the shared channel that lets a
// second instance (e.g. a future migration or a failover) converge on the same
// lifecycle decisions while each instance handles its own local hub. The memory
// store publishes nothing (events are handled locally), so memory mode has no
// subscriber goroutine.

package relay

import (
	"context"
	"time"
)

// RelayEvent 是经 relayEventsChannel 广播的跨实例生命周期事件。
// connection.replaced 额外携带新旧连接的实例/连接 ID，供旧实例定向断开被取代的
// 那条连接（而非整个 device，避免延迟事件误踢更新一代）。
// peer_online/peer_updated/peer_offline 只携带设备 ID：订阅侧从共享 discovery 回查
// runtime_epoch/revision 来重建推送发现帧（advisory，best-effort）。
type RelayEvent struct {
	Type                 string `json:"type"`
	DeviceID             string `json:"device_id"`
	EnrollmentGeneration int64  `json:"enrollment_generation,omitempty"`
	Time                 int64  `json:"ts"`
	// InstanceID 是发布事件实例的标识：推送发现事件由发布方先本地广播再 Publish，
	// 订阅方（含发布方自身的订阅连接）据此跳过同实例回环，避免对本地 peer 重复推送。
	InstanceID      string `json:"instance_id,omitempty"`
	OldInstanceID   string `json:"old_instance_id,omitempty"`
	OldConnectionID string `json:"old_connection_id,omitempty"`
	NewConnectionID string `json:"new_connection_id,omitempty"`
}

const (
	// eventDeviceRevoked 表示设备被吊销，所有实例应断开其连接。
	eventDeviceRevoked = "device.revoked"
	// eventDeviceKicked 表示设备被重新 enroll/抢占，所有实例应断开旧连接。
	eventDeviceKicked = "device.kicked"
	// eventConnectionReplaced 表示设备在线租约已被另一实例的新连接接管；旧实例
	// 据此定向断开指定的 old_connection_id，让跨实例替换立即收敛（而非等旧连接
	// 下一次心跳续租失败才自愈）。heartbeat CAS renew 保留作事件丢失的兜底。
	eventConnectionReplaced = "connection.replaced"
	// eventPeerOnline 表示设备首次上报 discovery，所有实例向本实例其余 peer
	// 广播 peer_online 帧。
	eventPeerOnline = "peer.online"
	// eventPeerUpdated 表示设备 discovery generation 变化，所有实例广播 peer_updated。
	eventPeerUpdated = "peer.updated"
	// eventPeerOffline 表示设备离线（sweeper 清理僵尸连接），所有实例广播 peer_offline。
	eventPeerOffline = "peer.offline"

	// reconcileInterval 是吊销对账周期：封顶 Redis 抖动期间丢失事件的窗口。
	reconcileInterval = 15 * time.Second
	// revocationReconcileTimeout is one budget for the complete sweep, not a
	// fresh timeout per device. Storage currently exposes only point lookups, so
	// this bounds the N+1 scan and defers any unchecked tail to the next sweep.
	revocationReconcileTimeout = 5 * time.Second
)

// handleRelayEvent 处理来自事件总线的跨实例事件。内存模式不订阅，因此本方法只
// 在 Redis 缓存激活时被调用。
func (s *Server) handleRelayEvent(event RelayEvent) {
	switch event.Type {
	case eventDeviceRevoked:
		s.handleRevokedEvent(event)
	case eventDeviceKicked:
		s.handleKickedEvent(event)
	case eventConnectionReplaced:
		s.hub.disconnectConnection(event.DeviceID, event.OldConnectionID)
	case eventPeerOnline, eventPeerUpdated, eventPeerOffline:
		// 发布方（含本实例自己的订阅连接）会收到自己发布的事件；发布方已在本地
		// 广播过，这里跳过同实例回环，避免对本地 peer 重复推送。
		if event.InstanceID == s.hub.instanceID {
			return
		}
		// 其它实例发布的推送发现事件：本实例把对应 hint 广播给所有本地 v2 控制面 peer
		// （排除事件归属设备自身，它所在的实例负责直接通知它）。online/updated 的
		// epoch/revision 需回查共享 discovery（best-effort，advisory）。
		frameType := map[string]string{
			eventPeerOnline:  framePeerOnline,
			eventPeerUpdated: framePeerUpdated,
			eventPeerOffline: framePeerOffline,
		}[event.Type]
		d := Discovery{}
		if frameType != framePeerOffline && s.hub.presence != nil {
			dctx, dcancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
			if dd, ok, err := s.hub.presence.GetDiscovery(dctx, event.DeviceID); err == nil && ok {
				d = dd
			}
			dcancel()
		}
		s.hub.broadcastPeerHintV2(frameType, event.DeviceID, d)
	}
}

// handleKickedEvent converges on the latest durable generation rather than
// trusting event delivery order. A stale event can still clean up older local
// sockets, but it can never close a socket authenticated under the current or a
// newer enrollment generation.
func (s *Server) handleKickedEvent(event RelayEvent) {
	unlock, locked := s.lockDeviceContext(s.eventsCtx, event.DeviceID)
	if !locked {
		return
	}
	defer unlock()
	cutoff := event.EnrollmentGeneration
	ctx, cancel := context.WithTimeout(s.eventsCtx, presenceLeaseTimeout)
	device, err := s.store.GetEnrollment(ctx, event.DeviceID)
	cancel()
	if err == nil && device != nil && device.EnrolledAt.UnixMicro() > cutoff {
		cutoff = device.EnrolledAt.UnixMicro()
	}
	if cutoff <= 0 {
		// Legacy publishers did not carry a generation. Preserve their old
		// behavior during rolling deployment; new publishers always bind one.
		s.relayData.closeDevice(event.DeviceID)
		s.hub.disconnectDevice(event.DeviceID)
		return
	}
	s.relayData.closeDeviceBeforeGeneration(event.DeviceID, cutoff)
	s.hub.disconnectDeviceBeforeGeneration(event.DeviceID, cutoff)
}

// handleRevokedEvent uses the atomically removed enrollment generation carried
// by the event. If the device has since re-enrolled, only pre-generation
// sockets are closed; if it remains absent, every local socket is terminal.
func (s *Server) handleRevokedEvent(event RelayEvent) {
	unlock, locked := s.lockDeviceContext(s.eventsCtx, event.DeviceID)
	if !locked {
		return
	}
	defer unlock()
	ctx, cancel := context.WithTimeout(s.eventsCtx, presenceLeaseTimeout)
	device, err := s.store.GetEnrollment(ctx, event.DeviceID)
	cancel()
	if err == nil && device != nil {
		current := device.EnrolledAt.UnixMicro()
		if event.EnrollmentGeneration > 0 && current > event.EnrollmentGeneration {
			s.relayData.closeDeviceBeforeGeneration(event.DeviceID, current)
			s.hub.disconnectDeviceBeforeGeneration(event.DeviceID, current)
			return
		}
	}
	if err != nil && event.EnrollmentGeneration > 0 {
		// A storage outage must not let the revoked generation keep transferring,
		// but generation-scoped closure preserves any later re-enrollment.
		cutoff := event.EnrollmentGeneration + 1
		s.relayData.closeDeviceBeforeGeneration(event.DeviceID, cutoff)
		s.hub.disconnectDeviceBeforeGeneration(event.DeviceID, cutoff)
		return
	}
	if err == nil && device == nil {
		// The durable enrollment is gone, so this identity no longer consumes a
		// discovery limiter slot. A delayed event that sees a later enrollment
		// returns above and deliberately preserves its reconnect budget.
		s.hub.forgetDiscoveryPublish(event.DeviceID)
	}
	s.relayData.closeDevice(event.DeviceID)
	s.hub.disconnectDevice(event.DeviceID)
}

// startEventSubscribers 在 Redis 缓存激活时启动事件订阅与吊销对账 goroutine。
// 内存模式无订阅者（事件在本地直接处理）。
func (s *Server) startEventSubscribers() {
	redis, ok := s.cache.(*redisStore)
	if !ok {
		return
	}
	s.eventsWG.Add(1)
	go func() {
		defer s.eventsWG.Done()
		_ = redis.runEventSubscriber(s.eventsCtx, s.handleRelayEvent)
	}()
	s.eventsWG.Add(1)
	go func() {
		defer s.eventsWG.Done()
		s.reconcileRevocations()
	}()
}

// reconcileRevocations 周期扫描本地已连接的设备，吊销在有效期内的一律断开。
// 事件总线没有重放：订阅重连窗口内丢失的 device.revoked 事件由本对账兜底，
// 使被吊销设备在他实例上的存活连接最多保留一个对账周期。
func (s *Server) reconcileRevocations() {
	ticker := time.NewTicker(reconcileInterval)
	defer ticker.Stop()
	for {
		select {
		case <-s.eventsCtx.Done():
			return
		case <-ticker.C:
			s.reconcileRevocationsOnce()
		}
	}
}

// reconcileRevocationsOnce 执行一次吊销对账扫描，单独抽出便于直接测试。
func (s *Server) reconcileRevocationsOnce() {
	ctx, cancel := context.WithTimeout(s.eventsCtx, revocationReconcileTimeout)
	defer cancel()
	s.reconcileRevocationsWithContext(ctx)
}

// reconcileRevocationsWithContext scans one snapshot under a single caller
// budget. Server.Close cancels eventsCtx, which also cancels an in-flight store
// call and lets the event goroutine join before cache/store shutdown.
func (s *Server) reconcileRevocationsWithContext(ctx context.Context) {
	s.hub.mutex.Lock()
	deviceIDs := make(map[string]struct{}, len(s.hub.peers))
	for deviceID := range s.hub.peers {
		deviceIDs[deviceID] = struct{}{}
	}
	for deviceID := range s.hub.pendingAdmissions {
		deviceIDs[deviceID] = struct{}{}
	}
	s.hub.mutex.Unlock()
	for _, deviceID := range s.relayData.deviceIDs() {
		deviceIDs[deviceID] = struct{}{}
	}
	for deviceID := range deviceIDs {
		if ctx.Err() != nil {
			return
		}
		unlock, locked := s.lockDeviceContext(ctx, deviceID)
		if !locked {
			return
		}
		// Atomic revoke deletes the enrollment and same-key re-enrollment advances
		// its monotonic generation. One GetEnrollment therefore reconciles both a
		// missed revoke and a missed kick without the previous IsRevoked + Get N+1.
		device, err := s.store.GetEnrollment(ctx, deviceID)
		if err != nil {
			unlock()
			if ctx.Err() != nil {
				return
			}
			s.logger.Warn("revocation reconciliation could not check device",
				"device_id", deviceID, "error", err)
			continue
		}
		if device == nil {
			s.relayData.closeDevice(deviceID)
			s.hub.disconnectDevice(deviceID)
			s.hub.forgetDiscoveryPublish(deviceID)
			unlock()
			continue
		}
		generation := device.EnrolledAt.UnixMicro()
		s.relayData.closeDeviceBeforeGeneration(deviceID, generation)
		s.hub.disconnectDeviceBeforeGeneration(deviceID, generation)
		unlock()
	}
}
