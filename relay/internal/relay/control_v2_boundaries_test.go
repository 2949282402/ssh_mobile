package relay

import (
	"context"
	"encoding/base64"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

func TestValidateV2ClientRequestBoundaries(t *testing.T) {
	tests := []struct {
		name      string
		frame     *v2.RelayFrame
		requestID uint64
		wantErr   bool
	}{
		{name: "nil frame", frame: nil},
		{name: "empty oneof", frame: &v2.RelayFrame{Version: v2.RELAY_V2_VERSION}},
		{
			name:    "heartbeat requires request id",
			frame:   &v2.RelayFrame{Kind: &v2.RelayFrame_Heartbeat{Heartbeat: &v2.Heartbeat{}}},
			wantErr: true,
		},
		{
			name: "heartbeat accepts request id",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_Heartbeat{
				Heartbeat: &v2.Heartbeat{RequestId: 1},
			}},
			requestID: 1,
		},
		{
			name: "discovery publish requires request id",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_DiscoveryPublish{
				DiscoveryPublish: &v2.DiscoveryPublish{},
			}},
			wantErr: true,
		},
		{
			name: "resolve requires request id",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_ResolvePeerRequest{
				ResolvePeerRequest: &v2.ResolvePeerRequest{},
			}},
			wantErr: true,
		},
		{
			name: "offer requires attempt id",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_ConnectivityOffer{
				ConnectivityOffer: &v2.ConnectivityOffer{RequestId: 2},
			}},
			requestID: 2,
			wantErr:   true,
		},
		{
			name: "answer accepts request and attempt",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_ConnectivityAnswer{
				ConnectivityAnswer: &v2.ConnectivityAnswer{RequestId: 3, AttemptId: "attempt-3"},
			}},
			requestID: 3,
		},
		{
			name: "reserve requires attempt id",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_RelayReserveRequest{
				RelayReserveRequest: &v2.RelayReserveRequest{RequestId: 4},
			}},
			requestID: 4,
			wantErr:   true,
		},
		{
			name: "realtime requires request id",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_RealtimeSignal{
				RealtimeSignal: &v2.RealtimeSignal{},
			}},
			wantErr: true,
		},
		{
			name:  "server direction is not a client request",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_Ready{Ready: &v2.Ready{}}},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			requestID, err := validateV2ClientRequest(test.frame)
			if requestID != test.requestID {
				t.Fatalf("request id = %d, want %d", requestID, test.requestID)
			}
			if (err != nil) != test.wantErr {
				t.Fatalf("error = %v, wantErr=%v", err, test.wantErr)
			}
		})
	}
}

func TestDiscoverySnapshotV2ValidationBoundaries(t *testing.T) {
	valid := &v2.DiscoverySnapshot{
		RuntimeEpoch: &v2.RuntimeEpoch{Low: 1},
		Revision:     1,
	}
	tests := []struct {
		name     string
		snapshot *v2.DiscoverySnapshot
		wantErr  bool
	}{
		{name: "valid", snapshot: valid},
		{name: "nil", snapshot: nil, wantErr: true},
		{name: "zero revision", snapshot: &v2.DiscoverySnapshot{RuntimeEpoch: &v2.RuntimeEpoch{Low: 1}}, wantErr: true},
		{name: "missing epoch", snapshot: &v2.DiscoverySnapshot{Revision: 1}, wantErr: true},
		{name: "zero epoch", snapshot: &v2.DiscoverySnapshot{RuntimeEpoch: &v2.RuntimeEpoch{}, Revision: 1}, wantErr: true},
		{
			name: "too many capabilities",
			snapshot: &v2.DiscoverySnapshot{
				RuntimeEpoch:          &v2.RuntimeEpoch{Low: 1},
				Revision:              1,
				TransportCapabilities: make([]v2.TransportCapability, maxDiscoveryCapabilities+1),
			},
			wantErr: true,
		},
		{
			name: "too many candidates",
			snapshot: &v2.DiscoverySnapshot{
				RuntimeEpoch: &v2.RuntimeEpoch{Low: 1},
				Revision:     1,
				CandidateBundle: &v2.CandidateBundle{
					Candidates: make([][]byte, maxDiscoveryCandidates+1),
				},
			},
			wantErr: true,
		},
		{
			name: "oversized candidate",
			snapshot: &v2.DiscoverySnapshot{
				RuntimeEpoch: &v2.RuntimeEpoch{Low: 1},
				Revision:     1,
				CandidateBundle: &v2.CandidateBundle{
					Candidates: [][]byte{make([]byte, maxDiscoveryCandidateBytes+1)},
				},
			},
			wantErr: true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if (validateDiscoverySnapshotV2(test.snapshot) != nil) != test.wantErr {
				t.Fatalf("validation result mismatch for %s", test.name)
			}
		})
	}
}

func TestDiscoveryConversionsPreserveOpaqueAndNumericFields(t *testing.T) {
	updatedAt := time.UnixMilli(123456)
	snapshot := &v2.DiscoverySnapshot{
		RuntimeEpoch:          &v2.RuntimeEpoch{High: 7, Low: 8},
		Revision:              9,
		TransportCapabilities: []v2.TransportCapability{v2.TransportCapability_TRANSPORT_CAPABILITY_TCP},
		CandidateBundle:       &v2.CandidateBundle{Candidates: [][]byte{{0, 1, 2}}},
		PublishedAtMs:         updatedAt.UnixMilli(),
	}
	discovery := discoveryFromV2("device-a", snapshot)
	if discovery.DeviceID != "device-a" || discovery.RuntimeEpochHigh != 7 || discovery.RuntimeEpochLow != 8 || discovery.Revision != 9 {
		t.Fatalf("discovery identity fields not preserved: %+v", discovery)
	}
	if len(discovery.Capabilities) != 1 || discovery.Capabilities[0] != "2" {
		t.Fatalf("capability conversion mismatch: %+v", discovery.Capabilities)
	}
	if len(discovery.Candidates) != 1 || discovery.Candidates[0] != base64.StdEncoding.EncodeToString([]byte{0, 1, 2}) {
		t.Fatalf("candidate conversion mismatch: %+v", discovery.Candidates)
	}
	converted := discoveryToV2(Discovery{
		RuntimeEpochHigh: 7,
		RuntimeEpochLow:  8,
		Revision:         9,
		Capabilities:     []string{"2", "not-a-number", "4294967296"},
		Candidates:       []string{discovery.Candidates[0], "%%%"},
		UpdatedAt:        updatedAt,
	})
	if converted.RuntimeEpoch.High != 7 || converted.RuntimeEpoch.Low != 8 || converted.Revision != 9 || converted.PublishedAtMs != updatedAt.UnixMilli() {
		t.Fatalf("snapshot identity fields not preserved: %+v", converted)
	}
	if len(converted.TransportCapabilities) != 1 || converted.TransportCapabilities[0] != v2.TransportCapability_TRANSPORT_CAPABILITY_TCP {
		t.Fatalf("numeric capability filtering mismatch: %+v", converted.TransportCapabilities)
	}
	if len(converted.CandidateBundle.Candidates) != 1 {
		t.Fatalf("invalid candidate should be filtered: %+v", converted.CandidateBundle)
	}
}

func TestResolveStatusErrorBoundaries(t *testing.T) {
	tests := []struct {
		status  v2.ResolveStatus
		code    v2.ErrorCode
		message string
	}{
		{v2.ResolveStatus_RESOLVE_STATUS_OFFLINE, v2.ErrorCode_ERROR_CODE_PEER_OFFLINE, "target peer is offline"},
		{v2.ResolveStatus_RESOLVE_STATUS_NOT_READY, v2.ErrorCode_ERROR_CODE_PEER_NOT_READY, "target peer is not ready"},
		{v2.ResolveStatus_RESOLVE_STATUS_UNKNOWN, v2.ErrorCode_ERROR_CODE_CONTROL_UNAVAILABLE, "control backend unavailable"},
		{v2.ResolveStatus_RESOLVE_STATUS_READY, v2.ErrorCode_ERROR_CODE_UNSPECIFIED, ""},
		{v2.ResolveStatus(99), v2.ErrorCode_ERROR_CODE_CONTROL_UNAVAILABLE, "control backend returned an unknown resolve status"},
	}
	for _, test := range tests {
		code, message := resolveStatusError(test.status)
		if code != test.code || message != test.message {
			t.Errorf("status %v = (%v, %q), want (%v, %q)", test.status, code, message, test.code, test.message)
		}
	}
}

func TestControlV2ProtocolErrorRoutingBoundaries(t *testing.T) {
	hub := newHub(Config{})
	defer hub.close()
	makePeer := func(deviceID, connectionID string) *peer {
		return &peer{
			deviceID:         deviceID,
			connectionID:     connectionID,
			outbound:         make(chan outboundFrame, 4),
			done:             make(chan struct{}),
			maxPendingFrames: 4,
			maxPendingBytes:  4096,
		}
	}
	initiator := makePeer("initiator", "initiator-1")
	sender := makePeer("target", "target-1")
	hub.mutex.Lock()
	hub.peers[initiator.deviceID] = initiator
	hub.peers[sender.deviceID] = sender
	hub.mutex.Unlock()

	hub.sendV2ProtocolError(sender, 7, v2.ErrorCode_ERROR_CODE_PROTOCOL, "bad request")
	queued := <-sender.outbound
	if queued.messageType != websocket.BinaryMessage {
		t.Fatalf("protocol error message type = %d, want binary", queued.messageType)
	}
	decoded, err := v2.DecodeControl(queued.data)
	if err != nil {
		t.Fatalf("decode protocol error: %v", err)
	}
	if errorFrame := decoded.GetProtocolError(); errorFrame == nil || errorFrame.RequestId != 7 || errorFrame.AttemptId != "" || errorFrame.Message != "bad request" {
		t.Fatalf("protocol error frame = %+v", decoded)
	}
	sender.dequeue(queued)

	hub.sendV2ProtocolErrorWithAttempt(sender, 8, "attempt-1", v2.ErrorCode_ERROR_CODE_PEER_OFFLINE, "offline")
	queued = <-sender.outbound
	decoded, err = v2.DecodeControl(queued.data)
	if err != nil || decoded.GetProtocolError() == nil || decoded.GetProtocolError().AttemptId != "attempt-1" {
		t.Fatalf("attempt-scoped protocol error = %+v, err=%v", decoded, err)
	}
	sender.dequeue(queued)

	hub.mutex.Lock()
	hub.v2Attempts["attempt-1"] = v2Attempt{
		initiator:             initiator.deviceID,
		initiatorConnectionID: initiator.connectionID,
		target:                sender.deviceID,
		targetConnectionID:    sender.connectionID,
		expiresAt:             time.Now().Add(time.Minute),
	}
	hub.mutex.Unlock()
	hub.handleProtocolErrorV2(sender, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_ProtocolError{ProtocolError: &v2.ProtocolError{
			AttemptId: "attempt-1",
			RequestId: 9,
			Code:      v2.ErrorCode_ERROR_CODE_RESOLVE_TIMEOUT,
			Message:   "timeout",
		}},
	})
	routed := <-initiator.outbound
	routedFrame, err := v2.DecodeControl(routed.data)
	if err != nil || routedFrame.GetProtocolError() == nil || routedFrame.GetProtocolError().RequestId != 9 {
		t.Fatalf("routed protocol error = %+v, err=%v", routedFrame, err)
	}
	initiator.dequeue(routed)

	// Missing attempt metadata is ignored, and an expired ticket is removed
	// rather than forwarding a stale error to a reconnected peer.
	hub.handleProtocolErrorV2(sender, &v2.RelayFrame{Version: v2.RELAY_V2_VERSION})
	hub.mutex.Lock()
	hub.v2Attempts["expired"] = v2Attempt{expiresAt: time.Now().Add(-time.Second)}
	hub.mutex.Unlock()
	hub.handleProtocolErrorV2(sender, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_ProtocolError{ProtocolError: &v2.ProtocolError{AttemptId: "expired"}},
	})
	hub.mutex.Lock()
	_, remains := hub.v2Attempts["expired"]
	hub.mutex.Unlock()
	if remains {
		t.Fatal("expired protocol-error attempt was not pruned")
	}

	// A mismatched sender cannot consume the ticket.
	hub.mutex.Lock()
	hub.v2Attempts["mismatch"] = v2Attempt{
		initiator:             initiator.deviceID,
		initiatorConnectionID: initiator.connectionID,
		target:                "another-device",
		targetConnectionID:    sender.connectionID,
		expiresAt:             time.Now().Add(time.Minute),
	}
	hub.mutex.Unlock()
	hub.handleProtocolErrorV2(sender, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_ProtocolError{ProtocolError: &v2.ProtocolError{AttemptId: "mismatch"}},
	})
	select {
	case extra := <-initiator.outbound:
		t.Fatalf("mismatched sender unexpectedly routed frame: %+v", extra)
	default:
	}
}

func TestControlV2HandlerFailureBoundaries(t *testing.T) {
	hub := newHub(Config{})
	defer hub.close()
	makePeer := func(deviceID, connectionID string) *peer {
		return &peer{
			deviceID:         deviceID,
			connectionID:     connectionID,
			outbound:         make(chan outboundFrame, 16),
			done:             make(chan struct{}),
			maxPendingFrames: 16,
			maxPendingBytes:  16 * 1024,
		}
	}
	sender := makePeer("sender", "sender-1")
	target := makePeer("target", "target-1")
	hub.mutex.Lock()
	hub.peers[sender.deviceID] = sender
	hub.peers[target.deviceID] = target
	hub.mutex.Unlock()
	readError := func(p *peer) *v2.ProtocolError {
		t.Helper()
		queued := <-p.outbound
		decoded, err := v2.DecodeControl(queued.data)
		if err != nil {
			t.Fatalf("decode queued control error: %v", err)
		}
		p.dequeue(queued)
		if decoded.GetProtocolError() == nil {
			t.Fatalf("queued frame is not a protocol error: %+v", decoded)
		}
		return decoded.GetProtocolError()
	}

	// A heartbeat without the authoritative presence store must fail closed,
	// and an offer without the preceding Resolve gate must retain its attempt id.
	hub.handleHeartbeatV2(sender, &v2.Heartbeat{RequestId: 1})
	if got := readError(sender); got.Code != v2.ErrorCode_ERROR_CODE_CONTROL_UNAVAILABLE || got.RequestId != 1 {
		t.Fatalf("heartbeat failure = %+v", got)
	}
	hub.handleConnectivityOfferV2(sender, &v2.ConnectivityOffer{RequestId: 2, AttemptId: "attempt-no-resolve"})
	if got := readError(sender); got.Code != v2.ErrorCode_ERROR_CODE_PROTOCOL || got.AttemptId != "attempt-no-resolve" {
		t.Fatalf("ungated offer failure = %+v", got)
	}

	// Realtime signaling rejects self/empty/offline targets and forwards a
	// valid opaque signal without rewriting its payload.
	for requestID, targetID := range map[uint64]string{3: "", 4: "sender", 5: "offline"} {
		hub.handleRealtimeSignalV2(sender, &v2.RealtimeSignal{RequestId: requestID, TargetDeviceId: targetID})
		got := readError(sender)
		if got.RequestId != requestID {
			t.Fatalf("realtime error request id = %d, want %d", got.RequestId, requestID)
		}
		if targetID == "offline" && got.Code != v2.ErrorCode_ERROR_CODE_PEER_OFFLINE {
			t.Fatalf("offline realtime code = %v", got.Code)
		}
	}
	hub.handleRealtimeSignalV2(sender, &v2.RealtimeSignal{RequestId: 6, TargetDeviceId: "target", Payload: []byte("opaque")})
	queued := <-target.outbound
	decoded, err := v2.DecodeControl(queued.data)
	if err != nil || decoded.GetRealtimeSignal() == nil || string(decoded.GetRealtimeSignal().Payload) != "opaque" {
		t.Fatalf("forwarded realtime signal = %+v, err=%v", decoded, err)
	}
	target.dequeue(queued)

	// Discovery publish errors map to a stable revision error after the sender
	// has a valid presence lease but omits the mandatory snapshot revision.
	store := newMemoryStore(Config{})
	hub.presence = store
	if _, _, err := store.TakePresence(context.Background(), sender.deviceID, sender.connectionID, Presence{}, time.Minute); err != nil {
		t.Fatal(err)
	}
	hub.handleDiscoveryPublishV2(sender, &v2.DiscoveryPublish{RequestId: 7})
	if got := readError(sender); got.Code != v2.ErrorCode_ERROR_CODE_REVISION_STALE || got.RequestId != 7 {
		t.Fatalf("invalid discovery publish = %+v", got)
	}
}
