package relay

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

func testRelayDataConnForRegistry(id, device string, role relayDataRole) *relayDataConn {
	return &relayDataConn{
		reservationID: id,
		deviceID:      device,
		role:          role,
		outbound:      make(chan relayDataOutboundFrame, 8),
		done:          make(chan struct{}),
		writeDone:     make(chan struct{}),
		flow: relayDataFlowBudget{
			maxPendingFrames: 8,
			maxPendingBytes:  4096,
		},
	}
}

func TestRelayDataRegistryReplacesSameRoleAndRepairsActivePair(t *testing.T) {
	registry := newRelayDataRegistry(defaultMaxTransferSessions)
	initiator := testRelayDataConnForRegistry("reservation-a", "device-a", relayDataRoleInitiator)
	duplicate := testRelayDataConnForRegistry("reservation-a", "device-a", relayDataRoleInitiator)
	responder := testRelayDataConnForRegistry("reservation-a", "device-b", relayDataRoleResponder)
	if active := registry.activePairCount(); active != 0 {
		t.Fatalf("new registry should have no active pairs, got %d", active)
	}

	if _, ok := registry.admitEndpoint(initiator); !ok {
		t.Fatal("first role should be admitted")
	}
	if active := registry.activePairCount(); active != 0 {
		t.Fatalf("single pending role must not count as active, got %d", active)
	}
	if _, ok := registry.admitEndpoint(duplicate); !ok {
		t.Fatal("same-role retry must replace an unpaired endpoint")
	}
	select {
	case <-initiator.done:
	default:
		t.Fatal("replaced unpaired endpoint remained open")
	}
	peer, ok := registry.admitEndpoint(responder)
	if !ok || peer != duplicate {
		t.Fatalf("matching opposite role should pair, peer=%p ok=%v", peer, ok)
	}
	if !duplicate.ready.Load() || !responder.ready.Load() || !duplicate.paired.Load() {
		t.Fatal("paired endpoints must be Ready and paired")
	}
	if active := registry.activePairCount(); active != 1 {
		t.Fatalf("paired reservation should count once, got %d", active)
	}
	retry := testRelayDataConnForRegistry("reservation-a", "device-a", relayDataRoleInitiator)
	if peer, ok := registry.admitEndpoint(retry); !ok || peer != nil {
		t.Fatalf("same-role retry must invalidate the active pair: peer=%p ok=%v", peer, ok)
	}
	for name, endpoint := range map[string]*relayDataConn{"old initiator": duplicate, "old responder": responder} {
		select {
		case <-endpoint.done:
		default:
			t.Fatalf("%s remained open after active-pair replacement", name)
		}
	}
	if registry.activePairCount() != 0 || registry.pendingPairs != 1 {
		t.Fatalf("replacement must create one fresh pending pair: active=%d pending=%d", registry.activePairCount(), registry.pendingPairs)
	}
	retryResponder := testRelayDataConnForRegistry("reservation-a", "device-b", relayDataRoleResponder)
	if peer, ok := registry.admitEndpoint(retryResponder); !ok || peer != retry {
		t.Fatalf("replacement responder must pair only with retry: peer=%p ok=%v", peer, ok)
	}

	// PairReady is the sole setup signal and is queued through the same
	// writer-owned outbound channel as all later control/data frames.
	if frame := <-retry.outbound; frame.messageType != websocket.PingMessage || frame.pairReady == nil || !frame.pairReady.wait() {
		t.Fatalf("first queued frame must be PairReady Ping, got %d", frame.messageType)
	}

	registry.releaseEndpoint(retryResponder)
	if active := registry.activePairCount(); active != 0 {
		t.Fatalf("released pair must leave the active count, got %d", active)
	}
}

func TestRelayDataRegistryPairReadyBarrierAbortsPartialQueue(t *testing.T) {
	registry := newRelayDataRegistry(1)
	initiator := testRelayDataConnForRegistry("reservation-barrier", "device-a", relayDataRoleInitiator)
	if _, ok := registry.admitEndpoint(initiator); !ok {
		t.Fatal("initiator admission failed")
	}
	// Make the already-pending peer reject its PairReady while the completing
	// endpoint can accept its own. This is the exact former partial-send order.
	initiator.outbound = make(chan relayDataOutboundFrame)
	responder := testRelayDataConnForRegistry("reservation-barrier", "device-b", relayDataRoleResponder)
	peer, ok := registry.admitEndpoint(responder)
	if ok || peer != initiator {
		t.Fatalf("partial PairReady queue must roll back both roles: peer=%p ok=%v", peer, ok)
	}
	frame := <-responder.outbound
	if frame.messageType != websocket.PingMessage || frame.pairReady == nil {
		t.Fatalf("unexpected staged PairReady frame: %+v", frame)
	}
	if frame.pairReady.wait() {
		t.Fatal("a staged frame must be aborted when the counterpart queue rejects")
	}
	if responder.ready.Load() || initiator.ready.Load() || responder.paired.Load() || initiator.paired.Load() {
		t.Fatal("aborted PairReady must never publish ready/paired state")
	}
	registry.mutex.Lock()
	_, pairPresent := registry.pairs[responder.reservationID]
	pending, active := registry.pendingPairs, registry.activePairs
	registry.mutex.Unlock()
	if pairPresent || pending != 0 || active != 0 {
		t.Fatalf("aborted PairReady leaked pair state: present=%v pending=%d active=%d", pairPresent, pending, active)
	}
}

func TestRelayDataRegistryEnforcesDynamicPairQuotasWithoutPartialState(t *testing.T) {
	registry := newRelayDataRegistry(1)
	firstInitiator := testRelayDataConnForRegistry("reservation-one", "device-a", relayDataRoleInitiator)
	secondInitiator := testRelayDataConnForRegistry("reservation-two", "device-c", relayDataRoleInitiator)
	if _, ok := registry.admitEndpoint(firstInitiator); !ok {
		t.Fatal("first pending reservation should be admitted")
	}
	if _, ok := registry.admitEndpoint(secondInitiator); ok {
		t.Fatal("pending pair quota must reject another reservation")
	}
	if registry.pendingPairs != 1 || registry.pairs["reservation-two"] != nil {
		t.Fatalf("pending rejection leaked state: pending=%d pair=%+v", registry.pendingPairs, registry.pairs["reservation-two"])
	}

	firstResponder := testRelayDataConnForRegistry("reservation-one", "device-b", relayDataRoleResponder)
	if peer, ok := registry.admitEndpoint(firstResponder); !ok || peer != firstInitiator {
		t.Fatalf("first pair completion failed: peer=%p ok=%v", peer, ok)
	}
	if registry.pendingPairs != 0 || registry.activePairCount() != 1 {
		t.Fatalf("first pair counters: pending=%d active=%d", registry.pendingPairs, registry.activePairCount())
	}
	if _, ok := registry.admitEndpoint(secondInitiator); !ok {
		t.Fatal("an active pair must not consume the independent pending quota")
	}
	secondResponder := testRelayDataConnForRegistry("reservation-two", "device-d", relayDataRoleResponder)
	if _, ok := registry.admitEndpoint(secondResponder); ok {
		t.Fatal("active pair quota must reject a second completion")
	}

	registry.mutex.Lock()
	secondPair := registry.pairs["reservation-two"]
	_, rejectedTracked := registry.deviceRefs["device-d"][secondResponder]
	pending, active := registry.pendingPairs, registry.activePairs
	registry.mutex.Unlock()
	if secondPair == nil || secondPair.initiator != secondInitiator || secondPair.responder != nil || rejectedTracked {
		t.Fatalf("active-capacity rejection mutated the pending pair: pair=%+v rejectedTracked=%v", secondPair, rejectedTracked)
	}
	if pending != 1 || active != 1 {
		t.Fatalf("capacity rejection changed counters: pending=%d active=%d", pending, active)
	}

	registry.releaseEndpoint(firstResponder)
	if peer, ok := registry.admitEndpoint(secondResponder); !ok || peer != secondInitiator {
		t.Fatalf("released active capacity should admit the waiting pair: peer=%p ok=%v", peer, ok)
	}
	if registry.activePairCount() != 1 {
		t.Fatalf("active pair count after retry=%d want=1", registry.activePairCount())
	}
}

func TestRelayDataRegistryConsumedCapacityChecksBeforeCommitAndPrunesExpired(t *testing.T) {
	registry := newRelayDataRegistry(2)
	initiator := testRelayDataConnForRegistry("reservation-capacity", "device-a", relayDataRoleInitiator)
	responder := testRelayDataConnForRegistry("reservation-capacity", "device-b", relayDataRoleResponder)
	if _, ok := registry.admitEndpoint(initiator); !ok {
		t.Fatal("initiator admission failed")
	}

	future := time.Now().Add(time.Hour)
	registry.mutex.Lock()
	for index := 0; index < maxConsumedRelayDataReservations; index++ {
		registry.consumed[fmt.Sprintf("consumed-%d", index)] = future
	}
	registry.mutex.Unlock()
	if _, ok := registry.admitEndpoint(responder); ok {
		t.Fatal("full consumed tombstone capacity must reject pair completion")
	}
	registry.mutex.Lock()
	pair := registry.pairs[initiator.reservationID]
	_, responderTracked := registry.deviceRefs[responder.deviceID][responder]
	pending, active := registry.pendingPairs, registry.activePairs
	for reservationID := range registry.consumed {
		registry.consumed[reservationID] = time.Now().Add(-time.Second)
	}
	registry.mutex.Unlock()
	if pair == nil || pair.initiator != initiator || pair.responder != nil || responderTracked {
		t.Fatalf("consumed-capacity rejection leaked state: pair=%+v responderTracked=%v", pair, responderTracked)
	}
	if pending != 1 || active != 0 {
		t.Fatalf("consumed-capacity rejection changed counters: pending=%d active=%d", pending, active)
	}

	if peer, ok := registry.admitEndpoint(responder); !ok || peer != initiator {
		t.Fatalf("expired tombstones should be pruned and release capacity: peer=%p ok=%v", peer, ok)
	}
	registry.mutex.Lock()
	consumedCount := len(registry.consumed)
	expiresAt := registry.consumed[initiator.reservationID]
	registry.mutex.Unlock()
	if consumedCount != 1 || time.Until(expiresAt) < relayDataConsumedRetention-time.Second {
		t.Fatalf("unexpected tombstone retention: count=%d expiresAt=%v retention=%v", consumedCount, expiresAt, relayDataConsumedRetention)
	}
	minimumRetention := 2 * (time.Duration(reservationLifetimeMaxS)*time.Second +
		time.Duration(v2.RESERVATION_EXPIRY_GRACE_S)*time.Second)
	if relayDataConsumedRetention < minimumRetention {
		t.Fatalf("tombstone retention=%v want at least %v", relayDataConsumedRetention, minimumRetention)
	}
}

func TestRelayDataRegistryUpgradeQuotaRevocationAndClosedGate(t *testing.T) {
	registry := newRelayDataRegistry(1)
	leaseA, status := registry.beginUpgrade("device-a")
	if status != relayDataUpgradeAccepted {
		t.Fatalf("first upgrade status=%v", status)
	}
	leaseB, status := registry.beginUpgrade("device-b")
	if status != relayDataUpgradeAccepted {
		t.Fatalf("second upgrade status=%v", status)
	}
	if _, status = registry.beginUpgrade("device-c"); status != relayDataUpgradeCapacity {
		t.Fatalf("third upgrade status=%v want capacity", status)
	}

	registry.closeDevice("device-a")
	if registry.startEndpoint(leaseA, testRelayDataConnForRegistry("late-a", "device-a", relayDataRoleInitiator)) {
		t.Fatal("revoked pre-101 lease must not register a late endpoint")
	}
	leaseB.release()
	registry.mutex.Lock()
	upgradeSlots := registry.upgradeSlots
	registry.mutex.Unlock()
	if upgradeSlots != 0 {
		t.Fatalf("all failed/released paths must free upgrade slots, got %d", upgradeSlots)
	}

	lateLease, status := registry.beginUpgrade("device-c")
	if status != relayDataUpgradeAccepted {
		t.Fatalf("upgrade after release status=%v", status)
	}
	registry.closeAll()
	registry.closeAll()
	if registry.startEndpoint(lateLease, testRelayDataConnForRegistry("late-c", "device-c", relayDataRoleInitiator)) {
		t.Fatal("shutdown-invalidated lease must not register an endpoint")
	}
	if _, status = registry.beginUpgrade("device-c"); status != relayDataUpgradeClosed {
		t.Fatalf("post-shutdown upgrade status=%v want closed", status)
	}
}
