// 推送发现控制面测试：lookup 租约判定、broadcast 排除语义、discovery_update
// 处理、presence sweeper、GET /v1/peers 与跨实例事件广播。

package relay

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
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
	// device-b 只有 presence，device-c 只有 discovery：都不在线。
	if _, _, err := server.cache.TakePresence(ctx, "device-b", "conn-b", Presence{InstanceID: "i1"}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := server.cache.TakeDiscovery(ctx, "device-c", "conn-c", Discovery{DeviceID: "device-c", Generation: 3, Candidates: []string{"cand-c"}}, time.Minute); err != nil {
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
}

// TestLookupFailsOpenToLocalPeers 固定租约读取出错时的 fail-open 退化语义：回退到
// 本地 h.peers 判定，本实例有连接即在线。
func TestLookupFailsOpenToLocalPeers(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
	})
	defer server.Close()
	caller := injectPeer(server.hub, "caller")
	injectPeer(server.hub, "device-x") // 本地表有连接，但缓存不可读

	// 缓存故障：任何 GetPresence/GetDiscovery 都返回错误。
	server.hub.presence = erroringCache{}

	server.hub.lookupPeer(caller, "device-x")
	frame := readControlFrame(t, caller)
	if frame.Online == nil || !*frame.Online {
		t.Fatalf("cache failure should fail open to local peer table: %+v", frame)
	}

	server.hub.lookupPeer(caller, "device-y")
	frame = readControlFrame(t, caller)
	if frame.Online == nil || *frame.Online {
		t.Fatalf("cache failure should not report a device absent from local table as online: %+v", frame)
	}
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

// TestDiscoveryUpdatePlaceholderToOnline 固定连接建立时的占位 discovery（generation 0）
// 被真实上传覆盖后按首次上报广播 peer_online（§8：上传 discovery 后才广播 online）。
func TestDiscoveryUpdatePlaceholderToOnline(t *testing.T) {
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
	// 模拟 hub.add 写入的占位 discovery。
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
		t.Fatalf("placeholder->real upload should broadcast peer_online, got %+v", frame)
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

	// 等待两个实例的 presence/discovery 占位落盘。
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
