package relay

import (
	"context"
	"testing"
	"time"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

func TestConnectivityOfferResolveGateBoundaries(t *testing.T) {
	store := newMemoryStore(Config{})
	hub := &hub{
		presence:             store,
		peers:                map[string]*peer{},
		v2Attempts:           map[string]v2Attempt{},
		attemptsByConnection: map[string]map[string]struct{}{},
		maxV2Attempts:        1,
		maxV2AttemptsPerConn: 1,
		coordinationTargets:  map[string]coordinationTarget{},
	}
	makePeer := func(deviceID, connectionID string) *peer {
		return &peer{
			deviceID:         deviceID,
			connectionID:     connectionID,
			outbound:         make(chan outboundFrame, 8),
			done:             make(chan struct{}),
			maxPendingFrames: 8,
			maxPendingBytes:  64 * 1024,
		}
	}
	sender := makePeer("sender", "sender-conn")
	target := makePeer("target", "target-conn")
	hub.peers[sender.deviceID] = sender
	hub.peers[target.deviceID] = target
	readFrame := func(t *testing.T, p *peer) *v2.RelayFrame {
		t.Helper()
		queued := <-p.outbound
		defer p.dequeue(queued)
		frame, err := v2.DecodeControl(queued.data)
		if err != nil {
			t.Fatalf("decode queued control frame: %v", err)
		}
		return frame
	}
	readError := func(t *testing.T, p *peer) *v2.ProtocolError {
		t.Helper()
		frame := readFrame(t, p)
		if frame.GetProtocolError() == nil {
			t.Fatalf("expected protocol error frame, got %+v", frame)
		}
		return frame.GetProtocolError()
	}
	ready := func(deviceID, connectionID string, epoch uint64) {
		t.Helper()
		if _, _, err := store.TakePresence(context.Background(), deviceID, connectionID, Presence{}, time.Minute); err != nil {
			t.Fatal(err)
		}
		if err := store.TakeDiscovery(context.Background(), deviceID, connectionID, Discovery{
			DeviceID: deviceID, ConnectionID: connectionID, Revision: 1, RuntimeEpochLow: epoch,
		}, time.Minute); err != nil {
			t.Fatal(err)
		}
	}

	// A target-less offer is rejected before any backend lookup when Resolve was
	// not performed on this authenticated control connection.
	hub.handleConnectivityOfferV2(sender, &v2.ConnectivityOffer{RequestId: 1, AttemptId: "no-resolve"})
	if got := readError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PROTOCOL || got.AttemptId != "no-resolve" {
		t.Fatalf("ungated offer = %+v", got)
	}

	// The resolve gate rejects a self target, and an initiator without a READY
	// discovery cannot make the relay forward client-supplied candidates.
	hub.rememberCoordinationTarget(sender, sender.deviceID)
	hub.handleConnectivityOfferV2(sender, &v2.ConnectivityOffer{RequestId: 2, AttemptId: "self-target"})
	if got := readError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PROTOCOL {
		t.Fatalf("self-target offer = %+v", got)
	}
	hub.rememberCoordinationTarget(sender, target.deviceID)
	hub.handleConnectivityOfferV2(sender, &v2.ConnectivityOffer{RequestId: 3, AttemptId: "offline-sender"})
	if got := readError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PEER_OFFLINE {
		t.Fatalf("offline sender offer = %+v", got)
	}

	ready(sender.deviceID, sender.connectionID, 1)
	// Target presence without a published discovery is NOT_READY, not offline.
	if _, _, err := store.TakePresence(context.Background(), target.deviceID, target.connectionID, Presence{}, time.Minute); err != nil {
		t.Fatal(err)
	}
	hub.rememberCoordinationTarget(sender, target.deviceID)
	hub.handleConnectivityOfferV2(sender, &v2.ConnectivityOffer{RequestId: 4, AttemptId: "not-ready-target"})
	if got := readError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PEER_NOT_READY {
		t.Fatalf("not-ready target offer = %+v", got)
	}

	ready(target.deviceID, target.connectionID, 2)
	validAttempt := "valid-offer"
	hub.rememberCoordinationTarget(sender, target.deviceID)
	hub.handleConnectivityOfferV2(sender, &v2.ConnectivityOffer{
		RequestId:         5,
		AttemptId:         validAttempt,
		InitiatorDeviceId: "spoofed-device",
	})
	forwarded := readFrame(t, target)
	offer := forwarded.GetConnectivityOffer()
	if offer == nil || offer.InitiatorDeviceId != sender.deviceID || offer.InitiatorSnapshot == nil || offer.InitiatorSnapshot.Revision != 1 {
		t.Fatalf("forwarded offer = %+v", forwarded)
	}
	if _, present := hub.v2Attempts[validAttempt]; !present {
		t.Fatal("valid offer did not create an attempt ticket")
	}

	// Attempt IDs are one-shot correlation keys while live; reuse is rejected.
	hub.rememberCoordinationTarget(sender, target.deviceID)
	hub.handleConnectivityOfferV2(sender, &v2.ConnectivityOffer{RequestId: 6, AttemptId: validAttempt})
	if got := readError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PROTOCOL {
		t.Fatalf("duplicate attempt offer = %+v", got)
	}

	// A different live attempt cannot displace the first ticket when either the
	// global or per-connection capacity is full.
	hub.rememberCoordinationTarget(sender, target.deviceID)
	hub.handleConnectivityOfferV2(sender, &v2.ConnectivityOffer{RequestId: 61, AttemptId: "over-capacity"})
	if got := readError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_RATE_LIMITED {
		t.Fatalf("attempt capacity error = %+v", got)
	}

	// A target that disappears after Resolve is reported as offline rather than
	// leaving a dangling attempt ticket. Disconnect also removes every attempt
	// indexed by the exact connection rather than waiting for the minute sweep.
	if !hub.disconnectConnection(target.deviceID, target.connectionID) {
		t.Fatal("target disconnect was not applied")
	}
	if _, present := hub.v2Attempts[validAttempt]; present {
		t.Fatal("target disconnect left its live attempt ticket")
	}
	hub.rememberCoordinationTarget(sender, target.deviceID)
	hub.handleConnectivityOfferV2(sender, &v2.ConnectivityOffer{RequestId: 7, AttemptId: "target-gone"})
	if got := readError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PEER_OFFLINE {
		t.Fatalf("disconnected target offer = %+v", got)
	}
	if _, present := hub.v2Attempts["target-gone"]; present {
		t.Fatal("disconnected target left a dangling attempt ticket")
	}
}
