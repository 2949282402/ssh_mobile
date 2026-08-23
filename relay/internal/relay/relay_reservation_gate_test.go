package relay

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

func authorizeRelayReservationForTest(t *testing.T, h *hub, sender, target *peer, attemptID string) {
	t.Helper()
	h.mutex.Lock()
	now := time.Now()
	added := h.reservationGates.add(attemptID, relayReservationGate{
		initiatorDeviceID:     sender.deviceID,
		initiatorConnectionID: sender.connectionID,
		targetDeviceID:        target.deviceID,
		targetConnectionID:    target.connectionID,
		expiresAt:             now.Add(v2AttemptLifetime),
	}, now)
	h.mutex.Unlock()
	if !added {
		t.Fatalf("failed to authorize relay reservation attempt %q", attemptID)
	}
}

func newRelayReservationGateHub(t *testing.T) (*hub, *memoryStore, *peer, *peer, *peer) {
	t.Helper()
	h := newHub(Config{Address: ":8080", InstanceID: "reservation-gate-test"})
	t.Cleanup(h.close)
	store := newMemoryStore(Config{})
	h.presence = store
	sender := injectPeer(h, "reservation-initiator")
	target := injectPeer(h, "reservation-target")
	other := injectPeer(h, "reservation-other")
	for index, p := range []*peer{sender, target, other} {
		if _, _, err := store.TakePresence(context.Background(), p.deviceID, p.connectionID, Presence{
			InstanceID: h.instanceID, ConnectionID: p.connectionID,
		}, time.Minute); err != nil {
			t.Fatal(err)
		}
		if err := store.TakeDiscovery(context.Background(), p.deviceID, p.connectionID, Discovery{
			DeviceID: p.deviceID, ConnectionID: p.connectionID,
			RuntimeEpochHigh: 1, RuntimeEpochLow: uint64(index + 1), Revision: 1,
		}, time.Minute); err != nil {
			t.Fatal(err)
		}
	}
	return h, store, sender, target, other
}

func forwardOfferForRelayReservationTest(t *testing.T, h *hub, sender, target *peer, attemptID string) {
	t.Helper()
	h.rememberCoordinationTarget(sender, target.deviceID)
	h.handleConnectivityOfferV2(sender, &v2.ConnectivityOffer{RequestId: 1, AttemptId: attemptID})
	forwarded := readV2ControlFrameFromPeer(t, target).GetConnectivityOffer()
	if forwarded == nil || forwarded.AttemptId != attemptID {
		t.Fatalf("target did not receive connectivity offer %q: %+v", attemptID, forwarded)
	}
}

func assertRelayReservationGateIndexesEmpty(t *testing.T, h *hub) {
	t.Helper()
	h.mutex.Lock()
	gates := len(h.reservationGates.gates)
	reverse := len(h.reservationGates.byConnection)
	expiryHeap := len(h.reservationGates.expiries.heap)
	expiryKeys := len(h.reservationGates.expiries.byKey)
	h.mutex.Unlock()
	if gates != 0 || reverse != 0 || expiryHeap != 0 || expiryKeys != 0 {
		t.Fatalf("reservation gate indexes retained state: gates=%d reverse=%d expiry_heap=%d expiry_keys=%d",
			gates, reverse, expiryHeap, expiryKeys)
	}
}

func assertConnectivityOfferIndexesEmpty(t *testing.T, h *hub) {
	t.Helper()
	h.mutex.Lock()
	attempts := len(h.v2Attempts)
	attemptReverse := len(h.attemptsByConnection)
	attemptExpiryHeap := len(h.v2AttemptExpiries.heap)
	attemptExpiryKeys := len(h.v2AttemptExpiries.byKey)
	gates := len(h.reservationGates.gates)
	gateReverse := len(h.reservationGates.byConnection)
	gateExpiryHeap := len(h.reservationGates.expiries.heap)
	gateExpiryKeys := len(h.reservationGates.expiries.byKey)
	h.mutex.Unlock()
	if attempts != 0 || attemptReverse != 0 || attemptExpiryHeap != 0 || attemptExpiryKeys != 0 ||
		gates != 0 || gateReverse != 0 || gateExpiryHeap != 0 || gateExpiryKeys != 0 {
		t.Fatalf("connectivity offer indexes retained state: attempts=%d attempt_reverse=%d attempt_expiry_heap=%d attempt_expiry_keys=%d gates=%d gate_reverse=%d gate_expiry_heap=%d gate_expiry_keys=%d",
			attempts, attemptReverse, attemptExpiryHeap, attemptExpiryKeys,
			gates, gateReverse, gateExpiryHeap, gateExpiryKeys)
	}
}

func assertConnectivityOfferAttemptAbsent(t *testing.T, h *hub, sender, target *peer, attemptID string) {
	t.Helper()
	gateKey := relayReservationGateKey{initiatorConnectionID: sender.connectionID, attemptID: attemptID}
	h.mutex.Lock()
	_, attemptPresent := h.v2Attempts[attemptID]
	_, attemptExpiryPresent := h.v2AttemptExpiries.byKey[attemptID]
	_, initiatorAttemptRef := h.attemptsByConnection[sender.connectionID][attemptID]
	_, targetAttemptRef := h.attemptsByConnection[target.connectionID][attemptID]
	_, gatePresent := h.reservationGates.gates[gateKey]
	_, gateExpiryPresent := h.reservationGates.expiries.byKey[gateKey]
	_, initiatorGateRef := h.reservationGates.byConnection[sender.connectionID][gateKey]
	_, targetGateRef := h.reservationGates.byConnection[target.connectionID][gateKey]
	attemptHeapPresent := false
	for _, entry := range h.v2AttemptExpiries.heap {
		if entry != nil && entry.key == attemptID {
			attemptHeapPresent = true
			break
		}
	}
	gateHeapPresent := false
	for _, entry := range h.reservationGates.expiries.heap {
		if entry != nil && entry.key == gateKey {
			gateHeapPresent = true
			break
		}
	}
	h.mutex.Unlock()
	if attemptPresent || attemptExpiryPresent || initiatorAttemptRef || targetAttemptRef || attemptHeapPresent ||
		gatePresent || gateExpiryPresent || initiatorGateRef || targetGateRef || gateHeapPresent {
		t.Fatalf("failed offer attempt %q retained indexes: attempt=%v attempt_expiry=%v initiator_attempt_ref=%v target_attempt_ref=%v attempt_heap=%v gate=%v gate_expiry=%v initiator_gate_ref=%v target_gate_ref=%v gate_heap=%v",
			attemptID, attemptPresent, attemptExpiryPresent, initiatorAttemptRef, targetAttemptRef, attemptHeapPresent,
			gatePresent, gateExpiryPresent, initiatorGateRef, targetGateRef, gateHeapPresent)
	}
}

func TestRelayReservationGateBindsForwardedAttemptToControlConnection(t *testing.T) {
	h, store, sender, target, other := newRelayReservationGateHub(t)

	// Authentication alone is not reservation authority.
	h.handleRelayReserveRequestV2(sender, &v2.RelayReserveRequest{
		RequestId: 1, AttemptId: "ungated-attempt", TargetDeviceId: target.deviceID,
	})
	if got := boundaryReadProtocolError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PROTOCOL {
		t.Fatalf("ungated reservation error=%+v", got)
	}

	attemptID := "forwarded-answer-attempt"
	forwardOfferForRelayReservationTest(t, h, sender, target, attemptID)

	// A different authenticated connection cannot consume the gate by guessing
	// the attempt_id and target.
	h.handleRelayReserveRequestV2(other, &v2.RelayReserveRequest{
		RequestId: 2, AttemptId: attemptID, TargetDeviceId: target.deviceID,
	})
	if got := boundaryReadProtocolError(t, other); got.Code != v2.ErrorCode_ERROR_CODE_PROTOCOL {
		t.Fatalf("guessed reservation error=%+v", got)
	}
	h.mutex.Lock()
	gateCount := len(h.reservationGates.gates)
	h.mutex.Unlock()
	if gateCount != 1 {
		t.Fatalf("foreign connection consumed reservation gate, count=%d", gateCount)
	}

	// Answer routing has its own one-shot state. Consuming that state must leave
	// the independent reservation fallback gate intact.
	h.handleConnectivityAnswerV2(target, &v2.ConnectivityAnswer{
		RequestId: 3, AttemptId: attemptID, Accepted: false,
	})
	if got := readV2ControlFrameFromPeer(t, sender).GetConnectivityAnswer(); got == nil || got.AttemptId != attemptID {
		t.Fatalf("answer did not route before relay fallback: %+v", got)
	}
	h.mutex.Lock()
	_, attemptStillPresent := h.v2Attempts[attemptID]
	gateCount = len(h.reservationGates.gates)
	h.mutex.Unlock()
	if attemptStillPresent || gateCount != 1 {
		t.Fatalf("answer/gate lifetimes were coupled: attempt=%v gates=%d", attemptStillPresent, gateCount)
	}

	h.handleRelayReserveRequestV2(sender, &v2.RelayReserveRequest{
		RequestId: 4, AttemptId: attemptID, TargetDeviceId: target.deviceID, DesiredLifetimeS: 15,
	})
	incoming := readV2ControlFrameFromPeer(t, target).GetIncomingRelayReservation()
	response := readV2ControlFrameFromPeer(t, sender).GetRelayReserveResponse()
	if incoming == nil || response == nil || incoming.AttemptId != attemptID || response.AttemptId != attemptID || incoming.ReservationId != response.ReservationId {
		t.Fatalf("authorized reservation was not delivered: incoming=%+v response=%+v", incoming, response)
	}
	if _, ok, err := store.GetReservation(context.Background(), response.ReservationId); err != nil || !ok {
		t.Fatalf("authorized reservation missing from store: ok=%v err=%v", ok, err)
	}
	assertRelayReservationGateIndexesEmpty(t, h)

	// The gate is consumed before storage work, so replay cannot mint a second
	// reservation even on the same authenticated connection.
	h.handleRelayReserveRequestV2(sender, &v2.RelayReserveRequest{
		RequestId: 5, AttemptId: attemptID, TargetDeviceId: target.deviceID,
	})
	if got := boundaryReadProtocolError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PROTOCOL {
		t.Fatalf("replayed reservation error=%+v", got)
	}
}

func TestRelayReservationGateDoesNotConsumeProtocolErrorRouting(t *testing.T) {
	h, _, sender, target, _ := newRelayReservationGateHub(t)
	attemptID := "forwarded-error-attempt"
	forwardOfferForRelayReservationTest(t, h, sender, target, attemptID)

	protocolError := &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayFrame_ProtocolError{ProtocolError: &v2.ProtocolError{
			RequestId: 6, AttemptId: attemptID, Code: v2.ErrorCode_ERROR_CODE_PEER_NOT_READY,
		}},
	}
	h.handleProtocolErrorV2(target, protocolError)
	if got := readV2ControlFrameFromPeer(t, sender).GetProtocolError(); got == nil || got.AttemptId != attemptID {
		t.Fatalf("attempt-scoped protocol error did not route: %+v", got)
	}
	h.handleProtocolErrorV2(target, protocolError)
	assertNoOutbound(t, sender)

	// The one-shot return route is gone, but the separately authorized Relay
	// fallback remains available exactly once.
	h.handleRelayReserveRequestV2(sender, &v2.RelayReserveRequest{
		RequestId: 7, AttemptId: attemptID, TargetDeviceId: target.deviceID,
	})
	if got := readV2ControlFrameFromPeer(t, target).GetIncomingRelayReservation(); got == nil || got.AttemptId != attemptID {
		t.Fatalf("reservation after routed protocol error missing: %+v", got)
	}
	if got := readV2ControlFrameFromPeer(t, sender).GetRelayReserveResponse(); got == nil || got.AttemptId != attemptID {
		t.Fatalf("reservation response after routed protocol error missing: %+v", got)
	}
}

func TestRelayReservationConsumptionPreservesOneShotAttemptReturnRouting(t *testing.T) {
	for _, responseKind := range []string{"answer", "protocol error"} {
		t.Run(responseKind, func(t *testing.T) {
			h, _, sender, target, _ := newRelayReservationGateHub(t)
			attemptID := "reserve-before-answer"
			if responseKind == "protocol error" {
				attemptID = "reserve-before-protocol-error"
			}
			forwardOfferForRelayReservationTest(t, h, sender, target, attemptID)
			h.handleRelayReserveRequestV2(sender, &v2.RelayReserveRequest{
				RequestId: 8, AttemptId: attemptID, TargetDeviceId: target.deviceID,
			})
			if got := readV2ControlFrameFromPeer(t, target).GetIncomingRelayReservation(); got == nil {
				t.Fatalf("target did not receive reservation before %s: %+v", responseKind, got)
			}
			if got := readV2ControlFrameFromPeer(t, sender).GetRelayReserveResponse(); got == nil {
				t.Fatalf("initiator did not receive reservation before %s: %+v", responseKind, got)
			}

			switch responseKind {
			case "answer":
				answer := &v2.ConnectivityAnswer{RequestId: 9, AttemptId: attemptID, Accepted: false}
				h.handleConnectivityAnswerV2(target, answer)
				if got := readV2ControlFrameFromPeer(t, sender).GetConnectivityAnswer(); got == nil || got.AttemptId != attemptID {
					t.Fatalf("answer route was consumed by reservation: %+v", got)
				}
				h.handleConnectivityAnswerV2(target, answer)
			case "protocol error":
				frame := &v2.RelayFrame{Version: v2.RELAY_V2_VERSION, Kind: &v2.RelayFrame_ProtocolError{ProtocolError: &v2.ProtocolError{
					RequestId: 9, AttemptId: attemptID, Code: v2.ErrorCode_ERROR_CODE_PEER_NOT_READY,
				}}}
				h.handleProtocolErrorV2(target, frame)
				if got := readV2ControlFrameFromPeer(t, sender).GetProtocolError(); got == nil || got.AttemptId != attemptID {
					t.Fatalf("protocol error route was consumed by reservation: %+v", got)
				}
				h.handleProtocolErrorV2(target, frame)
			}
			assertNoOutbound(t, sender)
		})
	}
}

func TestRelayReservationGateRejectsMismatchedTargetAndConsumesAuthorization(t *testing.T) {
	h, _, sender, target, other := newRelayReservationGateHub(t)
	attemptID := "target-bound-attempt"
	forwardOfferForRelayReservationTest(t, h, sender, target, attemptID)

	h.handleRelayReserveRequestV2(sender, &v2.RelayReserveRequest{
		RequestId: 8, AttemptId: attemptID, TargetDeviceId: other.deviceID,
	})
	if got := boundaryReadProtocolError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PROTOCOL {
		t.Fatalf("mismatched reservation target error=%+v", got)
	}
	h.mutex.Lock()
	remaining := len(h.reservationGates.gates)
	h.mutex.Unlock()
	if remaining != 0 {
		t.Fatalf("mismatched target retained one-shot gate: %d", remaining)
	}

	// Correcting the target cannot replay the already-consumed authorization.
	h.handleRelayReserveRequestV2(sender, &v2.RelayReserveRequest{
		RequestId: 9, AttemptId: attemptID, TargetDeviceId: target.deviceID,
	})
	if got := boundaryReadProtocolError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PROTOCOL {
		t.Fatalf("corrected replay error=%+v", got)
	}
	assertNoOutbound(t, target)
	assertNoOutbound(t, other)
}

func TestRelayReservationGateLifecycleIsBoundedAndDisconnectSafe(t *testing.T) {
	t.Run("replaced initiator cannot publish gate", func(t *testing.T) {
		h, _, sender, target, _ := newRelayReservationGateHub(t)
		replacement := boundaryHeartbeatPeer(sender.deviceID)
		replacement.connectionID = "conn-reservation-initiator-replacement"
		h.mutex.Lock()
		h.peers[sender.deviceID] = replacement
		h.mutex.Unlock()
		h.rememberCoordinationTarget(sender, target.deviceID)
		h.handleConnectivityOfferV2(sender, &v2.ConnectivityOffer{
			RequestId: 6, AttemptId: "replaced-initiator",
		})
		assertNoOutbound(t, target)
		h.mutex.Lock()
		gates := len(h.reservationGates.gates)
		attempts := len(h.v2Attempts)
		h.mutex.Unlock()
		if gates != 0 || attempts != 0 {
			t.Fatalf("replaced initiator published control state: gates=%d attempts=%d", gates, attempts)
		}
	})

	t.Run("replaced target requires a fresh ready owner", func(t *testing.T) {
		h, _, sender, target, _ := newRelayReservationGateHub(t)
		replacement := boundaryHeartbeatPeer(target.deviceID)
		replacement.connectionID = "conn-reservation-target-replacement"
		h.mutex.Lock()
		h.peers[target.deviceID] = replacement
		h.mutex.Unlock()

		h.rememberCoordinationTarget(sender, target.deviceID)
		h.handleConnectivityOfferV2(sender, &v2.ConnectivityOffer{
			RequestId: 7, AttemptId: "replaced-target",
		})
		if got := boundaryReadProtocolError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PEER_OFFLINE {
			t.Fatalf("replaced target offer error=%+v", got)
		}
		assertNoOutbound(t, target)
		assertNoOutbound(t, replacement)
		assertConnectivityOfferIndexesEmpty(t, h)
	})

	t.Run("failed offer enqueue", func(t *testing.T) {
		h, _, sender, target, _ := newRelayReservationGateHub(t)
		for i := 0; i < cap(target.outbound); i++ {
			target.outbound <- outboundFrame{}
		}
		h.rememberCoordinationTarget(sender, target.deviceID)
		h.handleConnectivityOfferV2(sender, &v2.ConnectivityOffer{
			RequestId: 7, AttemptId: "offer-enqueue-failed",
		})
		if got := boundaryReadProtocolError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PEER_OFFLINE {
			t.Fatalf("failed offer enqueue error=%+v", got)
		}
		select {
		case <-target.done:
		default:
			t.Fatal("failed offer enqueue did not close the exact backpressured target")
		}
		assertConnectivityOfferAttemptAbsent(t, h, sender, target, "offer-enqueue-failed")
		assertConnectivityOfferIndexesEmpty(t, h)
	})

	t.Run("expired", func(t *testing.T) {
		h, _, sender, target, _ := newRelayReservationGateHub(t)
		attemptID := "expired-reservation-gate"
		forwardOfferForRelayReservationTest(t, h, sender, target, attemptID)
		h.mutex.Lock()
		key := relayReservationGateKey{initiatorConnectionID: sender.connectionID, attemptID: attemptID}
		gate := h.reservationGates.gates[key]
		gate.expiresAt = time.Now().Add(-time.Second)
		h.reservationGates.gates[key] = gate
		h.mutex.Unlock()

		h.handleRelayReserveRequestV2(sender, &v2.RelayReserveRequest{
			RequestId: 8, AttemptId: attemptID, TargetDeviceId: target.deviceID,
		})
		if got := boundaryReadProtocolError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PROTOCOL {
			t.Fatalf("expired reservation gate error=%+v", got)
		}
		h.mutex.Lock()
		remaining := len(h.reservationGates.gates)
		h.mutex.Unlock()
		if remaining != 0 {
			t.Fatalf("expired reservation gate retained: %d", remaining)
		}
	})

	for _, endpoint := range []string{"initiator", "target"} {
		t.Run(endpoint+" disconnect", func(t *testing.T) {
			h, _, sender, target, _ := newRelayReservationGateHub(t)
			attemptID := "disconnect-" + endpoint
			forwardOfferForRelayReservationTest(t, h, sender, target, attemptID)
			peerToDisconnect := sender
			if endpoint == "target" {
				peerToDisconnect = target
			}
			if !h.disconnectConnection(peerToDisconnect.deviceID, peerToDisconnect.connectionID) {
				t.Fatal("expected bound control connection to disconnect")
			}
			h.mutex.Lock()
			gates := len(h.reservationGates.gates)
			attempts := len(h.v2Attempts)
			reverse := len(h.reservationGates.byConnection)
			attemptExpiries := len(h.v2AttemptExpiries.heap)
			gateExpiries := len(h.reservationGates.expiries.heap)
			h.mutex.Unlock()
			if gates != 0 || attempts != 0 || reverse != 0 || attemptExpiries != 0 || gateExpiries != 0 {
				t.Fatalf("disconnect retained control attempt state: gates=%d attempts=%d reverse=%d attempt_expiries=%d gate_expiries=%d",
					gates, attempts, reverse, attemptExpiries, gateExpiries)
			}
		})
	}

	t.Run("capacity", func(t *testing.T) {
		h, _, sender, target, _ := newRelayReservationGateHub(t)
		h.reservationGates.maxTotal = 1
		h.reservationGates.maxPerConn = 1
		forwardOfferForRelayReservationTest(t, h, sender, target, "capacity-first")
		h.rememberCoordinationTarget(sender, target.deviceID)
		h.handleConnectivityOfferV2(sender, &v2.ConnectivityOffer{RequestId: 9, AttemptId: "capacity-second"})
		if got := boundaryReadProtocolError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_RATE_LIMITED {
			t.Fatalf("bounded reservation gate error=%+v", got)
		}
		assertNoOutbound(t, target)
		h.mutex.Lock()
		gates := len(h.reservationGates.gates)
		attempts := len(h.v2Attempts)
		h.mutex.Unlock()
		if gates != 1 || attempts != 1 {
			t.Fatalf("capacity rejection changed live state: gates=%d attempts=%d", gates, attempts)
		}
		assertConnectivityOfferAttemptAbsent(t, h, sender, target, "capacity-second")
	})
}

func TestConnectivityOfferExpiryIndexesBoundHotPathAndReleaseCapacity(t *testing.T) {
	addState := func(t *testing.T, h *hub, attemptID, initiatorConnectionID, targetConnectionID string, insertedAt, expiresAt time.Time) {
		t.Helper()
		attempt := v2Attempt{
			initiator:             "historical-initiator",
			initiatorConnectionID: initiatorConnectionID,
			target:                "historical-target",
			targetConnectionID:    targetConnectionID,
			expiresAt:             expiresAt,
		}
		h.mutex.Lock()
		attemptAdded := h.addV2AttemptLocked(attemptID, attempt, insertedAt)
		gateAdded := attemptAdded && h.reservationGates.add(attemptID, relayReservationGate{
			initiatorDeviceID:     attempt.initiator,
			initiatorConnectionID: initiatorConnectionID,
			targetDeviceID:        attempt.target,
			targetConnectionID:    targetConnectionID,
			expiresAt:             expiresAt,
		}, insertedAt)
		h.mutex.Unlock()
		if !attemptAdded {
			t.Fatalf("failed to add indexed attempt %q", attemptID)
		}
		if !gateAdded {
			t.Fatalf("failed to add indexed reservation gate %q", attemptID)
		}
	}

	t.Run("ordinary offer leaves unrelated expiry work to the heap sweeper", func(t *testing.T) {
		h, _, sender, target, _ := newRelayReservationGateHub(t)
		insertedAt := time.Now().Add(-2 * time.Minute)
		expiresAt := insertedAt.Add(time.Second)
		const historical = 32
		for index := 0; index < historical; index++ {
			addState(t, h, fmt.Sprintf("historical-%d", index),
				fmt.Sprintf("historical-initiator-%d", index), fmt.Sprintf("historical-target-%d", index), insertedAt, expiresAt)
		}

		forwardOfferForRelayReservationTest(t, h, sender, target, "current-offer")

		h.mutex.Lock()
		attempts := len(h.v2Attempts)
		gates := len(h.reservationGates.gates)
		attemptExpiries := len(h.v2AttemptExpiries.heap)
		gateExpiries := len(h.reservationGates.expiries.heap)
		h.mutex.Unlock()
		if attempts != historical+1 || gates != historical+1 || attemptExpiries != historical+1 || gateExpiries != historical+1 {
			t.Fatalf("offer swept unrelated expiry state: attempts=%d gates=%d attempt_expiries=%d gate_expiries=%d",
				attempts, gates, attemptExpiries, gateExpiries)
		}
	})

	t.Run("full registries release one expired slot", func(t *testing.T) {
		h, _, sender, target, _ := newRelayReservationGateHub(t)
		h.maxV2Attempts = 2
		h.reservationGates.maxTotal = 2
		insertedAt := time.Now().Add(-2 * time.Minute)
		expiresAt := insertedAt.Add(time.Second)
		for index := 0; index < 2; index++ {
			addState(t, h, fmt.Sprintf("expired-capacity-%d", index),
				fmt.Sprintf("expired-initiator-%d", index), fmt.Sprintf("expired-target-%d", index), insertedAt, expiresAt)
		}

		forwardOfferForRelayReservationTest(t, h, sender, target, "capacity-recovered")

		h.mutex.Lock()
		_, attemptPresent := h.v2Attempts["capacity-recovered"]
		gateKey := relayReservationGateKey{initiatorConnectionID: sender.connectionID, attemptID: "capacity-recovered"}
		_, gatePresent := h.reservationGates.gates[gateKey]
		attempts := len(h.v2Attempts)
		gates := len(h.reservationGates.gates)
		expiredAttempts := 0
		now := time.Now()
		for _, attempt := range h.v2Attempts {
			if !now.Before(attempt.expiresAt) {
				expiredAttempts++
			}
		}
		expiredGates := 0
		for _, gate := range h.reservationGates.gates {
			if !now.Before(gate.expiresAt) {
				expiredGates++
			}
		}
		h.mutex.Unlock()
		if !attemptPresent || !gatePresent || attempts != 2 || gates != 2 || expiredAttempts != 1 || expiredGates != 1 {
			t.Fatalf("expired capacity recovery was not single-slot: attempt_present=%v gate_present=%v attempts=%d gates=%d expired_attempts=%d expired_gates=%d",
				attemptPresent, gatePresent, attempts, gates, expiredAttempts, expiredGates)
		}
	})

	t.Run("connection limit releases its own expired slot", func(t *testing.T) {
		h, _, sender, target, _ := newRelayReservationGateHub(t)
		h.maxV2AttemptsPerConn = 1
		h.reservationGates.maxPerConn = 1
		insertedAt := time.Now().Add(-2 * time.Minute)
		expiresAt := insertedAt.Add(time.Second)
		addState(t, h, "expired-connection-slot", sender.connectionID, "expired-target-connection", insertedAt, expiresAt)

		forwardOfferForRelayReservationTest(t, h, sender, target, "connection-capacity-recovered")

		h.mutex.Lock()
		_, expiredAttemptPresent := h.v2Attempts["expired-connection-slot"]
		expiredGateKey := relayReservationGateKey{initiatorConnectionID: sender.connectionID, attemptID: "expired-connection-slot"}
		_, expiredGatePresent := h.reservationGates.gates[expiredGateKey]
		attemptRefs := len(h.attemptsByConnection[sender.connectionID])
		gateRefs := len(h.reservationGates.byConnection[sender.connectionID])
		h.mutex.Unlock()
		if expiredAttemptPresent || expiredGatePresent || attemptRefs != 1 || gateRefs != 1 {
			t.Fatalf("connection-scoped expiry recovery failed: expired_attempt=%v expired_gate=%v attempt_refs=%d gate_refs=%d",
				expiredAttemptPresent, expiredGatePresent, attemptRefs, gateRefs)
		}
	})
}
