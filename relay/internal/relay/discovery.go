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

import "time"

// Discovery 描述一台设备的发现信息。Candidates 是不透明字符串列表（JSON 序列化的
// CandidateAdvertisement），relay 不解析其内容（ADR-017 边界）。
//
// ConnectionID 是该 discovery 的所有权标识：与 presence 租约同构，Release（断开）
// 时必须携带它做 CAS，防止旧连接的延迟清理误删新连接已上传的 discovery。
type Discovery struct {
	DeviceID     string    `json:"device_id"`
	ConnectionID string    `json:"connection_id,omitempty"`
	Generation   uint64    `json:"generation"`
	Capabilities []string  `json:"capabilities,omitempty"`
	Candidates   []string  `json:"candidates,omitempty"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// discoveryEntry 是内存实现的发现条目，带显式过期时间（内存模式无 Redis TTL）。
type discoveryEntry struct {
	discovery Discovery
	expiresAt time.Time
}
