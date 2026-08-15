// Cross-instance presence sweeper: closes local hub peers whose presence or
// discovery leases have lapsed (zombies) and broadcasts peer_offline so every
// instance converges on the same online set. The shared cache is the
// authoritative source of truth (明确版 §13); the local hub peer table is never
// authoritative on its own.

package relay

import (
	"context"
	"time"
)

// presenceSweepInterval 是僵尸连接清扫周期：把本地 hub 里「presence/discovery
// 租约已失效但仍挂着的 peer」收敛掉，封顶多实例下事件丢失导致的幽灵连接窗口。
const presenceSweepInterval = 30 * time.Second

// startPresenceSweeper 在 Redis 缓存激活时启动僵尸 peer 清扫 goroutine，与
// startEventSubscribers 共用 eventsCtx/eventsWG 生命周期。内存模式无 Redis TTL
// 与跨实例租约抢占，僵尸只能由本地 remove() 触发，不需要后台清扫。
func (s *Server) startPresenceSweeper() {
	if _, ok := s.cache.(*redisStore); !ok {
		return
	}
	s.eventsWG.Add(1)
	go func() {
		defer s.eventsWG.Done()
		ticker := time.NewTicker(presenceSweepInterval)
		defer ticker.Stop()
		for {
			select {
			case <-s.eventsCtx.Done():
				return
			case <-ticker.C:
				s.sweepPresenceOnce()
			}
		}
	}()
}

// sweepPresenceOnce 执行一次僵尸 peer 清扫。以共享缓存 presence 租约为准（presence
// 才是"在线"权威，明确版 §3）：本地 hub 里 presence 已失效（60s 无心跳）的设备视为
// 僵尸——无论其 discovery 键是否仍在。discovery 键可能被 Redis 逐出（maxmemory）而
// 与在线的 presence 不同步，若以 ListOnlinePeers（presence+discovery 双有效）判僵尸，
// 会把 discovery 丢失但仍在线的设备误杀。本地表不权威：本实例只关闭并广播本地持有
// 的连接，peer_offline 的跨实例通知走事件总线；同一设备只由持有其本地连接的实例发
// 一次，避免重复推送。
func (s *Server) sweepPresenceOnce() {
	s.hub.mutex.Lock()
	localPeers := make([]*peer, 0, len(s.hub.peers))
	for _, p := range s.hub.peers {
		localPeers = append(localPeers, p)
	}
	s.hub.mutex.Unlock()
	deviceIDs := make([]string, 0, len(localPeers))
	for _, p := range localPeers {
		deviceIDs = append(deviceIDs, p.deviceID)
	}
	ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	presences, err := s.cache.GetPresences(ctx, deviceIDs)
	cancel()
	if err != nil {
		s.logger.Warn("presence sweep could not list online peers", "error", err)
		return
	}
	var zombies []*peer
	for _, p := range localPeers {
		if _, ok := presences[p.deviceID]; !ok {
			zombies = append(zombies, p)
		}
	}
	for _, p := range zombies {
		s.logger.Info("presence sweep closing zombie peer",
			"device_id", p.deviceID, "connection_id", p.connectionID)
		// 定向断开快照中的这条连接（disconnectConnection 只关闭 connectionID 匹配的
		// peer）：若设备在快照与断开之间已重连为新的 connectionID，则定向断开是
		// no-op，不会像 disconnectDevice(deviceID) 那样重读 h.peers 误踢新连接。
		// 仅当真断开了匹配连接（返回 true）才广播 peer_offline——若重连的新连接已
		// 接管（no-op），设备实际在线，广播 offline 会误报。
		if s.hub.disconnectConnection(p.deviceID, p.connectionID) {
			s.hub.broadcastPeerEvent(framePeerOffline, p.deviceID, 0)
		}
	}
}
