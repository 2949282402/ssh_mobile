// v2 推送发现辅助：broadcastPeerEvent 聚合 v2 hint 广播与跨实例事件发布，
// broadcastPeerHintV2 把 presence 事件转成 protobuf advisory hint。v1 JSON 控制面
// 已随传输网络 v1 一并删除，本文件只保留 v2 控制面的广播原语。

package relay

import (
	"context"
	"time"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

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
		if d.ready() {
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
