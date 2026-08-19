package relay

import (
	"testing"

	"github.com/gorilla/websocket"
)

func testRelayDataConnForRegistry(id, device string, role relayDataRole) *relayDataConn {
	return &relayDataConn{
		reservationID:    id,
		deviceID:         device,
		role:             role,
		outbound:         make(chan outboundFrame, 8),
		done:             make(chan struct{}),
		writeDone:        make(chan struct{}),
		maxPendingFrames: 8,
		maxPendingBytes:  4096,
	}
}

func TestRelayDataRegistryRejectsDuplicateRoleAndConsumesPair(t *testing.T) {
	registry := newRelayDataRegistry()
	initiator := testRelayDataConnForRegistry("reservation-a", "device-a", relayDataRoleInitiator)
	duplicate := testRelayDataConnForRegistry("reservation-a", "device-a", relayDataRoleInitiator)
	responder := testRelayDataConnForRegistry("reservation-a", "device-b", relayDataRoleResponder)

	if _, _, ok := registry.register(initiator); !ok {
		t.Fatal("first role should be admitted")
	}
	if _, _, ok := registry.register(duplicate); ok {
		t.Fatal("duplicate role must be rejected")
	}
	peer, _, ok := registry.register(responder)
	if !ok || peer != initiator {
		t.Fatalf("matching opposite role should pair, peer=%p ok=%v", peer, ok)
	}
	if !initiator.ready.Load() || !responder.ready.Load() || !initiator.paired.Load() {
		t.Fatal("paired endpoints must be Ready and paired")
	}
	if _, _, ok := registry.register(testRelayDataConnForRegistry("reservation-a", "device-a", relayDataRoleInitiator)); ok {
		t.Fatal("consumed reservation must reject replayed role token")
	}

	// PairReady is the sole setup signal and is queued through the same
	// writer-owned outbound channel as all later control/data frames.
	if frame := <-initiator.outbound; frame.messageType != websocket.PingMessage {
		t.Fatalf("first queued frame must be PairReady Ping, got %d", frame.messageType)
	}
}
