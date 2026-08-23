// v2 推送发现辅助：broadcastPeerEvent 聚合 v2 hint 广播与跨实例事件发布，
// broadcastPeerHintV2 把 presence 事件转成 protobuf advisory hint。v1 JSON 控制面
// 已随传输网络 v1 一并删除，本文件只保留 v2 控制面的广播原语。

package relay

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

const (
	// Discovery changes fan out to every local control peer and every Relay
	// instance. Permit a short candidate-gathering burst, then refill slowly so
	// one authenticated device cannot sustain fleet-wide amplification.
	discoveryPublishBurst    = 4.0
	discoveryPublishRefill   = 5 * time.Second
	discoveryBudgetRetention = 10 * time.Minute
)

type discoveryPublishBudget struct {
	tokens    float64
	updatedAt time.Time
	lastUsed  time.Time
}

// discoveryFanoutLimiter owns expensive DiscoveryPublish admission state. It
// is device-scoped (not connection-scoped), survives reconnects, and uses its
// own mutex so token accounting never extends the peer-routing critical path.
type discoveryFanoutLimiter struct {
	mutex      sync.Mutex
	budgets    map[string]discoveryPublishBudget
	maxDevices int
}

func newDiscoveryFanoutLimiter(maxDevices int) *discoveryFanoutLimiter {
	if maxDevices <= 0 {
		maxDevices = defaultMaxEnrolledDevices
	}
	return &discoveryFanoutLimiter{
		budgets:    make(map[string]discoveryPublishBudget),
		maxDevices: maxDevices,
	}
}

func (limiter *discoveryFanoutLimiter) allow(deviceID string, now time.Time) bool {
	if limiter == nil || deviceID == "" {
		return false
	}
	limiter.mutex.Lock()
	defer limiter.mutex.Unlock()
	budget, exists := limiter.budgets[deviceID]
	if !exists {
		limiter.pruneLocked(now)
		if len(limiter.budgets) >= limiter.maxDevices {
			return false
		}
		budget = discoveryPublishBudget{tokens: discoveryPublishBurst, updatedAt: now}
	}
	if elapsed := now.Sub(budget.updatedAt); elapsed > 0 {
		budget.tokens += float64(elapsed) / float64(discoveryPublishRefill)
		if budget.tokens > discoveryPublishBurst {
			budget.tokens = discoveryPublishBurst
		}
		budget.updatedAt = now
	}
	budget.lastUsed = now
	if budget.tokens < 1 {
		limiter.budgets[deviceID] = budget
		return false
	}
	budget.tokens--
	limiter.budgets[deviceID] = budget
	return true
}

// forget releases admission state only after the durable enrollment has been
// removed. Connection replacement and same-key re-enrollment deliberately do
// not call this method: their device-scoped budget must survive reconnects.
func (limiter *discoveryFanoutLimiter) forget(deviceID string) {
	if limiter == nil || deviceID == "" {
		return
	}
	limiter.mutex.Lock()
	delete(limiter.budgets, deviceID)
	limiter.mutex.Unlock()
}

func (limiter *discoveryFanoutLimiter) pruneLocked(now time.Time) {
	for deviceID, budget := range limiter.budgets {
		if now.Sub(budget.lastUsed) >= discoveryBudgetRetention {
			delete(limiter.budgets, deviceID)
		}
	}
}

func (h *hub) allowDiscoveryPublish(deviceID string, now time.Time) bool {
	h.mutex.Lock()
	limiter := h.discoveryLimiter
	if limiter == nil {
		limiter = newDiscoveryFanoutLimiter(h.maxDiscoveryDevices)
		h.discoveryLimiter = limiter
	}
	h.mutex.Unlock()
	return limiter.allow(deviceID, now)
}

func (h *hub) forgetDiscoveryPublish(deviceID string) {
	h.mutex.Lock()
	limiter := h.discoveryLimiter
	h.mutex.Unlock()
	limiter.forget(deviceID)
}

// broadcastPeerEvent 向本实例其余 /v2/control peer 广播一个推送发现事件（经
// broadcastPeerHintV2 转成 protobuf hint），并 Publish 跨实例事件，让其它实例在
// handleRelayEvent 里做同样的本地广播。d 是该设备的 discovery 快照：online/updated
// 事件用它构造 PeerAvailableHint 的 runtime_epoch/revision；offline 事件传零值
// Discovery，走 PeerUnavailableHint。
func (h *hub) broadcastPeerEvent(frameType, deviceID string, d Discovery) {
	eventType := ""
	switch frameType {
	case framePeerOnline:
		eventType = eventPeerOnline
	case framePeerUpdated:
		eventType = eventPeerUpdated
	case framePeerOffline:
		eventType = eventPeerOffline
	}
	h.broadcastPeerHintV2(frameType, deviceID, d)
	if eventType != "" && h.presence != nil {
		// InstanceID 标记发布方，订阅侧据此跳过同实例回环（发布方已本地广播过）。
		// Publish 加 presenceLeaseTimeout 限时：本方法从设备 read goroutine 调用
		//（publishDiscoveryV2 / disconnect 路径），Redis 卡顿时不能无限阻塞帧转发。
		pctx, pcancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
		_ = h.presence.Publish(pctx, RelayEvent{
			Type:       eventType,
			DeviceID:   deviceID,
			InstanceID: h.instanceID,
			Time:       time.Now().UnixMilli(),
		})
		pcancel()
	}
}

// broadcastPeerHintV2 向所有 /v2/control peer（除事件归属设备外）推送一条 advisory
// 的 protobuf presence 提示帧（设计 §23）：online/updated 走 PeerAvailableHint 携带
// runtime_epoch/revision，offline 走 PeerUnavailableHint。hint 是 best-effort 的——
// 编码失败或对端积压时静默丢弃，不影响任何生命周期。
func (h *hub) broadcastPeerHintV2(frameType, deviceID string, d Discovery) {
	var hint *v2.RelayFrame
	switch frameType {
	case framePeerOnline, framePeerUpdated:
		if d.ready() && d.hasRuntimeEpoch() {
			hint = &v2.RelayFrame{
				Version: v2.RELAY_V2_VERSION,
				Kind: &v2.RelayFrame_PeerAvailableHint{PeerAvailableHint: &v2.PeerAvailableHint{
					DeviceId:     deviceID,
					RuntimeEpoch: &v2.RuntimeEpoch{High: d.RuntimeEpochHigh, Low: d.RuntimeEpochLow},
					Revision:     d.Revision,
				}},
			}
		}
	case framePeerOffline:
		hint = &v2.RelayFrame{
			Version: v2.RELAY_V2_VERSION,
			Kind: &v2.RelayFrame_PeerUnavailableHint{PeerUnavailableHint: &v2.PeerUnavailableHint{
				DeviceId: deviceID,
				Reason:   "offline",
			}},
		}
	}
	if hint != nil {
		h.broadcastV2(deviceID, hint)
	}
}

// sendPresenceHintSnapshotV2 sends a complete advisory presence view to a new
// control connection.  The shared ListOnlinePeers query is deliberately the
// same authority used by Resolve: presence and discovery ownership must agree,
// discovery must have a non-zero revision, and a real runtime epoch must be
// present before a peer is advertised as usable.  Backend errors produce no
// synthetic online entries; the client can retry Resolve and wait for the next
// edge-triggered hint.
func (h *hub) sendPresenceHintSnapshotV2(recipient *peer) {
	if recipient == nil || h.presence == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	online, err := h.presence.ListOnlinePeers(ctx)
	cancel()
	if err != nil {
		return
	}
	deviceIDs := make([]string, 0, len(online))
	for deviceID := range online {
		deviceIDs = append(deviceIDs, deviceID)
	}
	sort.Strings(deviceIDs)
	hints := make([]*v2.PeerPresenceHint, 0, len(deviceIDs))
	for _, deviceID := range deviceIDs {
		if deviceID == recipient.deviceID {
			continue
		}
		d := online[deviceID]
		if !d.ready() || !d.hasRuntimeEpoch() {
			continue
		}
		hints = append(hints, &v2.PeerPresenceHint{
			DeviceId:     deviceID,
			Online:       true,
			RuntimeEpoch: &v2.RuntimeEpoch{High: d.RuntimeEpochHigh, Low: d.RuntimeEpochLow},
			Revision:     d.Revision,
		})
	}
	h.sendV2Frame(recipient, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_PresenceHintSnapshot{PresenceHintSnapshot: &v2.PresenceHintSnapshot{
			Peers:         hints,
			PublishedAtMs: time.Now().UnixMilli(),
		}},
	})
}

// sameDiscoveryContent 比较两份 discovery 快照的候选与能力集合是否一致（无序）。
// 同 revision（同 epoch 内）必须对应同一份快照：集合比较允许候选顺序变化，但成员
// 不能增删改。
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
