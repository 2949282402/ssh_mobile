// /v2/control 与 /v2/relay/{reservation_id} 的端到端契约测试（Step 7：控制面与数据面
// 物理拆开）。这些测试走真实 WebSocket 升级 + 冻结 codec，验证：Ready 首帧、心跳、
// 发现发布/解析、offer/answer 转发、realtime 转发、presence hint 广播、reservation
// 生命周期与 /v2/relay 不透明转发，以及控制面纯净性（RelayDataFrame 错投控制面即违规）。

package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

// ---------------------------------------------------------------------------
// 测试辅助：v2 控制面与数据面连接
// ---------------------------------------------------------------------------

// newV2TestServer 构造一个仅内存的 Relay server 与 httptest 服务器，返回关闭函数。
func newV2TestServer(t *testing.T) (*Server, *httptest.Server) {
	t.Helper()
	server := NewServer(Config{
		CredentialKey:   []byte(mysqlTestCredentialKey),
		EnrollmentToken: "test-token",
		CredentialTTL:   time.Hour,
		MaxConnections:  16,
	})
	t.Cleanup(server.Close)
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	httpServer := httptest.NewServer(mux)
	t.Cleanup(httpServer.Close)
	return server, httpServer
}

// enrollV2 注册设备并返回 credential + keypair。
func enrollV2(t *testing.T, baseURL, deviceID string) (string, ed25519.PrivateKey) {
	t.Helper()
	credential, _, privateKey := enrollViaHTTP(t, baseURL, deviceID, "test-token")
	return credential, privateKey
}

// dialControlV2 连接 /v2/control 并消费首帧 Ready。
func dialControlV2(t *testing.T, baseURL, credential, deviceID string, nonceByte byte, privateKey ed25519.PrivateKey) *websocket.Conn {
	t.Helper()
	conn := dialControlV2NoReady(t, baseURL, credential, deviceID, nonceByte, privateKey)
	ready := readV2ControlFrame(t, conn)
	if ready.GetReady() == nil ||
		ready.GetReady().ProtocolVersion != v2.RELAY_V2_VERSION ||
		ready.GetReady().DeviceId != deviceID ||
		ready.GetReady().HeartbeatIntervalS != v2.HEARTBEAT_INTERVAL_S ||
		ready.GetReady().PresenceTtlS != v2.PRESENCE_TTL_S ||
		ready.GetReady().ServerTimeMs <= 0 {
		t.Fatalf("invalid v2 ready frame: %+v", ready)
	}
	return conn
}

func dialControlV2NoReady(t *testing.T, baseURL, credential, deviceID string, nonceByte byte, privateKey ed25519.PrivateKey) *websocket.Conn {
	t.Helper()
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{nonceByte}, 32))
	headers := http.Header{}
	headers.Set("Authorization", "Bearer "+credential)
	headers.Set("X-Relay-Nonce", nonce)
	headers.Set("X-Relay-Signature", base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, []byte("GET\n/v2/control\n"+nonce)),
	))
	relayURL, err := url.Parse(baseURL)
	if err != nil {
		t.Fatal(err)
	}
	relayURL.Scheme = "ws"
	relayURL.Path = "/v2/control"
	conn, response, err := websocket.DefaultDialer.Dial(relayURL.String(), headers)
	if err != nil {
		status := 0
		if response != nil {
			status = response.StatusCode
		}
		t.Fatalf("v2 control websocket connect failed with status %d: %v", status, err)
	}
	return conn
}

// dialRelayData 连接 /v2/relay/{reservationID}，用 hex 编码的 reservation token（query
// ?token=）授权，返回已升级连接。
func dialRelayData(t *testing.T, baseURL, reservationID, tokenHex string) *websocket.Conn {
	t.Helper()
	relayURL, err := url.Parse(baseURL)
	if err != nil {
		t.Fatal(err)
	}
	relayURL.Scheme = "ws"
	relayURL.Path = "/v2/relay/" + reservationID
	q := relayURL.Query()
	if tokenHex != "" {
		q.Set("token", tokenHex)
	}
	relayURL.RawQuery = q.Encode()
	conn, response, err := websocket.DefaultDialer.Dial(relayURL.String(), nil)
	if err != nil {
		status := 0
		if response != nil {
			status = response.StatusCode
		}
		t.Fatalf("v2 relay websocket connect failed with status %d: %v", status, err)
	}
	return conn
}

func writeV2ControlFrame(t *testing.T, conn *websocket.Conn, frame *v2.RelayFrame) {
	t.Helper()
	data, err := v2.EncodeFrame(frame)
	if err != nil {
		t.Fatalf("encode v2 control frame: %v", err)
	}
	if err := conn.WriteMessage(websocket.BinaryMessage, data); err != nil {
		t.Fatalf("write v2 control frame: %v", err)
	}
}

func readV2ControlFrame(t *testing.T, conn *websocket.Conn) *v2.RelayFrame {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	frame, err := readV2ControlFrameNoFatal(conn)
	if err != nil {
		t.Fatalf("read v2 control frame: %v", err)
	}
	return frame
}

// readV2ControlFrameNoFatal 读取一帧 v2 控制帧；失败（超时/关闭/解码错）返回 error
// 而非 t.Fatalf，供轮询循环使用。调用方负责设置读 deadline。
func readV2ControlFrameNoFatal(conn *websocket.Conn) (*v2.RelayFrame, error) {
	kind, data, err := conn.ReadMessage()
	if err != nil {
		return nil, err
	}
	if kind != websocket.BinaryMessage {
		return nil, fmt.Errorf("expected binary control frame, got message type %d", kind)
	}
	frame, err := v2.DecodeControl(data)
	if err != nil {
		return nil, err
	}
	return frame, nil
}

func readV2RealtimeSignal(t *testing.T, conn *websocket.Conn) *v2.RealtimeSignal {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		_ = conn.SetReadDeadline(deadline)
		frame, err := readV2ControlFrameNoFatal(conn)
		if err != nil {
			t.Fatalf("read v2 realtime signal: %v", err)
		}
		if signal := frame.GetRealtimeSignal(); signal != nil {
			return signal
		}
	}
}

func writeV2DataFrame(t *testing.T, conn *websocket.Conn, frame *v2.RelayDataFrame) {
	t.Helper()
	data, err := v2.EncodeDataFrame(frame)
	if err != nil {
		t.Fatalf("encode v2 data frame: %v", err)
	}
	if err := conn.WriteMessage(websocket.BinaryMessage, data); err != nil {
		t.Fatalf("write v2 data frame: %v", err)
	}
}

// readV2DataFrameDeadline 用自定义 deadline 读取一帧数据面帧（返回 nil 表示超时/关闭）。
func readV2DataFrameDeadline(t *testing.T, conn *websocket.Conn, deadline time.Duration) *v2.RelayDataFrame {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(deadline))
	kind, data, err := conn.ReadMessage()
	if err != nil {
		return nil
	}
	if kind != websocket.BinaryMessage {
		t.Fatalf("expected binary data frame, got message type %d", kind)
	}
	frame, err := v2.DecodeData(data)
	if err != nil {
		t.Fatalf("decode v2 data frame: %v", err)
	}
	return frame
}

// waitRelayPending 轮询 role-aware relayDataRegistry，直到 reservationID 是否
// 仍有未配对端点（true=一端等待，false=两端已就绪/无等待端点）。
func waitRelayPending(t *testing.T, server *Server, reservationID string, want bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		server.relayData.mutex.Lock()
		pair := server.relayData.pairs[reservationID]
		present := pair != nil && (pair.initiator == nil || pair.responder == nil)
		server.relayData.mutex.Unlock()
		if present == want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("relay data pending state for %s: want present=%v, timed out", reservationID, want)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func readRelayDataReady(t *testing.T, conn *websocket.Conn, reservationID string) {
	t.Helper()
	frame := readV2DataFrame(t, conn)
	if frame == nil || frame.GetReady() == nil || frame.GetReady().ReservationId != reservationID {
		t.Fatalf("expected relay_data_ready for %s, got %+v", reservationID, frame)
	}
}

// readV2DataFrame 读取一帧数据面帧（2s deadline）；超时/连接关闭时返回 nil。
func readV2DataFrame(t *testing.T, conn *websocket.Conn) *v2.RelayDataFrame {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	kind, data, err := conn.ReadMessage()
	if err != nil {
		return nil
	}
	if kind != websocket.BinaryMessage {
		t.Fatalf("expected binary data frame, got message type %d", kind)
	}
	frame, err := v2.DecodeData(data)
	if err != nil {
		t.Fatalf("decode v2 data frame: %v", err)
	}
	return frame
}

// publishDiscoveryV2Test 让设备发布一份 revision=1 的 discovery 并读取 DiscoveryAck。
func publishDiscoveryV2Test(t *testing.T, conn *websocket.Conn, requestID uint64) *v2.DiscoveryAck {
	t.Helper()
	writeV2ControlFrame(t, conn, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_DiscoveryPublish{DiscoveryPublish: &v2.DiscoveryPublish{
			RequestId: requestID,
			Snapshot: &v2.DiscoverySnapshot{
				RuntimeEpoch:          &v2.RuntimeEpoch{High: 0x6a09e667, Low: 0xbb67ae85},
				Revision:              1,
				TransportCapabilities: []v2.TransportCapability{v2.TransportCapability_TRANSPORT_CAPABILITY_WEBRTC},
				CandidateBundle:       &v2.CandidateBundle{Candidates: [][]byte{[]byte("cand-a")}},
				PublishedAtMs:         time.Now().UnixMilli(),
			},
		}},
	})
	ack := readV2ControlFrame(t, conn)
	got := ack.GetDiscoveryAck()
	if got == nil {
		t.Fatalf("expected discovery_ack, got %s", v2.KindName(ack))
	}
	if got.RequestId != requestID || got.Revision != 1 {
		t.Fatalf("unexpected discovery ack: %+v", got)
	}
	return got
}

// ---------------------------------------------------------------------------
// 控制面：Ready / Heartbeat
// ---------------------------------------------------------------------------

func TestControlV2ReadyAndHeartbeat(t *testing.T) {
	_, httpServer := newV2TestServer(t)
	credential, privateKey := enrollV2(t, httpServer.URL, "device-a")

	conn := dialControlV2(t, httpServer.URL, credential, "device-a", 0x21, privateKey)
	defer conn.Close()

	writeV2ControlFrame(t, conn, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_Heartbeat{Heartbeat: &v2.Heartbeat{
			RequestId: 1001,
			SentAtMs:  time.Now().UnixMilli(),
		}},
	})
	ack := readV2ControlFrame(t, conn)
	hb := ack.GetHeartbeatAck()
	if hb == nil || hb.RequestId != 1001 || hb.ServerTimeMs <= 0 {
		t.Fatalf("invalid heartbeat ack: %+v", ack)
	}
}

// ---------------------------------------------------------------------------
// 控制面：DiscoveryPublish / ResolvePeer / presence hint
// ---------------------------------------------------------------------------

func TestControlV2DiscoveryPublishResolveAndHints(t *testing.T) {
	_, httpServer := newV2TestServer(t)
	credA, privA := enrollV2(t, httpServer.URL, "device-a")
	credB, privB := enrollV2(t, httpServer.URL, "device-b")

	connA := dialControlV2(t, httpServer.URL, credA, "device-a", 0x31, privA)
	defer connA.Close()
	connB := dialControlV2(t, httpServer.URL, credB, "device-b", 0x32, privB)
	defer connB.Close()

	// device-a 发布 discovery → 自身拿 DiscoveryAck，device-b 收到 PeerAvailableHint。
	publishDiscoveryV2Test(t, connA, 1001)
	hint := readV2ControlFrame(t, connB)
	avail := hint.GetPeerAvailableHint()
	if avail == nil || avail.DeviceId != "device-a" || avail.Revision != 1 {
		t.Fatalf("device-b expected peer_available_hint for device-a, got %+v", hint)
	}

	// device-b resolve device-a → READY + discovery。
	writeV2ControlFrame(t, connB, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_ResolvePeerRequest{ResolvePeerRequest: &v2.ResolvePeerRequest{
			RequestId:      2002,
			TargetDeviceId: "device-a",
		}},
	})
	resp := readV2ControlFrame(t, connB)
	rs := resp.GetResolvePeerResponse()
	if rs == nil || rs.Status != v2.ResolveStatus_RESOLVE_STATUS_READY {
		t.Fatalf("device-a should resolve READY: %+v", resp)
	}
	if rs.Discovery == nil || rs.Discovery.Revision != 1 ||
		len(rs.Discovery.CandidateBundle.Candidates) != 1 ||
		!bytes.Equal(rs.Discovery.CandidateBundle.Candidates[0], []byte("cand-a")) {
		t.Fatalf("READY resolve should carry device-a discovery: %+v", rs.Discovery)
	}

	// 未上线目标 → OFFLINE。
	writeV2ControlFrame(t, connB, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_ResolvePeerRequest{ResolvePeerRequest: &v2.ResolvePeerRequest{
			RequestId:      2003,
			TargetDeviceId: "offline-device",
		}},
	})
	resp = readV2ControlFrame(t, connB)
	rs = resp.GetResolvePeerResponse()
	if rs == nil || rs.Status != v2.ResolveStatus_RESOLVE_STATUS_OFFLINE {
		t.Fatalf("offline target should resolve OFFLINE: %+v", resp)
	}
	// 注：presence hint 帧（PeerAvailableHint 等）是服务端→客户端方向，客户端反向发送
	// 属协议违规，见 TestControlV2RejectsClientHintFrames。
}

// ---------------------------------------------------------------------------
// 控制面：ConnectivityOffer / ConnectivityAnswer 转发
// ---------------------------------------------------------------------------

func TestControlV2ConnectivityForwarding(t *testing.T) {
	_, httpServer := newV2TestServer(t)
	credA, privA := enrollV2(t, httpServer.URL, "device-a")
	credB, privB := enrollV2(t, httpServer.URL, "device-b")

	connA := dialControlV2(t, httpServer.URL, credA, "device-a", 0x41, privA)
	defer connA.Close()
	connB := dialControlV2(t, httpServer.URL, credB, "device-b", 0x42, privB)
	defer connB.Close()

	// A 与 B 都发布 discovery：A 的 offer 需要服务端用其已发布 discovery 覆盖
	// initiator_snapshot，B 需要在线可连供 A resolve。
	publishDiscoveryV2Test(t, connA, 1001)
	if hint := readV2ControlFrame(t, connB); hint.GetPeerAvailableHint() == nil {
		t.Fatalf("device-b expected peer_available_hint after device-a publish, got %+v", hint)
	}
	publishDiscoveryV2Test(t, connB, 2001)
	if hint := readV2ControlFrame(t, connA); hint.GetPeerAvailableHint() == nil {
		t.Fatalf("device-a expected peer_available_hint after device-b publish, got %+v", hint)
	}

	// A resolve B；ConnectivityOffer 另外携带显式 target_device_id。
	writeV2ControlFrame(t, connA, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_ResolvePeerRequest{ResolvePeerRequest: &v2.ResolvePeerRequest{
			RequestId: 1002, TargetDeviceId: "device-b",
		}},
	})
	if resp := readV2ControlFrame(t, connA); resp.GetResolvePeerResponse() == nil {
		t.Fatalf("expected resolve response, got %+v", resp)
	}

	// A 向 B 发带显式目标的 ConnectivityOffer。
	attemptID := "a1b2c3d4e5f60718293a4b5c6d7e8f90"
	writeV2ControlFrame(t, connA, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_ConnectivityOffer{ConnectivityOffer: &v2.ConnectivityOffer{
			RequestId:         1003,
			AttemptId:         attemptID,
			InitiatorDeviceId: "device-a",
			TargetDeviceId:    "device-b",
		}},
	})
	offer := readV2ControlFrame(t, connB)
	of := offer.GetConnectivityOffer()
	if of == nil || of.AttemptId != attemptID || of.InitiatorDeviceId != "device-a" {
		t.Fatalf("device-b expected connectivity_offer, got %+v", offer)
	}
	// 服务端必须用 A 的已发布 discovery 覆盖 initiator_snapshot。
	if of.InitiatorSnapshot == nil || of.InitiatorSnapshot.Revision != 1 {
		t.Fatalf("server must overwrite initiator_snapshot with stored discovery: %+v", of.InitiatorSnapshot)
	}

	// B 回 ConnectivityAnswer → A 收到。
	writeV2ControlFrame(t, connB, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_ConnectivityAnswer{ConnectivityAnswer: &v2.ConnectivityAnswer{
			RequestId:         2003,
			AttemptId:         attemptID,
			Accepted:          true,
			ResponderDeviceId: "device-b",
		}},
	})
	ans := readV2ControlFrame(t, connA)
	an := ans.GetConnectivityAnswer()
	if an == nil || an.AttemptId != attemptID || !an.Accepted || an.ResponderDeviceId != "device-b" {
		t.Fatalf("device-a expected connectivity_answer, got %+v", ans)
	}
}

// TestControlV2ConnectivityOfferRoutesByExplicitTargetConcurrently fixes routing
// independence when one authenticated sender has multiple connectivity attempts in
// flight: each offer must use its own target_device_id, with no per-connection
// "last resolve" state that can cross-wire B and C.
func TestControlV2ConnectivityOfferRoutesByExplicitTargetConcurrently(t *testing.T) {
	server, _ := newV2TestServer(t)
	sender := injectPeer(server.hub, "device-a")
	targetB := injectPeer(server.hub, "device-b")
	targetC := injectPeer(server.hub, "device-c")

	offers := []*v2.ConnectivityOffer{
		{RequestId: 3001, AttemptId: strings.Repeat("b", 32), InitiatorDeviceId: "device-a", TargetDeviceId: "device-b"},
		{RequestId: 3002, AttemptId: strings.Repeat("c", 32), InitiatorDeviceId: "device-a", TargetDeviceId: "device-c"},
	}
	var waitGroup sync.WaitGroup
	for _, offer := range offers {
		waitGroup.Add(1)
		go func(offer *v2.ConnectivityOffer) {
			defer waitGroup.Done()
			server.hub.handleConnectivityOfferV2(sender, offer)
		}(offer)
	}
	waitGroup.Wait()

	for target, attemptID := range map[*peer]string{
		targetB: strings.Repeat("b", 32),
		targetC: strings.Repeat("c", 32),
	} {
		frame := readV2ControlFrameFromPeer(t, target)
		offer := frame.GetConnectivityOffer()
		if offer == nil || offer.AttemptId != attemptID || offer.TargetDeviceId != target.deviceID {
			t.Fatalf("target %s received the wrong explicit offer: %+v", target.deviceID, frame)
		}
	}
}

// ---------------------------------------------------------------------------
// 控制面：RealtimeSignal 转发
// ---------------------------------------------------------------------------

func TestControlV2RealtimeSignalForwarding(t *testing.T) {
	_, httpServer := newV2TestServer(t)
	credA, privA := enrollV2(t, httpServer.URL, "device-a")
	credB, privB := enrollV2(t, httpServer.URL, "device-b")

	connA := dialControlV2(t, httpServer.URL, credA, "device-a", 0x51, privA)
	defer connA.Close()
	connB := dialControlV2(t, httpServer.URL, credB, "device-b", 0x52, privB)
	defer connB.Close()

	send := func(t *testing.T, from, to *websocket.Conn, requestID uint64, target string, kind v2.RealtimeSignalKind, payload string) *v2.RealtimeSignal {
		t.Helper()
		writeV2ControlFrame(t, from, &v2.RelayFrame{
			Version: v2.RELAY_V2_VERSION,
			Kind: &v2.RelayFrame_RealtimeSignal{RealtimeSignal: &v2.RealtimeSignal{
				RequestId:      requestID,
				RealtimeId:     "rt-1234",
				TargetDeviceId: target,
				SenderDeviceId: "spoofed-device",
				Kind:           kind,
				Revision:       requestID,
				Payload:        []byte(payload),
			}},
		})
		return readV2RealtimeSignal(t, to)
	}

	// Each direction must preserve the authenticated sender, even when the
	// client-provided sender field is forged and target_device_id is the local
	// device on receipt.
	for _, tc := range []struct {
		name       string
		from, to   *websocket.Conn
		target     string
		kind       v2.RealtimeSignalKind
		payload    string
		wantSender string
	}{
		{name: "offer A to B", from: connA, to: connB, target: "device-b", kind: v2.RealtimeSignalKind_REALTIME_SIGNAL_KIND_OFFER, payload: "sdp-offer", wantSender: "device-a"},
		{name: "answer B to A", from: connB, to: connA, target: "device-a", kind: v2.RealtimeSignalKind_REALTIME_SIGNAL_KIND_ANSWER, payload: "sdp-answer", wantSender: "device-b"},
		{name: "ice A to B", from: connA, to: connB, target: "device-b", kind: v2.RealtimeSignalKind_REALTIME_SIGNAL_KIND_ICE_CANDIDATE, payload: "candidate-a", wantSender: "device-a"},
		{name: "ice B to A", from: connB, to: connA, target: "device-a", kind: v2.RealtimeSignalKind_REALTIME_SIGNAL_KIND_ICE_CANDIDATE, payload: "candidate-b", wantSender: "device-b"},
		{name: "close A to B", from: connA, to: connB, target: "device-b", kind: v2.RealtimeSignalKind_REALTIME_SIGNAL_KIND_CLOSE, payload: "close-a", wantSender: "device-a"},
		{name: "close B to A", from: connB, to: connA, target: "device-a", kind: v2.RealtimeSignalKind_REALTIME_SIGNAL_KIND_CLOSE, payload: "close-b", wantSender: "device-b"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			signal := send(t, tc.from, tc.to, uint64(len(tc.name)), tc.target, tc.kind, tc.payload)
			if signal.TargetDeviceId != tc.target || signal.SenderDeviceId != tc.wantSender ||
				signal.Kind != tc.kind || !bytes.Equal(signal.Payload, []byte(tc.payload)) {
				t.Fatalf("unexpected realtime signal: %+v", signal)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// 控制面纯净性：RelayDataFrame 错投 /v2/control 即违规关闭
// ---------------------------------------------------------------------------

func TestControlV2RejectsRelayDataFrame(t *testing.T) {
	_, httpServer := newV2TestServer(t)
	credential, privateKey := enrollV2(t, httpServer.URL, "device-a")

	conn := dialControlV2NoReady(t, httpServer.URL, credential, "device-a", 0x61, privateKey)
	// 先消费 Ready。
	if r := readV2ControlFrame(t, conn); r.GetReady() == nil {
		t.Fatalf("expected ready, got %+v", r)
	}
	// RelayDataConnect（oneof tag 10）被 RelayFrame 解码成 Ready（服务端→客户端方向），
	// 由控制面纯净性规则判违规并关闭。
	data, err := v2.EncodeDataFrame(&v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
			ReservationId: strings.Repeat("ab", 16),
			LocalToken:    make([]byte, 32),
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.WriteMessage(websocket.BinaryMessage, data); err != nil {
		t.Fatal(err)
	}
	// 服务端先回 ProtocolError 再关闭。
	pe := readV2ControlFrame(t, conn)
	if pe.GetProtocolError() == nil {
		t.Fatalf("expected protocol_error before close, got %+v", pe)
	}
	waitForClose(t, conn)
}

func waitForClose(t *testing.T, conn *websocket.Conn) {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	for {
		_, _, err := conn.ReadMessage()
		if err != nil {
			return
		}
	}
}

// ---------------------------------------------------------------------------
// Reservation 生命周期 + /v2/relay 数据面
// ---------------------------------------------------------------------------

func TestControlV2ReservationAndRelayData(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	credA, privA := enrollV2(t, httpServer.URL, "device-a")
	credB, privB := enrollV2(t, httpServer.URL, "device-b")

	connA := dialControlV2(t, httpServer.URL, credA, "device-a", 0x71, privA)
	defer connA.Close()
	connB := dialControlV2(t, httpServer.URL, credB, "device-b", 0x72, privB)
	defer connB.Close()

	// B 发布 discovery 使其 READY（A reserve B 前 B 必须在线可连）。
	publishDiscoveryV2Test(t, connB, 2001)
	// B 发布 discovery 会向 A 广播 PeerAvailableHint：先消费，避免与 reserve 响应混淆。
	if hint := readV2ControlFrame(t, connA); hint.GetPeerAvailableHint() == nil {
		t.Fatalf("device-a expected peer_available_hint after device-b publish, got %+v", hint)
	}

	// A 发起 reservation。
	attemptID := "r1c2d3e4f5a60718293a4b5c6d7e8f90"
	writeV2ControlFrame(t, connA, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_RelayReserveRequest{RelayReserveRequest: &v2.RelayReserveRequest{
			RequestId:        1001,
			AttemptId:        attemptID,
			TargetDeviceId:   "device-b",
			DesiredLifetimeS: 15,
		}},
	})
	resp := readV2ControlFrame(t, connA)
	rr := resp.GetRelayReserveResponse()
	if rr == nil || rr.AttemptId != attemptID || rr.ReservationId == "" ||
		len(rr.ReservationId) != v2.RESERVATION_ID_HEX_CHARS || len(rr.LocalToken) != v2.RESERVATION_TOKEN_BYTES {
		t.Fatalf("device-a expected relay_reserve_response, got %+v", resp)
	}
	if !strings.Contains(rr.RelayDataEndpoint, "/v2/relay/"+rr.ReservationId) {
		t.Fatalf("relay_data_endpoint should reference the reservation: %s", rr.RelayDataEndpoint)
	}
	expiresAt := time.UnixMilli(rr.ExpiresAtMs)
	if expiresAt.Before(time.Now()) || expiresAt.After(time.Now().Add(20*time.Second)) {
		t.Fatalf("reservation expiry should be clamped around 15s: %v", expiresAt)
	}

	// B 收到 IncomingRelayReservation（token 与 A 的不同）。
	incoming := readV2ControlFrame(t, connB)
	ir := incoming.GetIncomingRelayReservation()
	if ir == nil || ir.ReservationId != rr.ReservationId || ir.InitiatorDeviceId != "device-a" ||
		len(ir.LocalToken) != v2.RESERVATION_TOKEN_BYTES || bytes.Equal(ir.LocalToken, rr.LocalToken) {
		t.Fatalf("device-b expected incoming_relay_reservation, got %+v", incoming)
	}

	// reservation 落盘（Redis relay:reservation:{id} / memory map）。
	res, ok, err := server.cache.GetReservation(context.Background(), rr.ReservationId)
	if err != nil || !ok || res.InitiatorDeviceID != "device-a" || res.ResponderDeviceID != "device-b" {
		t.Fatalf("reservation should be stored: %+v ok=%v err=%v", res, ok, err)
	}

	// 双方连接 /v2/relay。
	dataA := dialRelayData(t, httpServer.URL, rr.ReservationId, hex.EncodeToString(rr.LocalToken))
	defer dataA.Close()
	dataB := dialRelayData(t, httpServer.URL, rr.ReservationId, hex.EncodeToString(ir.LocalToken))
	defer dataB.Close()

	// 首帧必须 RelayDataConnect。先 A：等待 A 在 registry 的 pending 中（第一端点），
	// 再 B：等待 pending 清空（两端点已互相 link）。分步等待消除「pending 为空但还没
	// 处理完 A 的 Connect」的竞态。
	writeV2DataFrame(t, dataA, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
			ReservationId: rr.ReservationId,
			LocalToken:    rr.LocalToken,
		}},
	})
	waitRelayPending(t, server, rr.ReservationId, true)

	writeV2DataFrame(t, dataB, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
			ReservationId: rr.ReservationId,
			LocalToken:    ir.LocalToken,
		}},
	})
	waitRelayPending(t, server, rr.ReservationId, false)
	readRelayDataReady(t, dataA, rr.ReservationId)
	readRelayDataReady(t, dataB, rr.ReservationId)

	// A → B：RelayDataPayload（不透明 encrypted_payload）。
	writeV2DataFrame(t, dataA, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Payload{Payload: &v2.RelayDataPayload{
			Sequence:         1,
			EncryptedPayload: []byte("opaque-chunk-1"),
		}},
	})
	payload := readV2DataFrame(t, dataB)
	p := payload.GetPayload()
	if p == nil || p.Sequence != 1 || !bytes.Equal(p.EncryptedPayload, []byte("opaque-chunk-1")) {
		t.Fatalf("device-b expected opaque relay_data_payload, got %+v", payload)
	}

	// B → A：RelayDataAck。
	writeV2DataFrame(t, dataB, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayDataFrame_Ack{Ack: &v2.RelayDataAck{Sequence: 1}},
	})
	ack := readV2DataFrame(t, dataA)
	if ack.GetAck() == nil || ack.GetAck().Sequence != 1 {
		t.Fatalf("device-a expected relay_data_ack, got %+v", ack)
	}

	// A → B：RelayDataClose（reason 0），双向关闭。
	writeV2DataFrame(t, dataA, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayDataFrame_Close{Close: &v2.RelayDataClose{Reason: 0, Detail: "done"}},
	})
	closeFrame := readV2DataFrame(t, dataB)
	if closeFrame.GetClose() == nil || closeFrame.GetClose().Reason != 0 {
		t.Fatalf("device-b expected relay_data_close, got %+v", closeFrame)
	}
}

// TestRelayDataReadyRequiresBothRoles fixes the strict data-plane readiness
// contract: the initiator may wait on the socket, but it must not receive
// Ready or become eligible for business payloads before the responder joins.
func TestRelayDataReadyRequiresBothRoles(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	ctx := context.Background()
	reservationID := hex.EncodeToString(randomBytes(16))
	initiatorToken := randomBytes(32)
	responderToken := randomBytes(32)
	if err := server.cache.CreateReservation(ctx, Reservation{
		ReservationID:     reservationID,
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		RelayDataEndpoint: "wss://" + httpServer.URL + "/v2/relay/" + reservationID,
		InitiatorToken:    initiatorToken,
		ResponderToken:    responderToken,
		ExpiresAtMs:       time.Now().Add(time.Minute).UnixMilli(),
	}); err != nil {
		t.Fatal(err)
	}

	dataA := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(initiatorToken))
	defer dataA.Close()
	writeV2DataFrame(t, dataA, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
			ReservationId: reservationID,
			LocalToken:    initiatorToken,
		}},
	})
	waitRelayPending(t, server, reservationID, true)
	// Simulate a delayed responder. The pending initiator must not observe a
	// setup acknowledgement while the other role is absent.
	type dataReadResult struct {
		frame *v2.RelayDataFrame
		err   error
	}
	initiatorRead := make(chan dataReadResult, 1)
	go func() {
		kind, data, err := dataA.ReadMessage()
		if err != nil {
			initiatorRead <- dataReadResult{err: err}
			return
		}
		if kind != websocket.BinaryMessage {
			initiatorRead <- dataReadResult{err: fmt.Errorf("unexpected message type %d", kind)}
			return
		}
		frame, err := v2.DecodeData(data)
		initiatorRead <- dataReadResult{frame: frame, err: err}
	}()
	select {
	case result := <-initiatorRead:
		if result.err != nil {
			t.Fatalf("initiator read failed before responder joined: %v", result.err)
		}
		t.Fatalf("initiator received data before responder joined: %+v", result.frame)
	case <-time.After(250 * time.Millisecond):
	}

	time.Sleep(500 * time.Millisecond)
	dataB := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(responderToken))
	defer dataB.Close()
	writeV2DataFrame(t, dataB, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
			ReservationId: reservationID,
			LocalToken:    responderToken,
		}},
	})
	waitRelayPending(t, server, reservationID, false)
	select {
	case result := <-initiatorRead:
		if result.err != nil {
			t.Fatalf("initiator failed waiting for Ready: %v", result.err)
		}
		if result.frame == nil || result.frame.GetReady() == nil || result.frame.GetReady().ReservationId != reservationID {
			t.Fatalf("expected relay_data_ready for %s, got %+v", reservationID, result.frame)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("initiator did not receive Ready after responder joined")
	}
	readRelayDataReady(t, dataB, reservationID)

	writeV2DataFrame(t, dataA, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Payload{Payload: &v2.RelayDataPayload{
			Sequence:         1,
			EncryptedPayload: []byte("after-ready"),
		}},
	})
	if frame := readV2DataFrame(t, dataB); frame == nil || frame.GetPayload() == nil {
		t.Fatalf("payload should forward after both Ready frames, got %+v", frame)
	}
}

// TestRelayDataSameRoleRetryReplacesOldEndpoint fixes role-aware reservation
// pairing: retries replace only the endpoint with the same token role and never
// link initiator+initiator or responder+responder.
func TestRelayDataSameRoleRetryReplacesOldEndpoint(t *testing.T) {
	for _, replaceInitiator := range []bool{true, false} {
		name := "responder"
		if replaceInitiator {
			name = "initiator"
		}
		t.Run(name, func(t *testing.T) {
			server, httpServer := newV2TestServer(t)
			ctx := context.Background()
			reservationID := hex.EncodeToString(randomBytes(16))
			initiatorToken := randomBytes(32)
			responderToken := randomBytes(32)
			if err := server.cache.CreateReservation(ctx, Reservation{
				ReservationID:     reservationID,
				InitiatorDeviceID: "device-a",
				ResponderDeviceID: "device-b",
				RelayDataEndpoint: "wss://" + httpServer.URL + "/v2/relay/" + reservationID,
				InitiatorToken:    initiatorToken,
				ResponderToken:    responderToken,
				ExpiresAtMs:       time.Now().Add(time.Minute).UnixMilli(),
			}); err != nil {
				t.Fatal(err)
			}

			firstToken := initiatorToken
			secondToken := responderToken
			if !replaceInitiator {
				firstToken, secondToken = responderToken, initiatorToken
			}
			first := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(firstToken))
			defer first.Close()
			writeV2DataFrame(t, first, &v2.RelayDataFrame{
				Version: v2.RELAY_V2_VERSION,
				Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
					ReservationId: reservationID,
					LocalToken:    firstToken,
				}},
			})
			waitRelayPending(t, server, reservationID, true)

			retry := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(firstToken))
			defer retry.Close()
			writeV2DataFrame(t, retry, &v2.RelayDataFrame{
				Version: v2.RELAY_V2_VERSION,
				Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
					ReservationId: reservationID,
					LocalToken:    firstToken,
				}},
			})
			if frame := readV2DataFrameDeadline(t, first, 2*time.Second); frame == nil || frame.GetClose() == nil {
				t.Fatalf("replaced %s endpoint should receive close, got %+v", name, frame)
			}
			waitRelayPending(t, server, reservationID, true)

			other := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(secondToken))
			defer other.Close()
			writeV2DataFrame(t, other, &v2.RelayDataFrame{
				Version: v2.RELAY_V2_VERSION,
				Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
					ReservationId: reservationID,
					LocalToken:    secondToken,
				}},
			})
			waitRelayPending(t, server, reservationID, false)
			readRelayDataReady(t, retry, reservationID)
			readRelayDataReady(t, other, reservationID)

			writeV2DataFrame(t, retry, &v2.RelayDataFrame{
				Version: v2.RELAY_V2_VERSION,
				Kind: &v2.RelayDataFrame_Payload{Payload: &v2.RelayDataPayload{
					Sequence:         7,
					EncryptedPayload: []byte("replacement-wins"),
				}},
			})
			frame := readV2DataFrame(t, other)
			if frame == nil || frame.GetPayload() == nil || frame.GetPayload().Sequence != 7 {
				t.Fatalf("replacement endpoint should be linked to the opposite role, got %+v", frame)
			}
		})
	}
}

func TestRelayDataPairedDisconnectRequiresFreshPair(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	ctx := context.Background()
	reservationID := hex.EncodeToString(randomBytes(16))
	initiatorToken := randomBytes(32)
	responderToken := randomBytes(32)
	if err := server.cache.CreateReservation(ctx, Reservation{
		ReservationID:     reservationID,
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		RelayDataEndpoint: "wss://" + httpServer.URL + "/v2/relay/" + reservationID,
		InitiatorToken:    initiatorToken,
		ResponderToken:    responderToken,
		ExpiresAtMs:       time.Now().Add(time.Minute).UnixMilli(),
	}); err != nil {
		t.Fatal(err)
	}
	connect := func(conn *websocket.Conn, token []byte) {
		t.Helper()
		writeV2DataFrame(t, conn, &v2.RelayDataFrame{
			Version: v2.RELAY_V2_VERSION,
			Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
				ReservationId: reservationID,
				LocalToken:    token,
			}},
		})
	}

	a1 := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(initiatorToken))
	b1 := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(responderToken))
	defer a1.Close()
	defer b1.Close()
	connect(a1, initiatorToken)
	waitRelayPending(t, server, reservationID, true)
	connect(b1, responderToken)
	waitRelayPending(t, server, reservationID, false)
	readRelayDataReady(t, a1, reservationID)
	readRelayDataReady(t, b1, reservationID)

	if err := a1.Close(); err != nil {
		t.Fatal(err)
	}
	closeFrame := readV2DataFrameDeadline(t, b1, 2*time.Second)
	if closeFrame == nil || closeFrame.GetClose() == nil || closeFrame.GetClose().Reason != 2 {
		t.Fatalf("paired peer should receive relay_data_close after disconnect, got %+v", closeFrame)
	}
	waitRelayPending(t, server, reservationID, false)

	a2 := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(initiatorToken))
	defer a2.Close()
	connect(a2, initiatorToken)
	waitRelayPending(t, server, reservationID, true)
	if frame := readV2DataFrameDeadline(t, a2, 250*time.Millisecond); frame != nil {
		t.Fatalf("replacement initiator must wait for a fresh responder, got %+v", frame)
	}

	b2 := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(responderToken))
	defer b2.Close()
	connect(b2, responderToken)
	waitRelayPending(t, server, reservationID, false)
	readRelayDataReady(t, a2, reservationID)
	readRelayDataReady(t, b2, reservationID)

	writeV2DataFrame(t, a2, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Payload{Payload: &v2.RelayDataPayload{
			Sequence:         8,
			EncryptedPayload: []byte("fresh-pair"),
		}},
	})
	frame := readV2DataFrame(t, b2)
	if frame == nil || frame.GetPayload() == nil || string(frame.GetPayload().EncryptedPayload) != "fresh-pair" {
		t.Fatalf("fresh pair should forward payload, got %+v", frame)
	}
}

// ---------------------------------------------------------------------------
// /v2/relay 校验
// ---------------------------------------------------------------------------

func TestRelayDataUpgradeValidation(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	ctx := context.Background()

	reservationID := hex.EncodeToString(randomBytes(16))
	initiatorToken := randomBytes(32)
	responderToken := randomBytes(32)
	if err := server.cache.CreateReservation(ctx, Reservation{
		ReservationID:     reservationID,
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		RelayDataEndpoint: "wss://" + httpServer.URL + "/v2/relay/" + reservationID,
		InitiatorToken:    initiatorToken,
		ResponderToken:    responderToken,
		ExpiresAtMs:       time.Now().Add(time.Minute).UnixMilli(),
	}); err != nil {
		t.Fatal(err)
	}

	// 非法格式 → 404（升级前 HTTP 拒绝）。
	badID := strings.Repeat("zz", 16)
	relayURL, _ := url.Parse(httpServer.URL)
	relayURL.Scheme = "ws"
	relayURL.Path = "/v2/relay/" + badID
	if _, response, err := websocket.DefaultDialer.Dial(relayURL.String(), nil); err == nil || response == nil || response.StatusCode != http.StatusNotFound {
		t.Fatalf("invalid reservation id should 404, got status=%v err=%v", statusOf(response), err)
	}

	// 不存在 → 404。
	nonexistent := hex.EncodeToString(randomBytes(16))
	relayURL.Path = "/v2/relay/" + nonexistent
	if _, response, err := websocket.DefaultDialer.Dial(relayURL.String(), nil); err == nil || response == nil || response.StatusCode != http.StatusNotFound {
		t.Fatalf("missing reservation should 404, got status=%v err=%v", statusOf(response), err)
	}

	// 无 token → 401。
	relayURL.Path = "/v2/relay/" + reservationID
	relayURL.RawQuery = ""
	if _, response, err := websocket.DefaultDialer.Dial(relayURL.String(), nil); err == nil || response == nil || response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("missing token should 401, got status=%v err=%v", statusOf(response), err)
	}

	// 错误 token → 401。
	relayURL.RawQuery = "token=" + strings.Repeat("ff", 32)
	if _, response, err := websocket.DefaultDialer.Dial(relayURL.String(), nil); err == nil || response == nil || response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong token should 401, got status=%v err=%v", statusOf(response), err)
	}
}

func statusOf(response *http.Response) int {
	if response == nil {
		return 0
	}
	return response.StatusCode
}

// TestRelayDataConnectValidation 固定 /v2/relay 首帧必须是 RelayDataConnect，且
// reservation_id/token 必须匹配，否则以 RelayDataClose(reason 2) 关闭。
func TestRelayDataConnectValidation(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	ctx := context.Background()

	reservationID := hex.EncodeToString(randomBytes(16))
	initiatorToken := randomBytes(32)
	responderToken := randomBytes(32)
	if err := server.cache.CreateReservation(ctx, Reservation{
		ReservationID:     reservationID,
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		RelayDataEndpoint: "wss://" + httpServer.URL + "/v2/relay/" + reservationID,
		InitiatorToken:    initiatorToken,
		ResponderToken:    responderToken,
		ExpiresAtMs:       time.Now().Add(time.Minute).UnixMilli(),
	}); err != nil {
		t.Fatal(err)
	}

	// 首帧不是 Connect → RelayDataClose(reason 2)。
	conn := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(initiatorToken))
	defer conn.Close()
	writeV2DataFrame(t, conn, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayDataFrame_Payload{Payload: &v2.RelayDataPayload{Sequence: 1, EncryptedPayload: []byte("x")}},
	})
	closeFrame := readV2DataFrame(t, conn)
	if closeFrame.GetClose() == nil || closeFrame.GetClose().Reason != 2 {
		t.Fatalf("expected relay_data_close reason 2 for non-connect first frame, got %+v", closeFrame)
	}

	// Connect 但 token 不匹配 → RelayDataClose(reason 2)。
	conn = dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(initiatorToken))
	defer conn.Close()
	writeV2DataFrame(t, conn, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
			ReservationId: reservationID,
			LocalToken:    bytes.Repeat([]byte{9}, 32),
		}},
	})
	closeFrame = readV2DataFrame(t, conn)
	if closeFrame.GetClose() == nil || closeFrame.GetClose().Reason != 2 {
		t.Fatalf("expected relay_data_close reason 2 for bad token, got %+v", closeFrame)
	}

	// Connect 但 reservation_id 与路径不符 → RelayDataClose(reason 2)。
	conn = dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(initiatorToken))
	defer conn.Close()
	writeV2DataFrame(t, conn, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
			ReservationId: hex.EncodeToString(randomBytes(16)),
			LocalToken:    initiatorToken,
		}},
	})
	closeFrame = readV2DataFrame(t, conn)
	if closeFrame.GetClose() == nil || closeFrame.GetClose().Reason != 2 {
		t.Fatalf("expected relay_data_close reason 2 for mismatched reservation id, got %+v", closeFrame)
	}
}

// TestRelayDataExpiryCloses 固定数据面到期强制关闭：reservation 过期（含 5s 宽限）后，
// 即使连接空闲，服务端也向本端投递 RelayDataClose(reason 1)。
func TestRelayDataExpiryCloses(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	ctx := context.Background()
	reservationID := hex.EncodeToString(randomBytes(16))
	initiatorToken := randomBytes(32)
	// 已过期的 reservation：宽限 5s 后（≈5s 内）服务端应强制关闭。
	if err := server.cache.CreateReservation(ctx, Reservation{
		ReservationID:     reservationID,
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		RelayDataEndpoint: "wss://" + httpServer.URL + "/v2/relay/" + reservationID,
		InitiatorToken:    initiatorToken,
		ResponderToken:    randomBytes(32),
		ExpiresAtMs:       time.Now().Add(-time.Second).UnixMilli(),
	}); err != nil {
		t.Fatal(err)
	}

	conn := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(initiatorToken))
	defer conn.Close()
	writeV2DataFrame(t, conn, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
			ReservationId: reservationID,
			LocalToken:    initiatorToken,
		}},
	})
	// expires_at + 5s 宽限：从「已过期 1s」算起约 4s 后关闭。
	closeFrame := readV2DataFrameDeadline(t, conn, 8*time.Second)
	if closeFrame == nil || closeFrame.GetClose() == nil || closeFrame.GetClose().Reason != 1 {
		t.Fatalf("expired reservation should close with reason 1, got %+v", closeFrame)
	}
}

// TestReservationLifetimeClamp 固定 desired_lifetime_s 夹取到 [15, 120]。
func TestReservationLifetimeClamp(t *testing.T) {
	cases := []struct {
		in, want uint32
	}{
		{0, v2.RESERVATION_LIFETIME_S_DEFAULT},
		{5, 15},
		{15, 15},
		{60, 60},
		{200, 120},
	}
	for _, c := range cases {
		if got := clampReservationLifetime(c.in); got != c.want {
			t.Errorf("clampReservationLifetime(%d) = %d, want %d", c.in, got, c.want)
		}
	}
}

// ---------------------------------------------------------------------------
// 控制面纯净性：客户端反向发送服务端→客户端方向帧即违规
// ---------------------------------------------------------------------------

// TestControlV2RejectsClientHintFrames 固定 presence hint 帧（PeerAvailableHint/
// PeerUnavailableHint/PresenceHintSnapshot）是服务端→客户端方向：服务端由
// broadcastPeerHintV2 从权威状态构造。已认证客户端反向原样发送这些帧可伪装任意设备的
// 在线/离线广播给整个 fleet，因此按控制面纯净性判违规：回一帧 ProtocolError 后关闭。
func TestControlV2RejectsClientHintFrames(t *testing.T) {
	_, httpServer := newV2TestServer(t)
	frames := []struct {
		deviceID string
		frame    *v2.RelayFrame
	}{
		{"device-a", &v2.RelayFrame{Version: v2.RELAY_V2_VERSION, Kind: &v2.RelayFrame_PeerAvailableHint{PeerAvailableHint: &v2.PeerAvailableHint{
			DeviceId: "device-a", RuntimeEpoch: &v2.RuntimeEpoch{High: 1}, Revision: 1,
		}}}},
		{"device-b", &v2.RelayFrame{Version: v2.RELAY_V2_VERSION, Kind: &v2.RelayFrame_PeerUnavailableHint{PeerUnavailableHint: &v2.PeerUnavailableHint{
			DeviceId: "device-a", Reason: "spoofed-offline",
		}}}},
		{"device-c", &v2.RelayFrame{Version: v2.RELAY_V2_VERSION, Kind: &v2.RelayFrame_PresenceHintSnapshot{PresenceHintSnapshot: &v2.PresenceHintSnapshot{
			Peers: []*v2.PeerPresenceHint{{DeviceId: "device-a", Online: true}},
		}}}},
	}
	for i, tc := range frames {
		credential, privateKey := enrollV2(t, httpServer.URL, tc.deviceID)
		conn := dialControlV2NoReady(t, httpServer.URL, credential, tc.deviceID, byte(0x70+i), privateKey)
		if r := readV2ControlFrame(t, conn); r.GetReady() == nil {
			t.Fatalf("expected ready, got %+v", r)
		}
		writeV2ControlFrame(t, conn, tc.frame)
		pe := readV2ControlFrame(t, conn)
		if pe.GetProtocolError() == nil {
			t.Fatalf("client hint frame %d should be rejected with protocol_error, got %+v", i, pe)
		}
		waitForClose(t, conn)
	}
}

// ---------------------------------------------------------------------------
// 控制面：ConnectivityOffer 发起方身份强制为发送者
// ---------------------------------------------------------------------------

// TestControlV2OfferInitiatorForcedToSender 固定 ConnectivityOffer 的发起方身份以服务端
// 认证为准：客户端可任意填 initiator_device_id（伪装成其它设备），服务端转发前必须强制
// 覆盖为发送者，防止对端把被伪装的设备记录为协商发起方。
func TestControlV2OfferInitiatorForcedToSender(t *testing.T) {
	_, httpServer := newV2TestServer(t)
	credA, privA := enrollV2(t, httpServer.URL, "device-a")
	credB, privB := enrollV2(t, httpServer.URL, "device-b")
	connA := dialControlV2(t, httpServer.URL, credA, "device-a", 0x81, privA)
	defer connA.Close()
	connB := dialControlV2(t, httpServer.URL, credB, "device-b", 0x82, privB)
	defer connB.Close()

	publishDiscoveryV2Test(t, connA, 1001)
	if hint := readV2ControlFrame(t, connB); hint.GetPeerAvailableHint() == nil {
		t.Fatalf("device-b expected peer_available_hint, got %+v", hint)
	}
	publishDiscoveryV2Test(t, connB, 2001)
	if hint := readV2ControlFrame(t, connA); hint.GetPeerAvailableHint() == nil {
		t.Fatalf("device-a expected peer_available_hint, got %+v", hint)
	}
	// A resolve B；offer 的路由目标由其显式 target_device_id 决定。
	writeV2ControlFrame(t, connA, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_ResolvePeerRequest{ResolvePeerRequest: &v2.ResolvePeerRequest{RequestId: 1002, TargetDeviceId: "device-b"}},
	})
	if resp := readV2ControlFrame(t, connA); resp.GetResolvePeerResponse() == nil {
		t.Fatalf("expected resolve response, got %+v", resp)
	}

	// A 伪造发起方为 "victim-device"：B 收到的 offer 里发起方必须是真实的 device-a。
	attemptID := "f1a2b3c4d5e60718293a4b5c6d7e8f90"
	writeV2ControlFrame(t, connA, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_ConnectivityOffer{ConnectivityOffer: &v2.ConnectivityOffer{
			RequestId:         1003,
			AttemptId:         attemptID,
			InitiatorDeviceId: "victim-device",
			TargetDeviceId:    "device-b",
		}},
	})
	offer := readV2ControlFrame(t, connB)
	of := offer.GetConnectivityOffer()
	if of == nil || of.AttemptId != attemptID {
		t.Fatalf("device-b expected connectivity_offer, got %+v", offer)
	}
	if of.InitiatorDeviceId != "device-a" {
		t.Fatalf("offer initiator must be forced to the authenticated sender device-a, got %q", of.InitiatorDeviceId)
	}
}

// ---------------------------------------------------------------------------
// Reservation：relay_data_endpoint 必须来自服务端配置的公共源
// ---------------------------------------------------------------------------

// TestRelayReserveEndpointFromServerOrigin 固定 relay_data_endpoint 从服务端配置的公共源
// 构造（RELAY_PUBLIC_URL），而不是连接主机：RelayReserveResponse 与对端收到的
// IncomingRelayReservation 都不得泄露 httptest 的连接主机。
func TestRelayReserveEndpointFromServerOrigin(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	server.hub.config.PublicURL = "wss://relay.example.com"
	credA, privA := enrollV2(t, httpServer.URL, "device-a")
	credB, privB := enrollV2(t, httpServer.URL, "device-b")
	connA := dialControlV2(t, httpServer.URL, credA, "device-a", 0x91, privA)
	defer connA.Close()
	connB := dialControlV2(t, httpServer.URL, credB, "device-b", 0x92, privB)
	defer connB.Close()

	publishDiscoveryV2Test(t, connB, 2001)
	if hint := readV2ControlFrame(t, connA); hint.GetPeerAvailableHint() == nil {
		t.Fatalf("device-a expected peer_available_hint, got %+v", hint)
	}

	attemptID := "e1f2a3b4c5d60718293a4b5c6d7e8f90"
	writeV2ControlFrame(t, connA, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_RelayReserveRequest{RelayReserveRequest: &v2.RelayReserveRequest{
			RequestId: 1001, AttemptId: attemptID, TargetDeviceId: "device-b", DesiredLifetimeS: 15,
		}},
	})
	resp := readV2ControlFrame(t, connA)
	rr := resp.GetRelayReserveResponse()
	if rr == nil || rr.ReservationId == "" {
		t.Fatalf("device-a expected relay_reserve_response, got %+v", resp)
	}
	wantEndpoint := "wss://relay.example.com/v2/relay/" + rr.ReservationId
	if rr.RelayDataEndpoint != wantEndpoint {
		t.Fatalf("relay_data_endpoint must use the configured public URL, got %q want %q", rr.RelayDataEndpoint, wantEndpoint)
	}
	if strings.Contains(rr.RelayDataEndpoint, "127.0.0.1") {
		t.Fatalf("relay_data_endpoint must not leak the connection host: %q", rr.RelayDataEndpoint)
	}
	incoming := readV2ControlFrame(t, connB)
	ir := incoming.GetIncomingRelayReservation()
	if ir == nil || !strings.HasPrefix(ir.RelayDataEndpoint, "wss://relay.example.com/v2/relay/") {
		t.Fatalf("incoming reservation must use the configured public URL too, got %+v", incoming)
	}
}

// TestRelayReserveEndpointIgnoresClientHostHeader 固定 relay_data_endpoint 绝不使用客户端
// 提供的 Host 头：peer.relayHost 是 /v2/control 升级时捕获的 Host 头（攻击者可控），即使
// 被注入恶意值，端点也必须来自服务端配置/监听地址派生，否则会把对端 B 的 ResponderToken
// 引导到攻击者选择的地址。
func TestRelayReserveEndpointIgnoresClientHostHeader(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	credB, privB := enrollV2(t, httpServer.URL, "device-b")
	connB := dialControlV2(t, httpServer.URL, credB, "device-b", 0x92, privB)
	defer connB.Close()
	publishDiscoveryV2Test(t, connB, 2001)

	// 单元级：注入带恶意 relayHost 的 peer，直接走 handleRelayReserveRequestV2。
	caller := injectPeer(server.hub, "device-x")
	caller.relayHost = "evil.example.com"
	server.hub.handleRelayReserveRequestV2(caller, &v2.RelayReserveRequest{
		RequestId: 1002, AttemptId: "a1b2c3d4e5f60718293a4b5c6d7e8f90", TargetDeviceId: "device-b", DesiredLifetimeS: 15,
	})
	frame := readV2ControlFrameFromPeer(t, caller)
	rr := frame.GetRelayReserveResponse()
	if rr == nil || rr.ReservationId == "" {
		t.Fatalf("expected relay_reserve_response, got %+v", frame)
	}
	if strings.Contains(rr.RelayDataEndpoint, "evil.example.com") {
		t.Fatalf("relay_data_endpoint must not use the client Host header: %q", rr.RelayDataEndpoint)
	}
	// 未配置 PublicURL 时应从监听地址派生（默认 :8080 → localhost:8080），仍非客户端 Host。
	if !strings.HasPrefix(rr.RelayDataEndpoint, "wss://localhost:8080/v2/relay/") {
		t.Fatalf("unconfigured public URL should derive from the listen address, got %q", rr.RelayDataEndpoint)
	}
}

// ---------------------------------------------------------------------------
// /v2/relay 数据面滑动窗口到期
// ---------------------------------------------------------------------------

// TestRelayDataSlidingExpiryKeepsActiveSessionAlive 固定数据面滑动窗口续期：reservation
// 名义到期（ExpiresAtMs+grace）后，只要流量持续（每帧触发展期），连接就必须保持存活，
// 不再被一次性定时器在 lifetime+grace 后强关。ExpiresAtMs=now、LifetimeS=1：无滑动窗口
// 时硬到期≈5s，测试持续转发 8s，断言任何一侧都不中途关闭。
func TestRelayDataSlidingExpiryKeepsActiveSessionAlive(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	ctx := context.Background()
	reservationID := hex.EncodeToString(randomBytes(16))
	initiatorToken := randomBytes(32)
	responderToken := randomBytes(32)
	if err := server.cache.CreateReservation(ctx, Reservation{
		ReservationID:     reservationID,
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		RelayDataEndpoint: "wss://" + httpServer.URL + "/v2/relay/" + reservationID,
		InitiatorToken:    initiatorToken,
		ResponderToken:    responderToken,
		ExpiresAtMs:       time.Now().UnixMilli(),
		LifetimeS:         1,
	}); err != nil {
		t.Fatal(err)
	}
	dataA := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(initiatorToken))
	defer dataA.Close()
	dataB := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(responderToken))
	defer dataB.Close()
	writeV2DataFrame(t, dataA, &v2.RelayDataFrame{Version: v2.RELAY_V2_VERSION, Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{ReservationId: reservationID, LocalToken: initiatorToken}}})
	waitRelayPending(t, server, reservationID, true)
	writeV2DataFrame(t, dataB, &v2.RelayDataFrame{Version: v2.RELAY_V2_VERSION, Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{ReservationId: reservationID, LocalToken: responderToken}}})
	waitRelayPending(t, server, reservationID, false)
	readRelayDataReady(t, dataA, reservationID)
	readRelayDataReady(t, dataB, reservationID)

	// 双向持续转发直到超过原始硬到期（≈now+5s）：任何一侧中途被强关都会让读帧失败。
	seq := uint64(1)
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		writeV2DataFrame(t, dataA, &v2.RelayDataFrame{Version: v2.RELAY_V2_VERSION, Kind: &v2.RelayDataFrame_Payload{Payload: &v2.RelayDataPayload{Sequence: seq, EncryptedPayload: []byte("opaque")}}})
		got := readV2DataFrameDeadline(t, dataB, 2*time.Second)
		if got == nil || got.GetClose() != nil {
			t.Fatalf("session closed mid-transfer at seq %d (past original expiry): %+v", seq, got)
		}
		if p := got.GetPayload(); p == nil || p.Sequence != seq {
			t.Fatalf("unexpected frame at seq %d: %+v", seq, got)
		}
		writeV2DataFrame(t, dataB, &v2.RelayDataFrame{Version: v2.RELAY_V2_VERSION, Kind: &v2.RelayDataFrame_Ack{Ack: &v2.RelayDataAck{Sequence: seq}}})
		got = readV2DataFrameDeadline(t, dataA, 2*time.Second)
		if got == nil || got.GetClose() != nil {
			t.Fatalf("session closed mid-transfer awaiting ack at seq %d: %+v", seq, got)
		}
		if a := got.GetAck(); a == nil || a.Sequence != seq {
			t.Fatalf("unexpected frame awaiting ack at seq %d: %+v", seq, got)
		}
		seq++
		time.Sleep(500 * time.Millisecond)
	}
}

// TestRelayDataSlidingExpiryClosesIdleSession 固定滑动窗口下空闲会话仍会被关闭：活跃一段
// 后停止流量，两端应在滑动到期（≈最后 touch + lifetime + grace）时收到 RelayDataClose
// (reason 1)，而不是无限存活。
func TestRelayDataSlidingExpiryClosesIdleSession(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	ctx := context.Background()
	reservationID := hex.EncodeToString(randomBytes(16))
	initiatorToken := randomBytes(32)
	responderToken := randomBytes(32)
	if err := server.cache.CreateReservation(ctx, Reservation{
		ReservationID:     reservationID,
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		RelayDataEndpoint: "wss://" + httpServer.URL + "/v2/relay/" + reservationID,
		InitiatorToken:    initiatorToken,
		ResponderToken:    responderToken,
		ExpiresAtMs:       time.Now().Add(time.Second).UnixMilli(),
		LifetimeS:         1,
	}); err != nil {
		t.Fatal(err)
	}
	dataA := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(initiatorToken))
	defer dataA.Close()
	dataB := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(responderToken))
	defer dataB.Close()
	writeV2DataFrame(t, dataA, &v2.RelayDataFrame{Version: v2.RELAY_V2_VERSION, Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{ReservationId: reservationID, LocalToken: initiatorToken}}})
	waitRelayPending(t, server, reservationID, true)
	writeV2DataFrame(t, dataB, &v2.RelayDataFrame{Version: v2.RELAY_V2_VERSION, Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{ReservationId: reservationID, LocalToken: responderToken}}})
	waitRelayPending(t, server, reservationID, false)
	readRelayDataReady(t, dataA, reservationID)
	readRelayDataReady(t, dataB, reservationID)

	// 先活跃一小段（触发滑动续期），然后彻底空闲。
	writeV2DataFrame(t, dataA, &v2.RelayDataFrame{Version: v2.RELAY_V2_VERSION, Kind: &v2.RelayDataFrame_Payload{Payload: &v2.RelayDataPayload{Sequence: 1, EncryptedPayload: []byte("opaque")}}})
	if got := readV2DataFrameDeadline(t, dataB, 2*time.Second); got == nil || got.GetPayload() == nil {
		t.Fatalf("expected payload, got %+v", got)
	}
	writeV2DataFrame(t, dataB, &v2.RelayDataFrame{Version: v2.RELAY_V2_VERSION, Kind: &v2.RelayDataFrame_Ack{Ack: &v2.RelayDataAck{Sequence: 1}}})
	if got := readV2DataFrameDeadline(t, dataA, 2*time.Second); got == nil || got.GetAck() == nil {
		t.Fatalf("expected ack, got %+v", got)
	}

	// 空闲到滑动到期后：两端都应收到 reason 1（reservation expired）。
	closeA := readV2DataFrameDeadline(t, dataA, 15*time.Second)
	if closeA == nil || closeA.GetClose() == nil || closeA.GetClose().Reason != 1 {
		t.Fatalf("idle session A should close with reason 1, got %+v", closeA)
	}
	closeB := readV2DataFrameDeadline(t, dataB, 5*time.Second)
	if closeB == nil || closeB.GetClose() == nil || closeB.GetClose().Reason != 1 {
		t.Fatalf("idle session B should also close with reason 1, got %+v", closeB)
	}
}

// ---------------------------------------------------------------------------
// 数据面：对端异常关闭必须通知存活端点
// ---------------------------------------------------------------------------

// TestRelayDataPeerNotifiedOnAbnormalClose 固定对端异常关闭必须通知存活端点：A 在不发送
// RelayDataClose 的情况下断开（异常关闭），B 必须在短时间内收到 RelayDataClose(reason 2,
// "relay peer disconnected")，而不是空等到自己滑动窗口到期（修复 #7：read 的 defer 在
// unregister 之前先捕获对端，否则 clearPeer 把 rc.peer 置空后通知分支是死代码）。
func TestRelayDataPeerNotifiedOnAbnormalClose(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	ctx := context.Background()
	reservationID := hex.EncodeToString(randomBytes(16))
	initiatorToken := randomBytes(32)
	responderToken := randomBytes(32)
	if err := server.cache.CreateReservation(ctx, Reservation{
		ReservationID:     reservationID,
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		RelayDataEndpoint: "wss://" + httpServer.URL + "/v2/relay/" + reservationID,
		InitiatorToken:    initiatorToken,
		ResponderToken:    responderToken,
		ExpiresAtMs:       time.Now().Add(time.Minute).UnixMilli(),
		LifetimeS:         15,
	}); err != nil {
		t.Fatal(err)
	}
	dataA := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(initiatorToken))
	defer dataA.Close()
	dataB := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(responderToken))
	defer dataB.Close()
	writeV2DataFrame(t, dataA, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{ReservationId: reservationID, LocalToken: initiatorToken}},
	})
	waitRelayPending(t, server, reservationID, true)
	writeV2DataFrame(t, dataB, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{ReservationId: reservationID, LocalToken: responderToken}},
	})
	waitRelayPending(t, server, reservationID, false)
	readRelayDataReady(t, dataA, reservationID)
	readRelayDataReady(t, dataB, reservationID)

	// A 异常断开（不发送 RelayDataClose）：B 应在短时间内收到 reason 2 通知。
	dataA.Close()
	closeFrame := readV2DataFrameDeadline(t, dataB, 3*time.Second)
	if closeFrame == nil || closeFrame.GetClose() == nil {
		t.Fatalf("peer B should be notified on abnormal close of A, got %+v", closeFrame)
	}
	if closeFrame.GetClose().Reason != 2 || !strings.Contains(closeFrame.GetClose().Detail, "relay peer disconnected") {
		t.Fatalf("expected relay_data_close reason 2 with peer-disconnected detail, got %+v", closeFrame)
	}
}

// ---------------------------------------------------------------------------
// 数据面：晚加入准入与初始窗口走滑动续期（而非名义 ExpiresAtMs）
// ---------------------------------------------------------------------------

// TestRelayDataLateJoinAfterSlidingRenewal 固定晚加入准入与初始到期定时器都走滑动窗口
// （修复 #11）：reservation 被 RenewReservation 滑过名义到期（+宽限）后，晚加入的端点
// 仍必须被 /v2/relay 升级接受（存储 TTL 存活，GetReservation ok），且数据连接拿到全新
// 窗口（refreshTTL）——旧实现既在升级阶段按名义 ExpiresAtMs 拒绝（410），又用陈旧
// ExpiresAtMs 初始化到期定时器把晚加入连接立即以 reason 1 强关。
func TestRelayDataLateJoinAfterSlidingRenewal(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	ctx := context.Background()
	reservationID := hex.EncodeToString(randomBytes(16))
	initiatorToken := randomBytes(32)
	responderToken := randomBytes(32)
	// 名义到期 1s 后（+5s 宽限 ≈ 6s）；LifetimeS=15 给首个端点足够长的存活窗口。
	if err := server.cache.CreateReservation(ctx, Reservation{
		ReservationID:     reservationID,
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		RelayDataEndpoint: "wss://" + httpServer.URL + "/v2/relay/" + reservationID,
		InitiatorToken:    initiatorToken,
		ResponderToken:    responderToken,
		ExpiresAtMs:       time.Now().Add(time.Second).UnixMilli(),
		LifetimeS:         15,
	}); err != nil {
		t.Fatal(err)
	}
	// 首个端点 A 连接并注册（保持 pending，供晚加入的 B 链接）。
	dataA := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(initiatorToken))
	defer dataA.Close()
	writeV2DataFrame(t, dataA, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{ReservationId: reservationID, LocalToken: initiatorToken}},
	})
	waitRelayPending(t, server, reservationID, true)

	// 把存储 TTL 滑到名义到期 + 宽限之后（滑动续期只滑存储 TTL，绝不回写 ExpiresAtMs）。
	if ok, err := server.cache.RenewReservation(ctx, reservationID, 30*time.Second); err != nil || !ok {
		t.Fatalf("renew reservation should slide the storage TTL: ok=%v err=%v", ok, err)
	}

	// 等到名义到期 + 宽限（≈6s）之后晚加入：旧 ExpiresAtMs 准入门此刻会拒绝（410 Gone），
	// 但存储键仍存活，晚加入必须被接受。
	time.Sleep(7 * time.Second)
	dataB := dialRelayData(t, httpServer.URL, reservationID, hex.EncodeToString(responderToken))
	defer dataB.Close()
	writeV2DataFrame(t, dataB, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{ReservationId: reservationID, LocalToken: responderToken}},
	})
	waitRelayPending(t, server, reservationID, false)
	readRelayDataReady(t, dataA, reservationID)
	readRelayDataReady(t, dataB, reservationID)

	// 晚加入的 B 拿到全新窗口：不被陈旧 ExpiresAtMs 的初始定时器立即 reason 1 强关，
	// 数据面可正常转发。
	writeV2DataFrame(t, dataA, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayDataFrame_Payload{Payload: &v2.RelayDataPayload{Sequence: 1, EncryptedPayload: []byte("late-join-ok")}},
	})
	got := readV2DataFrameDeadline(t, dataB, 3*time.Second)
	if got == nil || got.GetClose() != nil {
		t.Fatalf("late-joined data connection must be accepted and functional, got %+v", got)
	}
	if p := got.GetPayload(); p == nil || p.Sequence != 1 || !bytes.Equal(p.EncryptedPayload, []byte("late-join-ok")) {
		t.Fatalf("late-joined B should receive the forwarded payload, got %+v", got)
	}
}

// ---------------------------------------------------------------------------
// 控制面：被取代的连接不得继续分派帧
// ---------------------------------------------------------------------------

// TestControlV2RouteRejectsSupersededPeer 固定 routeControlV2 每帧重核 currency（恢复 v1
// routeControl 的 isCurrent 守卫，修复 #15）：被取代的控制连接在 closePeer 之后仍可能读到
// 一帧在途数据，此时不得再分派 ConnectivityOffer/RelayReserveRequest 等帧——返回 false
// 让 hub.read 关闭这条陈旧连接，而不是让陈旧身份继续对 fleet 施加影响。
func TestControlV2RouteRejectsSupersededPeer(t *testing.T) {
	server, _ := newV2TestServer(t)
	h := server.hub

	// 被取代的旧连接 + 已接管设备的新连接（h.peers 里只保留新连接）。
	stale := injectPeer(h, "device-a")
	injectPeer(h, "device-a")
	// 目标 B 在线：offer 自带显式 target_device_id。
	target := injectPeer(h, "device-b")

	cases := []struct {
		name  string
		frame *v2.RelayFrame
	}{
		{
			name: "connectivity offer",
			frame: &v2.RelayFrame{
				Version: v2.RELAY_V2_VERSION,
				Kind:    &v2.RelayFrame_ConnectivityOffer{ConnectivityOffer: &v2.ConnectivityOffer{RequestId: 1001, AttemptId: strings.Repeat("ab", 16), InitiatorDeviceId: "device-a", TargetDeviceId: "device-b"}},
			},
		},
		{
			name: "relay reserve request",
			frame: &v2.RelayFrame{
				Version: v2.RELAY_V2_VERSION,
				Kind:    &v2.RelayFrame_RelayReserveRequest{RelayReserveRequest: &v2.RelayReserveRequest{RequestId: 1002, AttemptId: strings.Repeat("cd", 16), TargetDeviceId: "device-b"}},
			},
		},
	}
	for _, tc := range cases {
		data, err := v2.EncodeFrame(tc.frame)
		if err != nil {
			t.Fatal(err)
		}
		if h.routeControlV2(stale, data) {
			t.Fatalf("%s: routeControlV2 must reject a superseded peer frame", tc.name)
		}
		select {
		case f := <-target.outbound:
			decoded, derr := v2.DecodeControl(f.data)
			t.Fatalf("%s: superseded peer frame must not be dispatched to the target, got %s (err=%v)", tc.name, v2.KindName(decoded), derr)
		default:
		}
	}
}
