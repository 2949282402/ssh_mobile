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
	"encoding/json"
	"time"

	"github.com/gorilla/websocket"
)

// RelayEvent 是经 relayEventsChannel 广播的跨实例生命周期事件。
// connection.replaced 额外携带新旧连接的实例/连接 ID，供旧实例定向断开被取代的
// 那条连接（而非整个 device，避免延迟事件误踢更新一代）。
// peer_online/peer_updated/peer_offline 携带该设备的 discovery generation，供
// 其它实例重建推送发现帧。
type RelayEvent struct {
	Type       string `json:"type"`
	DeviceID   string `json:"device_id"`
	Time       int64  `json:"ts"`
	Generation uint64 `json:"generation,omitempty"`
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
)

// handleRelayEvent 处理来自事件总线的跨实例事件。内存模式不订阅，因此本方法只
// 在 Redis 缓存激活时被调用。
func (s *Server) handleRelayEvent(event RelayEvent) {
	switch event.Type {
	case eventDeviceRevoked, eventDeviceKicked:
		s.hub.disconnectDevice(event.DeviceID)
	case eventConnectionReplaced:
		s.hub.disconnectConnection(event.DeviceID, event.OldConnectionID)
	case eventPeerOnline, eventPeerUpdated, eventPeerOffline:
		// 发布方（含本实例自己的订阅连接）会收到自己发布的事件；发布方已在本地
		// 广播过，这里跳过同实例回环，避免对本地 peer 重复推送。
		if event.InstanceID == s.hub.instanceID {
			return
		}
		// 其它实例发布的推送发现事件：本实例把对应帧广播给所有本地 peer（排除事件
		// 归属设备自身，它所在的实例负责直接通知它）。
		frameType := map[string]string{
			eventPeerOnline:  framePeerOnline,
			eventPeerUpdated: framePeerUpdated,
			eventPeerOffline: framePeerOffline,
		}[event.Type]
		frame, _ := json.Marshal(controlFrame{Type: frameType, DeviceID: event.DeviceID, Generation: event.Generation})
		s.hub.broadcast(event.DeviceID, outboundFrame{websocket.TextMessage, frame})
	}
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
	s.hub.mutex.Lock()
	peers := make([]string, 0, len(s.hub.peers))
	for deviceID := range s.hub.peers {
		peers = append(peers, deviceID)
	}
	s.hub.mutex.Unlock()
	for _, deviceID := range peers {
		// IsRevoked 是单个存储调用，store 内部并发安全，无需任何调用方锁——旧的全局
		// devicesMutex 让每 15s 一次、对全部在线设备的吊销对账把所有 device-plane 请求
		// 串行化（MySQL 模式一个 RTT 一锁，直接吃吞吐）。
		revoked, err := s.store.IsRevoked(context.Background(), deviceID, time.Now())
		if err != nil {
			s.logger.Warn("revocation reconciliation could not check device",
				"device_id", deviceID, "error", err)
			continue
		}
		if revoked {
			s.hub.disconnectDevice(deviceID)
		}
	}
}
