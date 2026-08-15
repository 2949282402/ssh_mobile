// 推送发现控制面测试：lookup 租约判定、broadcast 排除语义、discovery_update
// 处理、presence sweeper、GET /v1/peers 与跨实例事件广播。

package relay

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

// readOutbound 从 peer.outbound 读一帧，超时则测试失败。
func readOutbound(t *testing.T, p *peer) outboundFrame {
	t.Helper()
	select {
	case f := <-p.outbound:
		return f
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for outbound frame on %s", p.deviceID)
		return outboundFrame{}
	}
}

// readControlFrame 读取一帧并解析为 controlFrame。
func readControlFrame(t *testing.T, p *peer) controlFrame {
	t.Helper()
	f := readOutbound(t, p)
	var cf controlFrame
	if err := json.Unmarshal(f.data, &cf); err != nil {
		t.Fatalf("invalid control frame from %s: %v", p.deviceID, err)
	}
	return cf
}

// assertNoOutbound 断言 peer 的 outbound 在短窗口内没有新帧。
func assertNoOutbound(t *testing.T, p *peer) {
	t.Helper()
	select {
	case f := <-p.outbound:
		t.Fatalf("unexpected outbound frame on %s: %+v", p.deviceID, f)
	case <-time.After(50 * time.Millisecond):
	}
}

// TestLookupLeaseBasedOnline 固定 lookup 的租约判定：presence+discovery 均有效才
// online（明确版 §13），仅 presence 或仅 discovery 都算离线；在线时返回候选。
func TestLookupLeaseBasedOnline(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()
	caller := injectPeer(server.hub, "caller")

	if _, _, err := server.cache.TakePresence(ctx, "device-a", "conn-a", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-a", "conn-a", Discovery{
		DeviceID: "device-a", Generation: 7, Capabilities: []string{"cap-a"}, Candidates: []string{"cand-a"},
	}, time.Minute); err != nil {
		t.Fatal(err)
	}
	// device-b 只有 presence（offline）；device-c 先以 owner 写 discovery 再释放 presence
	// → 只残留 discovery（offline）；device-d presence+discovery 双有效但 generation 0
	// （offline，占位/遗留 gen-0 不算在线）。
	if _, _, err := server.cache.TakePresence(ctx, "device-b", "conn-b", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if _, _, err := server.cache.TakePresence(ctx, "device-c", "conn-c", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-c", "conn-c", Discovery{DeviceID: "device-c", Generation: 3, Candidates: []string{"cand-c"}}, time.Minute); err != nil {
		t.Fatal(err)
	}
	// TakeDiscovery 的 CAS 要求 presence owner；写入成功后释放 presence 构造
	// discovery-only 的离线态。
	if released, _ := server.cache.ReleasePresence(ctx, "device-c", "conn-c"); !released {
		t.Fatal("device-c presence could not be released")
	}
	if _, _, err := server.cache.TakePresence(ctx, "device-d", "conn-d", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-d", "conn-d", Discovery{DeviceID: "device-d", Generation: 0}, time.Minute); err != nil {
		t.Fatal(err)
	}

	server.hub.lookupPeer(caller, "device-a")
	frame := readControlFrame(t, caller)
	if frame.Type != "lookup_response" || frame.TargetID != "device-a" || frame.Online == nil || !*frame.Online {
		t.Fatalf("device-a should be online: %+v", frame)
	}
	if frame.Generation != 7 || len(frame.Capabilities) != 1 || frame.Capabilities[0] != "cap-a" ||
		len(frame.Candidates) != 1 || frame.Candidates[0] != "cand-a" {
		t.Fatalf("lookup should carry generation/capabilities/candidates: %+v", frame)
	}

	server.hub.lookupPeer(caller, "device-b")
	frame = readControlFrame(t, caller)
	if frame.Type != "lookup_response" || frame.Online == nil || *frame.Online {
		t.Fatalf("device-b (presence only) should be offline: %+v", frame)
	}

	server.hub.lookupPeer(caller, "device-c")
	frame = readControlFrame(t, caller)
	if frame.Type != "lookup_response" || frame.Online == nil || *frame.Online {
		t.Fatalf("device-c (discovery only) should be offline: %+v", frame)
	}
	if len(frame.Candidates) != 0 {
		t.Fatalf("offline lookup must not return candidates: %+v", frame)
	}

	server.hub.lookupPeer(caller, "device-d")
	frame = readControlFrame(t, caller)
	if frame.Type != "lookup_response" || frame.Online == nil || *frame.Online {
		t.Fatalf("device-d (generation 0) should be offline: %+v", frame)
	}
}

// TestLookupResolveFourStates 固定 4-state resolve（明确版 §10）：READY 才
// online=true；OFFLINE/NOT_READY/UNKNOWN 都判离线；UNKNOWN 绝不当 online（移除
// 原 fail-open 回退本地表语义）。
func TestLookupResolveFourStates(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()
	caller := injectPeer(server.hub, "caller")
	// 本地表有连接但缓存不可读：UNKNOWN 必须判离线，不再 fail-open 到 h.peers。
	injectPeer(server.hub, "device-x")

	if _, _, err := server.cache.TakePresence(ctx, "device-a", "conn-a", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-a", "conn-a", Discovery{
		DeviceID: "device-a", Generation: 7, Capabilities: []string{"cap-a"}, Candidates: []string{"cand-a"},
	}, time.Minute); err != nil {
		t.Fatal(err)
	}
	// 缓存故障：任何 GetPresence/GetDiscovery 都返回错误 → UNKNOWN → offline。
	server.hub.presence = erroringCache{}

	server.hub.lookupPeer(caller, "device-x")
	frame := readControlFrame(t, caller)
	if frame.Online == nil || *frame.Online {
		t.Fatalf("cache failure must resolve UNKNOWN (offline), not fail open: %+v", frame)
	}

	// 恢复可读缓存后：READY 的设备应在线。
	server.hub.presence = server.cache
	server.hub.lookupPeer(caller, "device-a")
	frame = readControlFrame(t, caller)
	if frame.Online == nil || !*frame.Online || frame.Generation != 7 {
		t.Fatalf("READY device should be online with generation: %+v", frame)
	}
}

// TestResolvePeerStatusMatrix 固定 resolvePeer 的四种状态判定。
func TestResolvePeerStatusMatrix(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	// device-a：READY（presence+discovery 有效、owner 一致、revision>0）。
	if _, _, err := server.cache.TakePresence(ctx, "device-a", "conn-a", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-a", "conn-a", Discovery{DeviceID: "device-a", Generation: 3}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if got := server.hub.resolvePeer(ctx, "device-a"); got.status != v2.ResolveStatus_RESOLVE_STATUS_READY {
		t.Fatalf("device-a should be READY, got %v", got.status)
	}

	// device-b：无 presence → OFFLINE。
	if got := server.hub.resolvePeer(ctx, "device-b"); got.status != v2.ResolveStatus_RESOLVE_STATUS_OFFLINE {
		t.Fatalf("device-b should be OFFLINE, got %v", got.status)
	}

	// device-c：presence 在线但无 discovery → NOT_READY。
	if _, _, err := server.cache.TakePresence(ctx, "device-c", "conn-c", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if got := server.hub.resolvePeer(ctx, "device-c"); got.status != v2.ResolveStatus_RESOLVE_STATUS_NOT_READY {
		t.Fatalf("device-c (presence only) should be NOT_READY, got %v", got.status)
	}

	// device-d：presence+discovery 双有效但 owner 不一致（重连窗口旧连接残留）→ NOT_READY。
	// 先以 conn-d1 为 presence owner 写 discovery，再让 conn-d2 接管 presence。
	if _, _, err := server.cache.TakePresence(ctx, "device-d", "conn-d1", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-d", "conn-d1", Discovery{DeviceID: "device-d", Generation: 5}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if _, _, err := server.cache.TakePresence(ctx, "device-d", "conn-d2", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if got := server.hub.resolvePeer(ctx, "device-d"); got.status != v2.ResolveStatus_RESOLVE_STATUS_NOT_READY {
		t.Fatalf("device-d (owner mismatch) should be NOT_READY, got %v", got.status)
	}

	// device-e：缓存读取故障 → UNKNOWN（绝不当 online）。
	server.hub.presence = erroringCache{}
	if got := server.hub.resolvePeer(ctx, "device-e"); got.status != v2.ResolveStatus_RESOLVE_STATUS_UNKNOWN {
		t.Fatalf("cache failure should be UNKNOWN, got %v", got.status)
	}
	server.hub.presence = server.cache
}

// TestHubBroadcastExcludesExcept 固定 broadcast 的「锁内快照、锁外 enqueue」语义：
// except 设备不收帧，其余 peer 都收到。
func TestHubBroadcastExcludesExcept(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	a := injectPeer(server.hub, "device-a")
	b := injectPeer(server.hub, "device-b")
	c := injectPeer(server.hub, "device-c")

	frame, _ := json.Marshal(controlFrame{Type: framePeerOnline, DeviceID: "device-a", Generation: 1})
	server.hub.broadcast("device-a", outboundFrame{websocket.TextMessage, frame})

	for _, p := range []*peer{b, c} {
		got := readControlFrame(t, p)
		if got.Type != framePeerOnline || got.DeviceID != "device-a" || got.Generation != 1 {
			t.Fatalf("peer %s received wrong broadcast: %+v", p.deviceID, got)
		}
	}
	// except 设备不应收到。
	select {
	case f := <-a.outbound:
		t.Fatalf("except device device-a received broadcast: %+v", f)
	default:
	}
}

// TestPresenceSweeperClosesZombies 固定 sweeper 判活：presence+discovery 均有效的
// 本地 peer 保留；租约缺失/不完整的视为僵尸关闭并广播 peer_offline。
func TestPresenceSweeperClosesZombies(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	healthy := injectPeer(server.hub, "device-a")
	if _, _, err := server.cache.TakePresence(ctx, "device-a", healthy.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-a", healthy.connectionID, Discovery{DeviceID: "device-a", Generation: 1}, time.Minute); err != nil {
		t.Fatal(err)
	}
	// device-b：本地表有 peer 但无任何租约 → 僵尸。
	noLease := injectPeer(server.hub, "device-b")
	// device-c：本地表有 peer 且 presence 有效，但 discovery 缺失。presence 才是在线
	// 权威（§3）；discovery 可能被 Redis 逐出而与在线 presence 不同步，误判为僵尸会把
	// 在线设备踢下线，因此 presence 有效即不 sweeping。
	presenceOnly := injectPeer(server.hub, "device-c")
	if _, _, err := server.cache.TakePresence(ctx, "device-c", presenceOnly.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}

	server.sweepPresenceOnce()

	server.hub.mutex.Lock()
	_, aPresent := server.hub.peers["device-a"]
	_, bPresent := server.hub.peers["device-b"]
	_, cPresent := server.hub.peers["device-c"]
	server.hub.mutex.Unlock()
	if !aPresent {
		t.Fatal("healthy peer was swept")
	}
	if bPresent {
		t.Fatal("peer without any lease was not swept")
	}
	if !cPresent {
		t.Fatal("peer with valid presence but no discovery was swept as zombie")
	}
	for _, zombie := range []*peer{noLease} {
		select {
		case <-zombie.done:
		default:
			t.Fatalf("zombie peer %s was not closed", zombie.deviceID)
		}
	}
	select {
	case <-presenceOnly.done:
		t.Fatal("presence-only peer was closed as a zombie")
	default:
	}
	// 仅 device-b 被 sweeping：其 peer_offline 广播只发一次。
	frame := readControlFrame(t, healthy)
	if frame.Type != framePeerOffline || frame.DeviceID != "device-b" {
		t.Fatalf("healthy peer expected device-b peer_offline, got %+v", frame)
	}
}

// TestDiscoveryUpdatePersistsAndBroadcasts 固定 discovery_update 处理：落盘 discovery、
// 首次上报广播 peer_online + 回发 presence_snapshot、同 generation 静默、变化广播
// peer_updated。
func TestDiscoveryUpdatePersistsAndBroadcasts(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	sender := injectPeer(server.hub, "device-a")
	if _, _, err := server.cache.TakePresence(ctx, "device-a", sender.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	other := injectPeer(server.hub, "device-b")
	if _, _, err := server.cache.TakePresence(ctx, "device-b", other.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-b", other.connectionID, Discovery{DeviceID: "device-b", Generation: 1}, time.Minute); err != nil {
		t.Fatal(err)
	}

	// 首次真实上报（injectPeer 不写占位 discovery）→ peer_online 广播 + 自身拿快照。
	server.hub.handleDiscoveryUpdate(sender, controlFrame{
		Type: "discovery_update", Generation: 1,
		Capabilities: []string{"cap-1"}, Candidates: []string{"cand-1"},
	})
	d, present, err := server.cache.GetDiscovery(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("discovery not persisted: present=%v err=%v", present, err)
	}
	if d.Generation != 1 || len(d.Candidates) != 1 || d.Candidates[0] != "cand-1" || len(d.Capabilities) != 1 {
		t.Fatalf("persisted discovery mismatch: %+v", d)
	}
	if d.ConnectionID != sender.connectionID {
		t.Fatalf("discovery owner should be the sender connection: %q", d.ConnectionID)
	}
	frame := readControlFrame(t, other)
	if frame.Type != framePeerOnline || frame.DeviceID != "device-a" || frame.Generation != 1 {
		t.Fatalf("other peer expected peer_online, got %+v", frame)
	}
	snapshot := readControlFrame(t, sender)
	if snapshot.Type != framePresenceSnapshot {
		t.Fatalf("announcer expected presence_snapshot after first upload, got %+v", snapshot)
	}
	if len(snapshot.Peers) != 1 || snapshot.Peers[0].DeviceID != "device-b" {
		t.Fatalf("snapshot should list other online peers only: %+v", snapshot.Peers)
	}

	// 同 generation 刷新 → 静默，无广播。
	server.hub.handleDiscoveryUpdate(sender, controlFrame{Type: "discovery_update", Generation: 1, Candidates: []string{"cand-1"}})
	assertNoOutbound(t, other)
	assertNoOutbound(t, sender)

	// generation 变化 → peer_updated 广播。
	server.hub.handleDiscoveryUpdate(sender, controlFrame{Type: "discovery_update", Generation: 2, Candidates: []string{"cand-2"}})
	frame = readControlFrame(t, other)
	if frame.Type != framePeerUpdated || frame.DeviceID != "device-a" || frame.Generation != 2 {
		t.Fatalf("other peer expected peer_updated, got %+v", frame)
	}
}

// TestDiscoveryUpdateRejectsGenerationRegression 固定 generation 单调约束限定在同一
// Discovery owner 内：同一连接上报更小的 generation 被拒绝（不落盘、不广播），已落盘
// 的更高值保持不变。
func TestDiscoveryUpdateRejectsGenerationRegression(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	sender := injectPeer(server.hub, "device-a")
	if _, _, err := server.cache.TakePresence(ctx, "device-a", sender.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	other := injectPeer(server.hub, "device-b")
	if _, _, err := server.cache.TakePresence(ctx, "device-b", other.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}

	server.hub.handleDiscoveryUpdate(sender, controlFrame{Type: "discovery_update", Generation: 10, Candidates: []string{"cand-10"}})
	// 回退：10 → 8 必须被拒绝。
	server.hub.handleDiscoveryUpdate(sender, controlFrame{Type: "discovery_update", Generation: 8, Candidates: []string{"cand-8"}})

	d, present, err := server.cache.GetDiscovery(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("discovery missing: present=%v err=%v", present, err)
	}
	if d.Generation != 10 {
		t.Fatalf("regression must not overwrite persisted generation: got %d", d.Generation)
	}
	if len(d.Candidates) != 1 || d.Candidates[0] != "cand-10" {
		t.Fatalf("regression must not overwrite persisted candidates: %+v", d.Candidates)
	}
	// 只广播过一次（首次 gen 10 的 peer_online），回退上传不产生任何帧。
	frame := readControlFrame(t, other)
	if frame.Type != framePeerOnline || frame.DeviceID != "device-a" || frame.Generation != 10 {
		t.Fatalf("expected single peer_online for gen 10, got %+v", frame)
	}
	assertNoOutbound(t, other)
}

// TestDiscoveryUpdateAcceptsCrossOwnerGeneration 固定升级迁移：旧版本客户端（PR #44
// 随机 u64 generation，通常远大于 unix-ms）的 discovery 残留时，升级后的新连接上传
// 较小的 unix-ms generation 必须被接受（跨 owner 视为新 epoch，不做回退拒绝）——
// 否则设备会一直不可发现。
func TestDiscoveryUpdateAcceptsCrossOwnerGeneration(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	other := injectPeer(server.hub, "device-b")

	// 旧连接（PR #44 随机大 generation）拥有 presence + discovery。
	old := injectPeer(server.hub, "device-a")
	if _, _, err := server.cache.TakePresence(ctx, "device-a", old.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-a", old.connectionID, Discovery{DeviceID: "device-a", Generation: 14829384729384729384, Candidates: []string{"cand-old"}}, time.Minute); err != nil {
		t.Fatal(err)
	}
	// 升级后新连接接管 presence，上传 unix-ms 级的小 generation。
	newConn := &peer{deviceID: "device-a", connectionID: "conn-a-upgraded", outbound: make(chan outboundFrame, 8), done: make(chan struct{})}
	if _, _, err := server.cache.TakePresence(ctx, "device-a", newConn.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}

	server.hub.handleDiscoveryUpdate(newConn, controlFrame{Type: "discovery_update", Generation: 1786790000000, Candidates: []string{"cand-new"}})

	d, present, err := server.cache.GetDiscovery(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("discovery missing after cross-owner upload: present=%v err=%v", present, err)
	}
	if d.Generation != 1786790000000 || d.ConnectionID != newConn.connectionID {
		t.Fatalf("cross-owner smaller generation must be accepted: %+v", d)
	}
	// 新连接首次可发现 → peer_online 广播。
	frame := readControlFrame(t, other)
	if frame.Type != framePeerOnline || frame.DeviceID != "device-a" || frame.Generation != 1786790000000 {
		t.Fatalf("cross-owner upload should broadcast peer_online, got %+v", frame)
	}
	online, err := server.cache.ListOnlinePeers(ctx)
	if err != nil || online["device-a"].Generation != 1786790000000 {
		t.Fatalf("device-a should be online after cross-owner upload: %+v err=%v", online, err)
	}
}

// TestDiscoveryUpdateRejectsSameGenerationContentChange 固定「同 generation 的 Discovery
// 不可变」：同一 owner 用相同 generation 但不同候选/能力内容上传被拒绝（候选变化必须
// generation++）；相同内容（含顺序变化）只刷新、静默不广播。
func TestDiscoveryUpdateRejectsSameGenerationContentChange(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	sender := injectPeer(server.hub, "device-a")
	if _, _, err := server.cache.TakePresence(ctx, "device-a", sender.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	other := injectPeer(server.hub, "device-b")
	if _, _, err := server.cache.TakePresence(ctx, "device-b", other.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	// 首次 gen 5 上传 → peer_online。
	server.hub.handleDiscoveryUpdate(sender, controlFrame{
		Type: "discovery_update", Generation: 5, Candidates: []string{"cand-a"}, Capabilities: []string{"cap-1"},
	})
	if frame := readControlFrame(t, other); frame.Type != framePeerOnline || frame.Generation != 5 {
		t.Fatalf("first upload should broadcast peer_online, got %+v", frame)
	}

	// 同 generation 但内容变化 → 拒绝（不落盘、不广播）。
	server.hub.handleDiscoveryUpdate(sender, controlFrame{
		Type: "discovery_update", Generation: 5, Candidates: []string{"cand-b"}, Capabilities: []string{"cap-1"},
	})
	d, present, err := server.cache.GetDiscovery(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("discovery missing: present=%v err=%v", present, err)
	}
	if len(d.Candidates) != 1 || d.Candidates[0] != "cand-a" {
		t.Fatalf("same-generation content change must not overwrite: %+v", d.Candidates)
	}
	assertNoOutbound(t, other)

	// 同 generation 相同内容（顺序变化）→ 刷新、静默。
	server.hub.handleDiscoveryUpdate(sender, controlFrame{
		Type: "discovery_update", Generation: 5, Candidates: []string{"cand-a"}, Capabilities: []string{"cap-1"},
	})
	assertNoOutbound(t, other)
}

// TestDiscoveryUpdateRejectsStaleOwner 固定 Discovery CAS：旧连接已被新连接取代
// （presence 已易主）后，旧连接的 discovery_update 被拒绝——不覆盖新连接的 discovery，
// 且旧连接自愈关闭（与心跳路径 RenewPresence=false 一致）。这封死跨实例重连竞态。
func TestDiscoveryUpdateRejectsStaleOwner(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	old := injectPeer(server.hub, "device-a") // connectionID "conn-device-a"
	if _, _, err := server.cache.TakePresence(ctx, "device-a", old.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-a", old.connectionID, Discovery{DeviceID: "device-a", Generation: 1, Candidates: []string{"cand-1"}}, time.Minute); err != nil {
		t.Fatal(err)
	}
	// 新连接接管 presence（跨实例/重连）：presence owner 变为 conn-a-2。
	newConn := &peer{deviceID: "device-a", connectionID: "conn-a-2", outbound: make(chan outboundFrame, 8), done: make(chan struct{})}
	if _, _, err := server.cache.TakePresence(ctx, "device-a", newConn.connectionID, Presence{InstanceID: "i2"}, time.Minute); err != nil {
		t.Fatal(err)
	}

	// 旧连接尝试覆盖 discovery（即用户描述的竞态：connection.replaced 事件尚未到达时
	// 旧连接的 discovery_update）。CAS 拒绝：不落盘，旧连接被关闭。
	server.hub.handleDiscoveryUpdate(old, controlFrame{Type: "discovery_update", Generation: 2, Candidates: []string{"cand-2"}})

	d, present, err := server.cache.GetDiscovery(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("discovery missing: present=%v err=%v", present, err)
	}
	if d.Generation != 1 || d.ConnectionID != old.connectionID {
		t.Fatalf("stale owner must not overwrite discovery: %+v", d)
	}
	select {
	case <-old.done:
	default:
		t.Fatal("superseded connection should have been closed by the rejected discovery write")
	}
}

// TestDiscoveryUpdateLegacyGen0ToOnline 固定遗留 gen-0 discovery 键（占位时代/旧版本
// 残留）被真实上传覆盖后按首次可发现广播 peer_online（§8：上传 discovery 后才广播
// online）。在线判定要求 generation>0，gen-0 残留不算在线。
func TestDiscoveryUpdateLegacyGen0ToOnline(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	sender := injectPeer(server.hub, "device-a")
	if _, _, err := server.cache.TakePresence(ctx, "device-a", sender.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	// 遗留 gen-0 discovery（TakeDiscovery 仍要求 presence owner，此处满足）。
	if err := server.cache.TakeDiscovery(ctx, "device-a", sender.connectionID, Discovery{DeviceID: "device-a", Generation: 0}, time.Minute); err != nil {
		t.Fatal(err)
	}
	other := injectPeer(server.hub, "device-b")
	if _, _, err := server.cache.TakePresence(ctx, "device-b", other.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}

	server.hub.handleDiscoveryUpdate(sender, controlFrame{Type: "discovery_update", Generation: 5, Candidates: []string{"cand"}})
	frame := readControlFrame(t, other)
	if frame.Type != framePeerOnline || frame.DeviceID != "device-a" || frame.Generation != 5 {
		t.Fatalf("gen-0 leftover -> real upload should broadcast peer_online, got %+v", frame)
	}
}

// TestListPeersAuthAndContent 固定 GET /v1/peers 的认证与返回内容：无 token/坏
// token/过期 credential/吊销均 401；成功时只返回在线设备、排除调用者、按 device_id
// 排序。
func TestListPeersAuthAndContent(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
		CredentialTTL:   time.Hour,
	})
	defer server.Close()
	ctx := context.Background()

	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	if result := server.replaceEnrollment("caller", encodedKey, "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("enroll caller failed: %v", result)
	}
	for _, id := range []string{"device-a", "device-b"} {
		if result := server.replaceEnrollment(id, "key-"+id, "test", 1, time.Now()); result != enrollmentOK {
			t.Fatalf("enroll %s failed: %v", id, result)
		}
	}
	// device-a/device-b 在线（presence+discovery 均有效）；caller 也写了 presence+discovery
	// 但应被排除；device-c 只有 presence，不算在线。
	for _, id := range []string{"device-a", "device-b", "caller"} {
		if _, _, err := server.cache.TakePresence(ctx, id, "conn-"+id, Presence{InstanceID: "i1"}, time.Minute); err != nil {
			t.Fatal(err)
		}
	}
	for _, id := range []string{"device-a", "device-b", "caller"} {
		if err := server.cache.TakeDiscovery(ctx, id, "conn-"+id, Discovery{DeviceID: id, Generation: 1}, time.Minute); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := server.cache.TakePresence(ctx, "device-c", "conn-device-c", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}

	credential, err := issueCredential([]byte(mysqlTestCredentialKey), "caller", publicKey, time.Hour)
	if err != nil {
		t.Fatal(err)
	}

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	doGet := func(headerToken string) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "/v1/peers", nil)
		if headerToken != "" {
			req.Header.Set("Authorization", "Bearer "+headerToken)
		}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec
	}

	// 无 token → 401。
	if rec := doGet(""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("no token: expected 401, got %d", rec.Code)
	}
	// 坏 token → 401。
	if rec := doGet("garbage"); rec.Code != http.StatusUnauthorized {
		t.Fatalf("bad token: expected 401, got %d", rec.Code)
	}
	// 过期 credential → 401 + code 12。
	expired, err := issueCredential([]byte(mysqlTestCredentialKey), "caller", publicKey, -time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	rec := doGet(expired)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expired credential: expected 401, got %d", rec.Code)
	}
	var errResp networkErrorResponse
	if err := json.NewDecoder(rec.Body).Decode(&errResp); err != nil || errResp.Code != relayErrorCredentialExpired {
		t.Fatalf("expired credential should map to code 12: %+v (%v)", errResp, err)
	}

	// 成功：只含在线设备，排除 caller，按 device_id 排序。
	rec = doGet(credential)
	if rec.Code != http.StatusOK {
		t.Fatalf("successful list peers: expected 200, got %d", rec.Code)
	}
	var body peerListResponse
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	got := make([]string, 0, len(body.Peers))
	for _, p := range body.Peers {
		got = append(got, p.PeerID)
	}
	if strings.Join(got, ",") != "device-a,device-b" {
		t.Fatalf("list peers should be sorted online peers excluding caller: %v", got)
	}

	// 吊销 → 401（fail-closed）。
	if recorded, err := server.store.RecordRevocation(ctx, "caller", time.Now().Add(time.Hour)); err != nil || !recorded {
		t.Fatalf("record revocation failed: recorded=%v err=%v", recorded, err)
	}
	if rec := doGet(credential); rec.Code != http.StatusUnauthorized {
		t.Fatalf("revoked caller: expected 401, got %d", rec.Code)
	}
}

// TestHandleRelayEventPeerEvents 固定 handleRelayEvent 对推送发现事件的处理：其它
// 实例的事件广播到本地 peer；同实例回环事件被跳过（避免重复推送）。
func TestHandleRelayEventPeerEvents(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	other := injectPeer(server.hub, "device-b")

	server.handleRelayEvent(RelayEvent{Type: eventPeerOnline, DeviceID: "device-a", Generation: 3, InstanceID: "other-instance"})
	frame := readControlFrame(t, other)
	if frame.Type != framePeerOnline || frame.DeviceID != "device-a" || frame.Generation != 3 {
		t.Fatalf("peer_online should broadcast locally, got %+v", frame)
	}

	// 同实例回环：发布方已本地广播过，订阅侧跳过。
	server.handleRelayEvent(RelayEvent{Type: eventPeerUpdated, DeviceID: "device-a", Generation: 4, InstanceID: server.hub.instanceID})
	assertNoOutbound(t, other)

	server.handleRelayEvent(RelayEvent{Type: eventPeerOffline, DeviceID: "device-a", InstanceID: "other-instance"})
	frame = readControlFrame(t, other)
	if frame.Type != framePeerOffline || frame.DeviceID != "device-a" {
		t.Fatalf("peer_offline should broadcast locally, got %+v", frame)
	}
}

// TestMultiInstancePeerEventPropagation 验证 discovery_update 在实例 A 触发的事件经
// Redis 总线传播到实例 B，B 将其广播给本地 peer。需要 MySQL+Redis，无环境时跳过。
func TestMultiInstancePeerEventPropagation(t *testing.T) {
	mysqlDSN, redisURL := requireMySQLFullStack(t)
	ctx := context.Background()

	configA := mysqlTestConfig(mysqlDSN)
	configA.RedisURL = redisURL
	configA.InstanceID = "instance-a"
	serverA, err := OpenServer(configA)
	if err != nil {
		t.Fatalf("open instance A: %v", err)
	}
	defer serverA.Close()
	configB := mysqlTestConfig(mysqlDSN)
	configB.RedisURL = redisURL
	configB.InstanceID = "instance-b"
	serverB, err := OpenServer(configB)
	if err != nil {
		t.Fatalf("open instance B: %v", err)
	}
	defer serverB.Close()
	resetMySQLTestDB(t, mysqlDSN)

	muxA, muxB := http.NewServeMux(), http.NewServeMux()
	serverA.RegisterRoutes(muxA)
	serverB.RegisterRoutes(muxB)
	httpA := httptest.NewServer(muxA)
	defer httpA.Close()
	httpB := httptest.NewServer(muxB)
	defer httpB.Close()

	credA, _, privA := enrollViaHTTP(t, httpA.URL, "device-a", "test-token")
	connA := dialDevice(t, httpA.URL, credA, "device-a", 0x30, privA)
	defer connA.Close()
	credB, _, privB := enrollViaHTTP(t, httpB.URL, "device-b", "test-token")
	connB := dialDevice(t, httpB.URL, credB, "device-b", 0x31, privB)
	defer connB.Close()

	// 等待两个实例的 presence 租约落盘（占位 discovery 已移除，设备上传 discovery_update
	// 前不算在线）。
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		_, presentA, _ := serverA.cache.GetPresence(ctx, "device-a")
		_, presentB, _ := serverB.cache.GetPresence(ctx, "device-b")
		if presentA && presentB {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	// device-a 上传 discovery_update：A 本地广播 + Publish 跨实例事件，B 收到后广播。
	if err := connA.WriteJSON(controlFrame{Type: "discovery_update", Generation: 1, Candidates: []string{"cand-a"}}); err != nil {
		t.Fatal(err)
	}
	wait := time.Now().Add(5 * time.Second)
	for time.Now().Before(wait) {
		_ = connB.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		var frame controlFrame
		if err := connB.ReadJSON(&frame); err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				time.Sleep(50 * time.Millisecond)
				continue
			}
			t.Fatalf("read from instance B: %v", err)
		}
		if frame.Type == framePeerOnline && frame.DeviceID == "device-a" && frame.Generation == 1 {
			_ = connB.SetReadDeadline(time.Time{})
			return
		}
	}
	_ = connB.SetReadDeadline(time.Time{})
	t.Fatal("instance B peer did not receive peer_online published by instance A")
}

// TestPublishDiscoveryV2AcksAndPersists 固定 v2 可靠发布原语：publishDiscoveryV2
// 落盘 discovery、返回 DiscoveryAck（runtime_epoch + revision）、广播 peer_online，
// 且同 epoch 的 revision 严格递增、同 revision 内容不可变。
func TestPublishDiscoveryV2AcksAndPersists(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	sender := injectPeer(server.hub, "device-a")
	if _, _, err := server.cache.TakePresence(ctx, "device-a", sender.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	other := injectPeer(server.hub, "device-b")
	if _, _, err := server.cache.TakePresence(ctx, "device-b", other.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	epoch := &v2.RuntimeEpoch{High: 0x0102030405060708, Low: 0x090a0b0c0d0e0f10}
	snapshot := &v2.DiscoverySnapshot{
		RuntimeEpoch:          epoch,
		Revision:              1,
		TransportCapabilities: []v2.TransportCapability{v2.TransportCapability_TRANSPORT_CAPABILITY_WEBRTC},
		CandidateBundle:       &v2.CandidateBundle{Candidates: [][]byte{[]byte("cand-a-blob")}},
	}

	ack, err := server.hub.publishDiscoveryV2(42, "device-a", sender.connectionID, snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if ack == nil || ack.RequestId != 42 || ack.Revision != 1 || ack.RuntimeEpoch.High != epoch.High || ack.RuntimeEpoch.Low != epoch.Low {
		t.Fatalf("ack should echo request_id 42 and epoch+revision 1: %+v", ack)
	}
	d, present, err := server.cache.GetDiscovery(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("discovery not persisted: present=%v err=%v", present, err)
	}
	if d.Revision != 1 || d.Generation != 1 || d.RuntimeEpochHigh != epoch.High || d.RuntimeEpochLow != epoch.Low {
		t.Fatalf("stored discovery mismatch: %+v", d)
	}
	if len(d.Candidates) != 1 || d.Candidates[0] != "Y2FuZC1hLWJsb2I=" { // base64("cand-a-blob")
		t.Fatalf("v2 candidate should round-trip as base64: %+v", d.Candidates)
	}
	// peer_online 广播到其它 peer。
	frame := readControlFrame(t, other)
	if frame.Type != framePeerOnline || frame.DeviceID != "device-a" || frame.Generation != 1 {
		t.Fatalf("expected peer_online for v2 publish, got %+v", frame)
	}

	// 同 epoch 更高 revision → 接受，广播 peer_updated。
	ack2, err := server.hub.publishDiscoveryV2(43, "device-a", sender.connectionID, &v2.DiscoverySnapshot{
		RuntimeEpoch: epoch, Revision: 2, CandidateBundle: &v2.CandidateBundle{Candidates: [][]byte{[]byte("new-blob")}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if ack2.Revision != 2 {
		t.Fatalf("ack revision should be 2, got %d", ack2.Revision)
	}
	frame = readControlFrame(t, other)
	if frame.Type != framePeerUpdated || frame.DeviceID != "device-a" || frame.Generation != 2 {
		t.Fatalf("expected peer_updated, got %+v", frame)
	}

	// 同 epoch 更低 revision → 拒绝（revision 必须严格递增）。
	if _, err := server.hub.publishDiscoveryV2(44, "device-a", sender.connectionID, &v2.DiscoverySnapshot{
		RuntimeEpoch: epoch, Revision: 1, CandidateBundle: &v2.CandidateBundle{Candidates: [][]byte{[]byte("stale")}},
	}); !errors.Is(err, errDiscoveryRevisionStale) {
		t.Fatalf("stale revision should be rejected with errDiscoveryRevisionStale, got %v", err)
	}

	// 同 epoch 同 revision 不同内容 → 拒绝（不可变）。
	if _, err := server.hub.publishDiscoveryV2(45, "device-a", sender.connectionID, &v2.DiscoverySnapshot{
		RuntimeEpoch: epoch, Revision: 2, CandidateBundle: &v2.CandidateBundle{Candidates: [][]byte{[]byte("different")}},
	}); !errors.Is(err, errDiscoveryRevisionImmutable) {
		t.Fatalf("immutable revision content change should be rejected, got %v", err)
	}

	// 跨 epoch 的任意 revision → 接受（不可比较）。
	if _, err := server.hub.publishDiscoveryV2(46, "device-a", sender.connectionID, &v2.DiscoverySnapshot{
		RuntimeEpoch: &v2.RuntimeEpoch{High: 2, Low: 3}, Revision: 1,
		CandidateBundle: &v2.CandidateBundle{Candidates: [][]byte{[]byte("fresh")}},
	}); err != nil {
		t.Fatalf("cross-epoch publish should be accepted: %v", err)
	}
}

// TestDiscoveryUpdateStoresEpochRevision 固定 v1 discovery_update 的 epoch+revision
// 映射：新 owner 派生新 epoch、revision=1；同 owner generation 变化 revision 递增；
// 同 generation 刷新 revision 不变。
func TestDiscoveryUpdateStoresEpochRevision(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	sender := injectPeer(server.hub, "device-a")
	if _, _, err := server.cache.TakePresence(ctx, "device-a", sender.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	server.hub.handleDiscoveryUpdate(sender, controlFrame{Type: "discovery_update", Generation: 5, Candidates: []string{"cand"}})
	d, present, err := server.cache.GetDiscovery(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("discovery missing: present=%v err=%v", present, err)
	}
	if d.Generation != 5 || d.Revision != 1 {
		t.Fatalf("first upload should be gen 5 revision 1: %+v", d)
	}
	epochHigh, epochLow := d.RuntimeEpochHigh, d.RuntimeEpochLow
	if epochHigh == 0 && epochLow == 0 {
		t.Fatal("new owner should get a non-zero runtime_epoch")
	}

	// 同 owner generation 递增 → revision 递增，epoch 不变。
	server.hub.handleDiscoveryUpdate(sender, controlFrame{Type: "discovery_update", Generation: 6, Candidates: []string{"cand"}})
	d, present, err = server.cache.GetDiscovery(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("discovery missing after gen 6: present=%v err=%v", present, err)
	}
	if d.Generation != 6 || d.Revision != 2 || d.RuntimeEpochHigh != epochHigh || d.RuntimeEpochLow != epochLow {
		t.Fatalf("gen bump should increment revision within the same epoch: %+v", d)
	}

	// 同 owner 同 generation 刷新 → revision 不变。
	server.hub.handleDiscoveryUpdate(sender, controlFrame{Type: "discovery_update", Generation: 6, Candidates: []string{"cand"}})
	d, present, err = server.cache.GetDiscovery(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("discovery missing after refresh: present=%v err=%v", present, err)
	}
	if d.Revision != 2 {
		t.Fatalf("same-generation refresh should keep revision 2: %+v", d)
	}
}

// TestServerHeartbeatMonitorClosesStalePeer 固定服务端心跳租约定时器：超过
// ServerHeartbeatMisses×ServerHeartbeatInterval 未收到 heartbeat 帧的连接被关闭；
// 持续心跳的连接不受影响。客户端驱动的续期路径保持不变。
func TestServerHeartbeatMonitorClosesStalePeer(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:           []byte(mysqlTestCredentialKey),
		EnrollmentToken:         "test-token",
		ServerHeartbeatInterval: 50 * time.Millisecond,
		ServerHeartbeatMisses:   2,
	})
	defer server.Close()

	stale := injectPeer(server.hub, "device-a")
	server.hub.mutex.Lock()
	stale.lastHeartbeat = time.Now().Add(-5 * time.Second) // 已错过多个心跳周期。
	server.hub.mutex.Unlock()

	alive := injectPeer(server.hub, "device-b")
	server.hub.mutex.Lock()
	alive.lastHeartbeat = time.Now()
	server.hub.mutex.Unlock()
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		ticker := time.NewTicker(25 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				server.hub.mutex.Lock()
				alive.lastHeartbeat = time.Now()
				server.hub.mutex.Unlock()
			}
		}
	}()

	time.Sleep(200 * time.Millisecond)
	select {
	case <-stale.done:
	default:
		t.Fatal("stale peer should be closed by the server heartbeat monitor")
	}
	select {
	case <-alive.done:
		t.Fatal("heartbeating peer should not be closed by the server heartbeat monitor")
	default:
	}
}

// TestSendPresenceSnapshotEmptyAlwaysIncludesPeers 固定空快照也必须输出 "peers":[]
// （不能因 omitempty 省略成 {"type":"presence_snapshot"}）：Rust 客户端 decode_event
// 把缺失 peers 当协议错误断连，单设备中继即陷入无限重连。
func TestSendPresenceSnapshotEmptyAlwaysIncludesPeers(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	sender := injectPeer(server.hub, "device-a")
	if _, _, err := server.cache.TakePresence(ctx, "device-a", sender.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}

	server.hub.sendPresenceSnapshot(sender)
	frame := readControlFrame(t, sender)
	if frame.Type != framePresenceSnapshot {
		t.Fatalf("expected presence_snapshot, got %+v", frame)
	}
	if frame.Peers == nil {
		t.Fatal("snapshot peers must be present (non-nil) even when empty")
	}
	if len(frame.Peers) != 0 {
		t.Fatalf("snapshot should be empty, got %+v", frame.Peers)
	}
}

// TestDiscoveryReconnectStaleOwnerWindowNotOnline 固定重连窗口的在线语义：新连接
// TakePresence 接管后、尚未重新上传 discovery 前，旧连接残留的 discovery（owner 仍是
// 旧连接）不满足「presence 与 discovery owner 一致」，因此设备不算在线；新连接的真实
// 上传（owner 一致）才按首次可发现广播 peer_online。
func TestDiscoveryReconnectStaleOwnerWindowNotOnline(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	other := injectPeer(server.hub, "device-b")

	// 首次连接：presence + discovery（gen 5）均为 conn-a-1 所有 → 在线。
	first := &peer{deviceID: "device-a", connectionID: "conn-a-1", outbound: make(chan outboundFrame, 8), done: make(chan struct{})}
	if _, _, err := server.cache.TakePresence(ctx, "device-a", first.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-a", first.connectionID, Discovery{DeviceID: "device-a", Generation: 5, Candidates: []string{"cand"}, UpdatedAt: time.Now()}, time.Minute); err != nil {
		t.Fatal(err)
	}
	online, err := server.cache.ListOnlinePeers(ctx)
	if err != nil || online["device-a"].Generation != 5 {
		t.Fatalf("device-a should be online before reconnect: %+v err=%v", online, err)
	}

	// 重连：新连接接管 presence，但旧 discovery（owner conn-a-1）仍在 TTL 内。
	second := &peer{deviceID: "device-a", connectionID: "conn-a-2", outbound: make(chan outboundFrame, 8), done: make(chan struct{})}
	if _, _, err := server.cache.TakePresence(ctx, "device-a", second.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	online, err = server.cache.ListOnlinePeers(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, present := online["device-a"]; present {
		t.Fatalf("device-a must not be online in the stale-owner window: %+v", online)
	}

	// 新连接上传真实 discovery（gen 6，owner conn-a-2）→ owner 一致、非此前在线
	// （旧 discovery owner 不匹配）→ 首次可发现广播 peer_online。
	server.hub.handleDiscoveryUpdate(second, controlFrame{Type: "discovery_update", Generation: 6, Candidates: []string{"cand"}})
	d, present, err := server.cache.GetDiscovery(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("discovery after reconnect missing: present=%v err=%v", present, err)
	}
	if d.Generation != 6 || d.ConnectionID != second.connectionID {
		t.Fatalf("reconnect discovery should be gen 6 owned by conn-a-2: %+v", d)
	}
	frame := readControlFrame(t, other)
	if frame.Type != framePeerOnline || frame.DeviceID != "device-a" || frame.Generation != 6 {
		t.Fatalf("reconnect real upload should broadcast peer_online, got %+v", frame)
	}
	online, err = server.cache.ListOnlinePeers(ctx)
	if err != nil || online["device-a"].Generation != 6 {
		t.Fatalf("device-a should be online after reconnect upload: %+v err=%v", online, err)
	}
}
