// Discovery 是跨实例共享的设备发现状态：其他设备如何连接该设备。
//
// 与 Presence（是否在线）分离：Discovery 只回答"如何连接"。两者生命周期绑定——
// TTL 相同（presence TTL）、心跳同时续期、断开同时释放，保证离线设备的 Discovery
// 不会残留为可连接状态。
//
// ADR-017 修订边界：relay 存储 Discovery（device_id + generation + opaque
// candidates）供 lookup 返回，但转发 candidate_offer/answer 等信令帧时仍不解析
// payload（存储与转发分离）。Candidates 以不透明形式存储，relay 不解释其 endpoint、
// transport 或优先级语义。

package relay

import (
	"encoding/binary"
	"time"
)

// Discovery 描述一台设备的发现信息。Candidates 是不透明字符串列表（JSON 序列化的
// CandidateAdvertisement），relay 不解析其内容（ADR-017 边界）。
//
// ConnectionID 是该 discovery 的所有权标识：与 presence 租约同构，Release（断开）
// 时必须携带它做 CAS，防止旧连接的延迟清理误删新连接已上传的 discovery。
//
// 存储模型同时携带 v1 与 v2 两个版本的排序字段（Step 3 加法迁移）：
//   - Generation（uint64）是 v1 线上的派生字段：v1 discovery_update 携带 generation，
//     presence_snapshot / peer_* / lookup_response 都回显它；v2 发布时由 revision 派生。
//   - RuntimeEpochHigh/Low + Revision 是 v2 契约（relay_v2.proto DiscoverySnapshot）的
//     权威排序模型：revision 只在同一 runtime_epoch 内有意义，跨 epoch 不可比较
//     （明确版 §7）。v1 上传时由服务端为每条连接派生 epoch、把 generation 变化映射为
//     严格递增的 revision。存储层写入时用 normalizeDiscovery 补齐缺失的一侧。
type Discovery struct {
	DeviceID         string    `json:"device_id"`
	ConnectionID     string    `json:"connection_id,omitempty"`
	Generation       uint64    `json:"generation"`
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
// candidates≤64 条 ×2048B、capabilities≤64 条 ×256B。服务端同样限制，防止单台
// 设备的上报撑爆后续 lookup_response / presence_snapshot，使查询客户端超限断连。
const (
	maxDiscoveryCandidates      = 64
	maxDiscoveryCandidateBytes  = 2048
	maxDiscoveryCapabilities    = 64
	maxDiscoveryCapabilityBytes = 256
)

// ready 报告该 discovery 是否满足 READY 判定（明确版 §10）：已可靠发布的真实
// revision（>0）。v1 上传在存储层由 generation 派生 revision；v2 发布直接携带
// revision，存储层再派生 generation 供 v1 线回显。两者统一以 revision>0 作为
// 「Discovery 已可靠发布」的判据。
func (d Discovery) ready() bool { return d.Revision > 0 }

// sameEpoch 报告两份 discovery 是否属于同一 v2 runtime_epoch（128 位 high/low）。
func (d Discovery) sameEpoch(o Discovery) bool {
	return d.RuntimeEpochHigh == o.RuntimeEpochHigh && d.RuntimeEpochLow == o.RuntimeEpochLow
}

// newRuntimeEpoch 生成一个新的 128 位随机 runtime epoch（big-endian high/low，
// 与 relay_v2.proto RuntimeEpoch 的固定表示一致）。v1 上传没有线字段携带它，服务端
// 为每条新连接（新 owner）派生一个 epoch，保证同连接内的 revision 有可比基准。
func newRuntimeEpoch() (high, low uint64) {
	b := randomBytes(16)
	return binary.BigEndian.Uint64(b[:8]), binary.BigEndian.Uint64(b[8:])
}

// deriveRevisionFromGeneration 把 v1 线的 uint64 generation 映射到 v2 的 revision
// 排序字段。该映射对 v1 客户端无语义（v1 线仍回显存储的 generation），只保证：
// generation>0 时 revision 也为正（READY 判据），且 v1 上传在同 epoch 内得到一个
// 可比较的排序值。generation 恰为 2^32 的非零倍数时 uint32 截断为 0，兜底为 1。
func deriveRevisionFromGeneration(generation uint64) uint32 {
	if generation == 0 {
		return 0
	}
	revision := uint32(generation)
	if revision == 0 {
		return 1
	}
	return revision
}

// normalizeDiscovery 补齐存储行的排序字段：只带 generation（v1 上传 / 手工写入）时
// 由它派生 revision；只带 revision（v2 发布）时派生 generation 供 v1 线回显。两者都
// 带则不动。memory 与 Redis 的 TakeDiscovery 在落盘前统一调用，保证任何写入路径产
// 出的行都同时满足 v1 线（generation）与 v2 模型（revision>0 的 READY 判据）。
func normalizeDiscovery(d *Discovery) {
	if d.Revision == 0 && d.Generation > 0 {
		d.Revision = deriveRevisionFromGeneration(d.Generation)
	}
	if d.Generation == 0 && d.Revision > 0 {
		d.Generation = uint64(d.Revision)
	}
}
