package relay

import (
	"testing"

	"github.com/gorilla/websocket"
)

func testRelayDataConnForRegistry(id, device string, role relayDataRole) *relayDataConn {
	return &relayDataConn{
		reservationID: id,
		deviceID:      device,
		role:          role,
		outbound:      make(chan outboundFrame, 8),
		done:          make(chan struct{}),
		writeDone:     make(chan struct{}),
		flow: relayDataFlowBudget{
			maxPendingFrames: 8,
			maxPendingBytes:  4096,
		},
	}
}

func TestRelayDataRegistryRejectsDuplicateRoleAndConsumesPair(t *testing.T) {
	registry := newRelayDataRegistry()
	initiator := testRelayDataConnForRegistry("reservation-a", "device-a", relayDataRoleInitiator)
	duplicate := testRelayDataConnForRegistry("reservation-a", "device-a", relayDataRoleInitiator)
	responder := testRelayDataConnForRegistry("reservation-a", "device-b", relayDataRoleResponder)

	if _, ok := registry.admitEndpoint(initiator); !ok {
		t.Fatal("first role should be admitted")
	}
	if _, ok := registry.admitEndpoint(duplicate); ok {
		t.Fatal("duplicate role must be rejected")
	}
	peer, ok := registry.admitEndpoint(responder)
	if !ok || peer != initiator {
		t.Fatalf("matching opposite role should pair, peer=%p ok=%v", peer, ok)
	}
	if !initiator.ready.Load() || !responder.ready.Load() || !initiator.paired.Load() {
		t.Fatal("paired endpoints must be Ready and paired")
	}
	if _, ok := registry.admitEndpoint(testRelayDataConnForRegistry("reservation-a", "device-a", relayDataRoleInitiator)); ok {
		t.Fatal("consumed reservation must reject replayed role token")
	}

	// PairReady is the sole setup signal and is queued through the same
	// writer-owned outbound channel as all later control/data frames.
	if frame := <-initiator.outbound; frame.messageType != websocket.PingMessage {
		t.Fatalf("first queued frame must be PairReady Ping, got %d", frame.messageType)
	}
}
