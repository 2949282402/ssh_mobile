// 推送发现控制面测试（v2 模型）：权威 resolve、broadcastV2 排除语义、presence
// sweeper、跨实例事件广播、publishDiscoveryV2 的 epoch/revision 语义与 stale-owner
// 拒绝。v1 JSON 控制面已随传输网络 v1 删除，所有帧断言都走 v2 protobuf codec。

package relay

import (
	"context"
	"encoding/base64"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

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

// readV2ControlFrameFromPeer 读取一帧并解码为 v2 RelayFrame。
func readV2ControlFrameFromPeer(t *testing.T, p *peer) *v2.RelayFrame {
	t.Helper()
	f := readOutbound(t, p)
	frame, err := v2.DecodeControl(f.data)
	if err != nil {
		t.Fatalf("invalid v2 control frame from %s: %v", p.deviceID, err)
	}
	return frame
}

// readPeerAvailableHint 读取一帧并断言是 PeerAvailableHint。
func readPeerAvailableHint(t *testing.T, p *peer) *v2.PeerAvailableHint {
	t.Helper()
	frame := readV2ControlFrameFromPeer(t, p)
	hint := frame.GetPeerAvailableHint()
	if hint == nil {
		t.Fatalf("expected peer_available_hint from %s, got %s", p.deviceID, v2.KindName(frame))
	}
	return hint
}

// readPeerUnavailableHint 读取一帧并断言是 PeerUnavailableHint。
func readPeerUnavailableHint(t *testing.T, p *peer) *v2.PeerUnavailableHint {
	t.Helper()
	frame := readV2ControlFrameFromPeer(t, p)
	hint := frame.GetPeerUnavailableHint()
	if hint == nil {
		t.Fatalf("expected peer_unavailable_hint from %s, got %s", p.deviceID, v2.KindName(frame))
	}
	return hint
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

// TestResolveV2LeaseBasedOnline 固定 v2 ResolvePeerRequest 的 4-state 判定：
// READY 只在 presence+discovery 双有效、owner 一致、revision>0 时返回；
// NOT_READY（presence 在线但 discovery 未发布）、OFFLINE（presence 缺失）与
// revision=0 的残留都不得判 READY。
func TestResolveV2LeaseBasedOnline(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()
	caller := injectPeer(server.hub, "caller")

	// device-a：READY（presence+discovery 均有效、owner 一致、revision>0）。
	if _, _, err := server.cache.TakePresence(ctx, "device-a", "conn-a", Presence{InstanceID: "i1", ConnectionID: "conn-a"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-a", "conn-a", Discovery{
		DeviceID: "device-a", Revision: 7, RuntimeEpochHigh: 0x1234, RuntimeEpochLow: 0x5678,
		Capabilities: []string{"5"}, Candidates: []string{base64.StdEncoding.EncodeToString([]byte("cand-a"))},
	}, time.Minute); err != nil {
		t.Fatal(err)
	}
	// device-b：只有 presence（NOT_READY）。
	if _, _, err := server.cache.TakePresence(ctx, "device-b", "conn-b", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	// device-c：先以 owner 写 discovery 再释放 presence → 只残留 discovery（OFFLINE）。
	if _, _, err := server.cache.TakePresence(ctx, "device-c", "conn-c", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-c", "conn-c", Discovery{DeviceID: "device-c", Revision: 3, Candidates: []string{"cand-c"}}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if released, _ := server.cache.ReleasePresence(ctx, "device-c", "conn-c"); !released {
		t.Fatal("device-c presence could not be released")
	}
	// device-d：presence+discovery 双有效但 revision=0（残留）→ NOT_READY。
	if _, _, err := server.cache.TakePresence(ctx, "device-d", "conn-d", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-d", "conn-d", Discovery{DeviceID: "device-d"}, time.Minute); err != nil {
		t.Fatal(err)
	}

	server.hub.handleResolvePeerRequestV2(caller, &v2.ResolvePeerRequest{RequestId: 1, TargetDeviceId: "device-a"})
	frame := readV2ControlFrameFromPeer(t, caller)
	rs := frame.GetResolvePeerResponse()
	if rs == nil || rs.Status != v2.ResolveStatus_RESOLVE_STATUS_READY {
		t.Fatalf("device-a should be READY: %+v", frame)
	}
	if rs.Discovery == nil || rs.Discovery.Revision != 7 ||
		len(rs.Discovery.TransportCapabilities) != 1 ||
		len(rs.Discovery.CandidateBundle.Candidates) != 1 {
		t.Fatalf("READY resolve should carry device-a discovery: %+v", rs.Discovery)
	}

	server.hub.handleResolvePeerRequestV2(caller, &v2.ResolvePeerRequest{RequestId: 2, TargetDeviceId: "device-b"})
	frame = readV2ControlFrameFromPeer(t, caller)
	if rs := frame.GetResolvePeerResponse(); rs == nil || rs.Status != v2.ResolveStatus_RESOLVE_STATUS_NOT_READY {
		t.Fatalf("device-b (presence only) should be NOT_READY: %+v", frame)
	}

	server.hub.handleResolvePeerRequestV2(caller, &v2.ResolvePeerRequest{RequestId: 3, TargetDeviceId: "device-c"})
	frame = readV2ControlFrameFromPeer(t, caller)
	if rs := frame.GetResolvePeerResponse(); rs == nil || rs.Status != v2.ResolveStatus_RESOLVE_STATUS_OFFLINE {
		t.Fatalf("device-c (discovery only) should be OFFLINE: %+v", frame)
	}

	server.hub.handleResolvePeerRequestV2(caller, &v2.ResolvePeerRequest{RequestId: 4, TargetDeviceId: "device-d"})
	frame = readV2ControlFrameFromPeer(t, caller)
	if rs := frame.GetResolvePeerResponse(); rs == nil || rs.Status != v2.ResolveStatus_RESOLVE_STATUS_NOT_READY {
		t.Fatalf("device-d (revision 0) should be NOT_READY: %+v", frame)
	}
}

// TestResolveV2FourStates 固定 v2 resolve 的 4-state：READY 才携带 discovery；
// OFFLINE/NOT_READY/UNKNOWN 分别回状态；UNKNOWN 绝不当 READY（移除原 fail-open
// 回退本地表语义）。
func TestResolveV2FourStates(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()
	caller := injectPeer(server.hub, "caller")
	// 本地表有连接但缓存不可读：UNKNOWN 必须判 NOT READY，不再 fail-open 到 h.peers。
	injectPeer(server.hub, "device-x")

	if _, _, err := server.cache.TakePresence(ctx, "device-a", "conn-a", Presence{InstanceID: "i1", ConnectionID: "conn-a"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-a", "conn-a", Discovery{
		DeviceID: "device-a", ConnectionID: "conn-a", RuntimeEpochHigh: 1, RuntimeEpochLow: 1,
		Revision: 7, Capabilities: []string{"cap-a"}, Candidates: []string{"cand-a"},
	}, time.Minute); err != nil {
		t.Fatal(err)
	}
	// 缓存故障：任何 GetPresence/GetDiscovery 都返回错误 → UNKNOWN。
	server.hub.presence = erroringCache{}

	server.hub.handleResolvePeerRequestV2(caller, &v2.ResolvePeerRequest{RequestId: 1, TargetDeviceId: "device-x"})
	frame := readV2ControlFrameFromPeer(t, caller)
	if rs := frame.GetResolvePeerResponse(); rs == nil || rs.Status != v2.ResolveStatus_RESOLVE_STATUS_UNKNOWN {
		t.Fatalf("cache failure must resolve UNKNOWN, not fail open: %+v", frame)
	}

	// 恢复可读缓存后：READY 的设备应返回 READY + discovery。
	server.hub.presence = server.cache
	server.hub.handleResolvePeerRequestV2(caller, &v2.ResolvePeerRequest{RequestId: 2, TargetDeviceId: "device-a"})
	frame = readV2ControlFrameFromPeer(t, caller)
	if rs := frame.GetResolvePeerResponse(); rs == nil || rs.Status != v2.ResolveStatus_RESOLVE_STATUS_READY || rs.Discovery == nil {
		t.Fatalf("READY device should resolve READY with discovery: %+v", frame)
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
	if _, _, err := server.cache.TakePresence(ctx, "device-a", "conn-a", Presence{InstanceID: "i1", ConnectionID: "conn-a"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-a", "conn-a", Discovery{
		DeviceID: "device-a", ConnectionID: "conn-a", RuntimeEpochHigh: 1, RuntimeEpochLow: 1, Revision: 3,
	}, time.Minute); err != nil {
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
	if _, _, err := server.cache.TakePresence(ctx, "device-d", "conn-d1", Presence{InstanceID: "i1", ConnectionID: "conn-d1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-d", "conn-d1", Discovery{
		DeviceID: "device-d", ConnectionID: "conn-d1", RuntimeEpochHigh: 1, RuntimeEpochLow: 1, Revision: 5,
	}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if _, _, err := server.cache.TakePresence(ctx, "device-d", "conn-d2", Presence{InstanceID: "i1", ConnectionID: "conn-d2"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if got := server.hub.resolvePeer(ctx, "device-d"); got.status != v2.ResolveStatus_RESOLVE_STATUS_NOT_READY {
		t.Fatalf("device-d (owner mismatch) should be NOT_READY, got %v", got.status)
	}

	// device-e：缓存读取故障 → UNKNOWN（绝不当 READY）。
	server.hub.presence = erroringCache{}
	if got := server.hub.resolvePeer(ctx, "device-e"); got.status != v2.ResolveStatus_RESOLVE_STATUS_UNKNOWN {
		t.Fatalf("cache failure should be UNKNOWN, got %v", got.status)
	}
	server.hub.presence = server.cache
}

// TestHubBroadcastV2ExcludesExcept 固定 broadcastV2 的「锁内快照、锁外 enqueue」语义：
// except 设备不收帧，其余 v2 控制面 peer 都收到。
func TestHubBroadcastV2ExcludesExcept(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	a := injectPeer(server.hub, "device-a")
	b := injectPeer(server.hub, "device-b")
	c := injectPeer(server.hub, "device-c")

	server.hub.broadcastV2("device-a", &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_PeerAvailableHint{PeerAvailableHint: &v2.PeerAvailableHint{
			DeviceId: "device-a", RuntimeEpoch: &v2.RuntimeEpoch{High: 1}, Revision: 1,
		}},
	})

	for _, p := range []*peer{b, c} {
		got := readPeerAvailableHint(t, p)
		if got.DeviceId != "device-a" || got.Revision != 1 {
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
// 本地 peer 保留；租约缺失/不完整的视为僵尸关闭并广播 peer_unavailable_hint。
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
	if err := server.cache.TakeDiscovery(ctx, "device-a", healthy.connectionID, Discovery{DeviceID: "device-a", Revision: 1}, time.Minute); err != nil {
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
	// 仅 device-b 被 sweeping：healthy peer 收到一条 PeerUnavailableHint。
	hint := readPeerUnavailableHint(t, healthy)
	if hint.DeviceId != "device-b" {
		t.Fatalf("healthy peer expected device-b peer_unavailable_hint, got %+v", hint)
	}
}

// TestPublishDiscoveryV2AcksAndPersists 固定 v2 可靠发布原语：publishDiscoveryV2
// 落盘 discovery、返回 DiscoveryAck（runtime_epoch + revision）、向其它 v2 控制面
// peer 广播 PeerAvailableHint，且同 epoch 的 revision 严格递增、同 revision 内容
// 不可变。
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
	if d.Revision != 1 || d.RuntimeEpochHigh != epoch.High || d.RuntimeEpochLow != epoch.Low {
		t.Fatalf("stored discovery mismatch: %+v", d)
	}
	if len(d.Candidates) != 1 || d.Candidates[0] != "Y2FuZC1hLWJsb2I=" { // base64("cand-a-blob")
		t.Fatalf("v2 candidate should round-trip as base64: %+v", d.Candidates)
	}
	// PeerAvailableHint 广播到其它 peer。
	hint := readPeerAvailableHint(t, other)
	if hint.DeviceId != "device-a" || hint.Revision != 1 {
		t.Fatalf("expected peer_available_hint for device-a rev 1, got %+v", hint)
	}

	// 同 epoch 更高 revision → 接受，广播 peer_available_hint（revision 2）。
	ack2, err := server.hub.publishDiscoveryV2(43, "device-a", sender.connectionID, &v2.DiscoverySnapshot{
		RuntimeEpoch: epoch, Revision: 2, CandidateBundle: &v2.CandidateBundle{Candidates: [][]byte{[]byte("new-blob")}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if ack2.Revision != 2 {
		t.Fatalf("ack revision should be 2, got %d", ack2.Revision)
	}
	hint = readPeerAvailableHint(t, other)
	if hint.DeviceId != "device-a" || hint.Revision != 2 {
		t.Fatalf("expected peer_available_hint for device-a rev 2, got %+v", hint)
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

// TestPublishDiscoveryV2RejectsStaleOwner 固定 Discovery CAS：旧连接已被新连接取代
// （presence 已易主）后，旧连接的 v2 publish 被拒绝——不覆盖新连接的 discovery。
func TestPublishDiscoveryV2RejectsStaleOwner(t *testing.T) {
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
	if err := server.cache.TakeDiscovery(ctx, "device-a", old.connectionID, Discovery{DeviceID: "device-a", Revision: 1, Candidates: []string{"cand-1"}}, time.Minute); err != nil {
		t.Fatal(err)
	}
	// 新连接接管 presence（跨实例/重连）。
	newConn := &peer{deviceID: "device-a", connectionID: "conn-a-2", outbound: make(chan outboundFrame, 8), done: make(chan struct{})}
	if _, _, err := server.cache.TakePresence(ctx, "device-a", newConn.connectionID, Presence{InstanceID: "i2"}, time.Minute); err != nil {
		t.Fatal(err)
	}

	// 旧连接尝试覆盖 discovery：CAS 拒绝，不落盘。
	epoch := &v2.RuntimeEpoch{High: 1, Low: 2}
	if _, err := server.hub.publishDiscoveryV2(1, "device-a", old.connectionID, &v2.DiscoverySnapshot{
		RuntimeEpoch: epoch, Revision: 2, CandidateBundle: &v2.CandidateBundle{Candidates: [][]byte{[]byte("cand-2")}},
	}); !errors.Is(err, errDiscoveryNotOwner) {
		t.Fatalf("stale owner publish should be rejected with errDiscoveryNotOwner, got %v", err)
	}
	d, present, err := server.cache.GetDiscovery(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("discovery missing: present=%v err=%v", present, err)
	}
	if d.Revision != 1 || d.ConnectionID != old.connectionID {
		t.Fatalf("stale owner must not overwrite discovery: %+v", d)
	}
}

// TestHandleRelayEventPeerEvents 固定 handleRelayEvent 对推送发现事件的处理：其它
// 实例的事件广播到本地 v2 控制面 peer；同实例回环事件被跳过（避免重复推送）。
func TestHandleRelayEventPeerEvents(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()
	other := injectPeer(server.hub, "device-b")
	// device-a 有已发布的 discovery，online/updated 事件据此构造 PeerAvailableHint。
	if _, _, err := server.cache.TakePresence(ctx, "device-a", "conn-a", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-a", "conn-a", Discovery{
		DeviceID: "device-a", RuntimeEpochHigh: 1, RuntimeEpochLow: 1, Revision: 3,
	}, time.Minute); err != nil {
		t.Fatal(err)
	}

	server.handleRelayEvent(RelayEvent{Type: eventPeerOnline, DeviceID: "device-a", InstanceID: "other-instance"})
	hint := readPeerAvailableHint(t, other)
	if hint.DeviceId != "device-a" || hint.Revision != 3 {
		t.Fatalf("peer_online should broadcast locally as available hint, got %+v", hint)
	}

	// 同实例回环：发布方已本地广播过，订阅侧跳过。
	server.handleRelayEvent(RelayEvent{Type: eventPeerUpdated, DeviceID: "device-a", InstanceID: server.hub.instanceID})
	assertNoOutbound(t, other)

	server.handleRelayEvent(RelayEvent{Type: eventPeerOffline, DeviceID: "device-a", InstanceID: "other-instance"})
	h := readPeerUnavailableHint(t, other)
	if h.DeviceId != "device-a" {
		t.Fatalf("peer_offline should broadcast locally as unavailable hint, got %+v", h)
	}
}

// TestDiscoveryReconnectStaleOwnerWindowNotOnline 固定重连窗口的在线语义：新连接
// TakePresence 接管后、尚未重新发布 discovery 前，旧连接残留的 discovery（owner 仍
// 是旧连接）不满足「presence 与 discovery owner 一致」，因此设备不算在线；新连接的
// 真实发布（owner 一致）才按首次可发现广播 PeerAvailableHint。
func TestDiscoveryReconnectStaleOwnerWindowNotOnline(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	ctx := context.Background()

	other := injectPeer(server.hub, "device-b")

	// 首次连接：presence + discovery（rev 5）均为 conn-a-1 所有 → 在线。
	first := &peer{deviceID: "device-a", connectionID: "conn-a-1", outbound: make(chan outboundFrame, 8), done: make(chan struct{})}
	if _, _, err := server.cache.TakePresence(ctx, "device-a", first.connectionID, Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-a", first.connectionID, Discovery{DeviceID: "device-a", Revision: 5, Candidates: []string{"cand"}, UpdatedAt: time.Now()}, time.Minute); err != nil {
		t.Fatal(err)
	}
	online, err := server.cache.ListOnlinePeers(ctx)
	if err != nil || online["device-a"].Revision != 5 {
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

	// 新连接发布真实 discovery（rev 6，owner conn-a-2）→ 首次可发现广播。
	epoch := &v2.RuntimeEpoch{High: 0x11, Low: 0x22}
	if _, err := server.hub.publishDiscoveryV2(1, "device-a", second.connectionID, &v2.DiscoverySnapshot{
		RuntimeEpoch: epoch, Revision: 6, CandidateBundle: &v2.CandidateBundle{Candidates: [][]byte{[]byte("cand")}},
	}); err != nil {
		t.Fatal(err)
	}
	d, present, err := server.cache.GetDiscovery(ctx, "device-a")
	if err != nil || !present {
		t.Fatalf("discovery after reconnect missing: present=%v err=%v", present, err)
	}
	if d.Revision != 6 || d.ConnectionID != second.connectionID {
		t.Fatalf("reconnect discovery should be rev 6 owned by conn-a-2: %+v", d)
	}
	hint := readPeerAvailableHint(t, other)
	if hint.DeviceId != "device-a" || hint.Revision != 6 {
		t.Fatalf("reconnect real publish should broadcast peer_available_hint, got %+v", hint)
	}
	online, err = server.cache.ListOnlinePeers(ctx)
	if err != nil || online["device-a"].Revision != 6 {
		t.Fatalf("device-a should be online after reconnect publish: %+v err=%v", online, err)
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

// TestMultiInstancePeerEventPropagation 验证 v2 DiscoveryPublish 在实例 A 触发的
// 事件经 Redis 总线传播到实例 B，B 将其广播给本地 v2 控制面 peer。需要 MySQL+Redis，
// 无环境时跳过。
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

	credA, privA := enrollV2(t, httpA.URL, "device-a")
	connA := dialControlV2(t, httpA.URL, credA, "device-a", 0x30, privA)
	defer connA.Close()
	credB, privB := enrollV2(t, httpB.URL, "device-b")
	connB := dialControlV2(t, httpB.URL, credB, "device-b", 0x31, privB)
	defer connB.Close()

	// 等待两个实例的 presence 租约落盘。
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		_, presentA, _ := serverA.cache.GetPresence(ctx, "device-a")
		_, presentB, _ := serverB.cache.GetPresence(ctx, "device-b")
		if presentA && presentB {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	// device-a 发布 discovery：A 本地广播 + Publish 跨实例事件，B 收到后广播
	// PeerAvailableHint 给本地 peer（connB）。
	writeV2ControlFrame(t, connA, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_DiscoveryPublish{DiscoveryPublish: &v2.DiscoveryPublish{
			RequestId: 1,
			Snapshot: &v2.DiscoverySnapshot{
				RuntimeEpoch:    &v2.RuntimeEpoch{High: 0x6a09e667, Low: 0xbb67ae85},
				Revision:        1,
				CandidateBundle: &v2.CandidateBundle{Candidates: [][]byte{[]byte("cand-a")}},
				PublishedAtMs:   time.Now().UnixMilli(),
			},
		}},
	})
	// 先消费 A 自身的 DiscoveryAck（避免与 B 的 hint 混淆——不同连接互不干扰）。
	ack := readV2ControlFrame(t, connA)
	if ack.GetDiscoveryAck() == nil {
		t.Fatalf("device-a expected discovery_ack, got %s", v2.KindName(ack))
	}

	wait := time.Now().Add(5 * time.Second)
	for time.Now().Before(wait) {
		_ = connB.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		frame, err := readV2ControlFrameNoFatal(connB)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				time.Sleep(50 * time.Millisecond)
				continue
			}
			t.Fatalf("read from instance B: %v", err)
		}
		if hint := frame.GetPeerAvailableHint(); hint != nil && hint.DeviceId == "device-a" && hint.Revision == 1 {
			_ = connB.SetReadDeadline(time.Time{})
			return
		}
	}
	_ = connB.SetReadDeadline(time.Time{})
	t.Fatal("instance B peer did not receive peer_available_hint published by instance A")
}
