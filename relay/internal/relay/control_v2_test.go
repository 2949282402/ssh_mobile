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
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
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
		SessionTTL:      time.Minute,
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
	kind, data, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read v2 control frame: %v", err)
	}
	if kind != websocket.BinaryMessage {
		t.Fatalf("expected binary control frame, got message type %d", kind)
	}
	frame, err := v2.DecodeControl(data)
	if err != nil {
		t.Fatalf("decode v2 control frame: %v", err)
	}
	return frame
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

// waitRelayPending 轮询 relayDataRegistry 的 pending 表，直到 reservationID 是否
// 在 pending 中与 want 一致（true=第一端点已登记，false=两端点已链接并移出 pending）。
func waitRelayPending(t *testing.T, server *Server, reservationID string, want bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		server.relayData.mutex.Lock()
		_, present := server.relayData.pending[reservationID]
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

	// device-a 广播一条 advisory PeerAvailableHint → device-b 收到。
	writeV2ControlFrame(t, connA, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_PeerAvailableHint{PeerAvailableHint: &v2.PeerAvailableHint{
			DeviceId: "device-a", RuntimeEpoch: &v2.RuntimeEpoch{High: 1}, Revision: 9,
		}},
	})
	hint = readV2ControlFrame(t, connB)
	if hint.GetPeerAvailableHint() == nil || hint.GetPeerAvailableHint().DeviceId != "device-a" {
		t.Fatalf("device-b expected broadcast peer_available_hint, got %+v", hint)
	}
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

	// A resolve B（记录 A 的 lastResolveTarget，ConnectivityOffer 据此路由）。
	writeV2ControlFrame(t, connA, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_ResolvePeerRequest{ResolvePeerRequest: &v2.ResolvePeerRequest{
			RequestId: 1002, TargetDeviceId: "device-b",
		}},
	})
	if resp := readV2ControlFrame(t, connA); resp.GetResolvePeerResponse() == nil {
		t.Fatalf("expected resolve response, got %+v", resp)
	}

	// A 向 B（A 最近 resolve 的 target）发 ConnectivityOffer。
	attemptID := "a1b2c3d4e5f60718293a4b5c6d7e8f90"
	writeV2ControlFrame(t, connA, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_ConnectivityOffer{ConnectivityOffer: &v2.ConnectivityOffer{
			RequestId:         1003,
			AttemptId:         attemptID,
			InitiatorDeviceId: "device-a",
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

	writeV2ControlFrame(t, connA, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_RealtimeSignal{RealtimeSignal: &v2.RealtimeSignal{
			RequestId:      1001,
			RealtimeId:     "rt-1234",
			TargetDeviceId: "device-b",
			Kind:           v2.RealtimeSignalKind_REALTIME_SIGNAL_KIND_OFFER,
			Revision:       1,
			Payload:        []byte("sdp-offer"),
		}},
	})
	sig := readV2ControlFrame(t, connB)
	rs := sig.GetRealtimeSignal()
	if rs == nil || rs.TargetDeviceId != "device-b" || rs.Kind != v2.RealtimeSignalKind_REALTIME_SIGNAL_KIND_OFFER || !bytes.Equal(rs.Payload, []byte("sdp-offer")) {
		t.Fatalf("device-b expected realtime_signal, got %+v", sig)
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
