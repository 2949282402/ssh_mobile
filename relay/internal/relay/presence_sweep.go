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

// sweepPresenceOnce 执行一次僵尸 peer 清扫。以共享缓存 ListOnlinePeers（presence+
// discovery 均有效的设备，明确版 §13）为准：本地 hub 里不在该集合的设备视为僵尸——
// 其租约已过期（60s 无心跳）或已被其它实例接管。本地表不权威：本实例只关闭并广播
// 本地持有的连接，peer_offline 的跨实例通知走事件总线；同一设备只由持有其本地连接
// 的实例发一次，避免重复推送。
func (s *Server) sweepPresenceOnce() {
	ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	online, err := s.cache.ListOnlinePeers(ctx)
	cancel()
	if err != nil {
		s.logger.Warn("presence sweep could not list online peers", "error", err)
		return
	}
	s.hub.mutex.Lock()
	var zombies []*peer
	for deviceID, p := range s.hub.peers {
		if _, ok := online[deviceID]; !ok {
			zombies = append(zombies, p)
		}
	}
	s.hub.mutex.Unlock()
	for _, p := range zombies {
		s.logger.Info("presence sweep closing zombie peer",
			"device_id", p.deviceID, "connection_id", p.connectionID)
		// 只关闭仍归本实例持有的连接；若连接在此期间已自愈或已被替换，disconnectDevice
		// 的 CAS 释放会安全跳过，不会误删新连接。
		s.hub.disconnectDevice(p.deviceID)
		s.hub.broadcastPeerEvent(framePeerOffline, p.deviceID, 0)
	}
}
