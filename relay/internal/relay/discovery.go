// Discovery 是跨实例共享的设备发现状态：其他设备如何连接该设备。
//
// 与 Presence（是否在线）分离：Discovery 只回答"如何连接"。两者生命周期绑定——
// TTL 相同（presence TTL）、心跳同时续期、断开同时释放，保证离线设备的 Discovery
// 不会残留为可连接状态。
//
// ADR-017 修订边界：relay 存储 Discovery（device_id + runtime_epoch + revision +
// opaque candidates）供 resolve 返回，但转发 candidate_offer/answer 等信令帧时仍不
// 解析 payload（存储与转发分离）。Candidates 以不透明形式存储，relay 不解释其
// endpoint、transport 或优先级语义。

package relay

import "time"

// Discovery 描述一台设备的发现信息。Candidates 是不透明字符串列表（base64 编码的
// CandidateAdvertisement），relay 不解析其内容（ADR-017 边界）。
//
// ConnectionID 是该 discovery 的所有权标识：与 presence 租约同构，Release（断开）
// 时必须携带它做 CAS，防止旧连接的延迟清理误删新连接已上传的 discovery。
//
// 排序模型是冻结契约（relay_v2.proto DiscoverySnapshot）的权威模型：
// RuntimeEpochHigh/Low（128 位 runtime_epoch）+ Revision。revision 只在同一
// runtime_epoch 内有意义，跨 epoch 不可比较（明确版 §7）。READY 判定（ready()）
// 要求 revision>0，即 discovery 已可靠发布。
type Discovery struct {
	DeviceID         string    `json:"device_id"`
	ConnectionID     string    `json:"connection_id,omitempty"`
	RuntimeEpochHigh uint64    `json:"runtime_epoch_high,omitempty"`
	RuntimeEpochLow  uint64    `json:"runtime_epoch_low,omitempty"`
	Revision         uint32    `json:"revision,omitempty"`
	Capabilities     []string  `json:"capabilities,omitempty"`
	Candidates       []string  `json:"candidates,omitempty"`
	UpdatedAt        time.Time `json:"updated_at"`
}

// discoveryEntry 是内存实现的发现条目，带显式过期时间（内存模式无 Redis TTL）。
type discoveryEntry struct {
	discovery Discovery
	expiresAt time.Time
}

// discovery 上传的边界约束，与设备端 network-nat/exchange.rs 的对等限制一致：
// candidates≤64 条 ×4096B、capabilities≤64 条 ×256B。服务端同样限制，防止单台
// 设备的上报撑爆后续 resolve 响应，使查询客户端超限断连。
const (
	maxDiscoveryCandidates      = 64
	maxDiscoveryCandidateBytes  = 4096
	maxDiscoveryCapabilities    = 64
	maxDiscoveryCapabilityBytes = 256
)

// ready 报告该 discovery 是否满足 READY 判定（明确版 §10）：已可靠发布的真实
// revision（>0）。v2 发布直接携带 revision；revision>0 即「Discovery 已可靠发布」。
func (d Discovery) ready() bool { return d.Revision > 0 }

// hasRuntimeEpoch reports whether the discovery carries a real non-zero
// runtime identity.  A zero epoch is not a valid v2 snapshot and must not make
// an otherwise online presence READY.
func (d Discovery) hasRuntimeEpoch() bool {
	return d.RuntimeEpochHigh != 0 || d.RuntimeEpochLow != 0
}

// sameEpoch 报告两份 discovery 是否属于同一 v2 runtime_epoch（128 位 high/low）。
func (d Discovery) sameEpoch(o Discovery) bool {
	return d.RuntimeEpochHigh == o.RuntimeEpochHigh && d.RuntimeEpochLow == o.RuntimeEpochLow
}
