// Authoritative 4-state peer resolve and the v2 reliable-discovery-publish
// primitive (design §9 / §10).
//
// resolvePeer is the single authoritative entry for "is this peer reachable":
// it never fail-opens to the local hub peer table, and it never reports
// online=true from a presence read alone. The v1 lookup_response handler derives
// its online *bool from this resolve so the v1 wire keeps its shape while the
// underlying semantics are already the v2 four-state model.
//
// publishDiscoveryV2 is the server-side reliable-publish primitive that Step 7's
// /v2/control DiscoveryPublish handler will call; it performs the presence-owner
// CAS write and returns the DiscoveryAck payload (runtime_epoch + committed
// revision) that the client needs to flip its local DiscoveryState to PUBLISHED.

package relay

import (
	"context"
	"encoding/base64"
	"errors"
	"strconv"
	"time"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

// errDiscoveryRevisionStale reports that a v2 DiscoveryPublish carried a revision
// not greater than the currently stored revision within the same runtime_epoch.
// It maps to the frozen ErrorCode ERROR_CODE_REVISION_STALE.
var errDiscoveryRevisionStale = errors.New("discovery publish rejected: revision is not greater than the current revision within the same runtime_epoch")

// errDiscoveryRevisionImmutable reports that a v2 DiscoveryPublish carried the
// same revision as the currently stored snapshot but different content. Within a
// single runtime_epoch a revision uniquely identifies one snapshot, so content
// may only change with a higher revision. It maps to ErrorCode
// ERROR_CODE_REVISION_STALE.
var errDiscoveryRevisionImmutable = errors.New("discovery publish rejected: same revision must carry identical content (immutable within epoch)")

// errDiscoveryNoRevision reports that a v2 DiscoveryPublish carried revision 0.
// revision is mandatory (>= 1) in the frozen contract.
var errDiscoveryNoRevision = errors.New("discovery publish rejected: revision must be >= 1")

// resolveResult is the authoritative 4-state peer resolve (design §10).
type resolveResult struct {
	status    v2.ResolveStatus
	discovery Discovery
}

// resolvePeer 是 peer 可连性的唯一权威判定（明确版 §10），绝不 fail-open：
//
//	READY    = presence 与 discovery 均有效、owner(control_connection_id) 一致、
//	           discovery 已可靠发布（revision>0）。
//	NOT_READY = presence 在线但 discovery 尚未可靠发布（缺失 / revision=0 / owner
//	           mismatch 的残留）。
//	UNKNOWN  = Redis/后端读取失败，状态无法可靠判定（绝不当 online=true 伪装成功）。
//	OFFLINE  = presence 确定不存在。
//
// 返回的 discovery 只在 READY 时携带（调用方据此回显 v1 的 generation/candidates/
// capabilities）。
func (h *hub) resolvePeer(ctx context.Context, targetID string) resolveResult {
	if h.presence == nil {
		// 无共享状态层：没有 presence 租约可判定，权威判离线。
		return resolveResult{status: v2.ResolveStatus_RESOLVE_STATUS_OFFLINE}
	}
	presence, presenceOK, presenceErr := h.presence.GetPresence(ctx, targetID)
	if presenceErr != nil {
		// 后端读取故障：状态未知，NOT fail-open online。
		return resolveResult{status: v2.ResolveStatus_RESOLVE_STATUS_UNKNOWN}
	}
	if !presenceOK {
		// presence 确定不存在 → OFFLINE。
		return resolveResult{status: v2.ResolveStatus_RESOLVE_STATUS_OFFLINE}
	}
	found, discOK, discErr := h.presence.GetDiscovery(ctx, targetID)
	if discErr != nil {
		return resolveResult{status: v2.ResolveStatus_RESOLVE_STATUS_UNKNOWN}
	}
	if !discOK || !found.ready() || presence.ConnectionID != found.ConnectionID {
		// presence 在线但 discovery 未可靠发布（缺失 / revision=0 / owner 不一致残留）。
		return resolveResult{status: v2.ResolveStatus_RESOLVE_STATUS_NOT_READY}
	}
	return resolveResult{status: v2.ResolveStatus_RESOLVE_STATUS_READY, discovery: found}
}

// discoveryFromV2 converts a frozen v2 DiscoverySnapshot into the shared storage
// Discovery. Candidate blobs are opaque bytes and are stored base64-encoded so
// they round-trip through the existing []string v1 storage shape; transport
// capabilities are stored as their numeric string so the v2 resolve path can
// parse them back into the enum. Generation is derived from revision for the v1
// wire (normalizeDiscovery fills the inverse direction at write time).
func discoveryFromV2(deviceID string, snapshot *v2.DiscoverySnapshot) Discovery {
	d := Discovery{
		DeviceID:         deviceID,
		Generation:       uint64(snapshot.Revision),
		RuntimeEpochHigh: snapshot.GetRuntimeEpoch().GetHigh(),
		RuntimeEpochLow:  snapshot.GetRuntimeEpoch().GetLow(),
		Revision:         snapshot.Revision,
		UpdatedAt:        time.Now(),
	}
	for _, capability := range snapshot.TransportCapabilities {
		d.Capabilities = append(d.Capabilities, strconv.FormatInt(int64(capability), 10))
	}
	if bundle := snapshot.CandidateBundle; bundle != nil {
		for _, candidate := range bundle.Candidates {
			d.Candidates = append(d.Candidates, base64.StdEncoding.EncodeToString(candidate))
		}
	}
	// 若客户端未携带 epoch（协议违规，但保持原语健壮），服务端派生一个，避免
	// 零 epoch 被 READY 判据错误接受。
	if d.RuntimeEpochHigh == 0 && d.RuntimeEpochLow == 0 {
		d.RuntimeEpochHigh, d.RuntimeEpochLow = newRuntimeEpoch()
	}
	return d
}

// publishDiscoveryV2 是 v2 DiscoveryPublish 路径的服务端可靠发布原语：把冻结的
// DiscoverySnapshot 转成存储模型、执行 presence-owner CAS 写入、按 v2 规则校验
// revision 单调性、广播 peer_online/peer_updated，并返回 DiscoveryAck（回显
// request_id、携带 runtime_epoch + 提交的 revision）。Step 7 的 /v2/control
// handler 将调用本方法并把返回的 ack 发回发布客户端（只有收到 ack，客户端才把
// DiscoveryState 置为 PUBLISHED，明确版 §9）。本方法不向发布客户端写任何 v1 JSON 帧。
func (h *hub) publishDiscoveryV2(requestID uint64, deviceID, connID string, snapshot *v2.DiscoverySnapshot) (*v2.DiscoveryAck, error) {
	if h.presence == nil {
		return nil, errDiscoveryNotOwner
	}
	if snapshot == nil || snapshot.Revision == 0 {
		return nil, errDiscoveryNoRevision
	}
	d := discoveryFromV2(deviceID, snapshot)

	ctx, cancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	defer cancel()
	presence, presenceOK, presenceErr := h.presence.GetPresence(ctx, deviceID)
	if presenceErr != nil {
		return nil, presenceErr
	}
	if !presenceOK {
		// presence 已失效（僵尸连接）：不刷新 discovery TTL，拒绝写入。
		return nil, errDiscoveryNotOwner
	}
	old, hadOld, getErr := h.presence.GetDiscovery(ctx, deviceID)
	if getErr != nil {
		return nil, getErr
	}
	if hadOld && old.sameEpoch(d) {
		// 同 runtime_epoch：revision 必须严格递增，且同 revision 内容不可变
		// （明确版 §7「同 generation/同 revision 永远对应同一份快照」）。
		if snapshot.Revision < old.Revision {
			return nil, errDiscoveryRevisionStale
		}
		if snapshot.Revision == old.Revision && !sameDiscoveryContent(old, d) {
			return nil, errDiscoveryRevisionImmutable
		}
	}
	// 跨 epoch 的 revision 不可比较（明确版 §7），直接接受任意 >=1 的 revision。
	wasOnline := presenceOK && hadOld && old.ready() && presence.ConnectionID == old.ConnectionID
	if err := h.presence.TakeDiscovery(ctx, deviceID, connID, d, h.presenceTTL); err != nil {
		return nil, err
	}
	frameType := ""
	if !wasOnline {
		frameType = framePeerOnline
	} else if old.Revision != d.Revision {
		frameType = framePeerUpdated
	}
	if frameType != "" {
		// 广播推送发现事件给其它（v1/v2）peer 与跨实例事件总线；发布客户端自身由
		// Step 7 的 /v2/control handler 以 v2 帧（DiscoveryAck / PresenceHint）通知。
		h.broadcastPeerEvent(frameType, deviceID, d.Generation)
	}
	return &v2.DiscoveryAck{
		RequestId:    requestID,
		RuntimeEpoch: &v2.RuntimeEpoch{High: d.RuntimeEpochHigh, Low: d.RuntimeEpochLow},
		Revision:     d.Revision,
	}, nil
}
