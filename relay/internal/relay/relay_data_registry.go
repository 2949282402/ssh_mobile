// Relay Data one-shot role registry and revocation index.

package relay

import "sync"

const (
	// Pending pairs and consumed one-shot reservations are independently bounded.
	maxPendingRelayDataConns         = 4096
	maxConsumedRelayDataReservations = 65536
)

type relayDataRole uint8

const (
	relayDataRoleInitiator relayDataRole = iota + 1
	relayDataRoleResponder
)

type relayDataPair struct {
	initiator *relayDataConn
	responder *relayDataConn
}

// relayDataRegistry 把同一 reservation 的 initiator/responder 两个 /v2/relay
// 端点链接起来。角色由首帧 token 决定，不能因为到达顺序而互换。
type relayDataRegistry struct {
	mutex sync.Mutex
	pairs map[string]*relayDataPair
	// consumed is process-local because this deployment deliberately has one
	// live RelayData instance.  Once a pair has been established, the
	// reservation token cannot create another pair; active sockets retain their
	// in-memory reservation and are not dependent on the admission record.
	consumed map[string]struct{}
	// deviceRefs indexes every data endpoint after its RelayDataConnect frame
	// has been admitted.  Revocation uses it to close pending endpoints and the
	// counterpart of an active pair without scanning unrelated sockets.
	deviceRefs map[string]map[*relayDataConn]struct{}
	// upgradeRefs covers an authenticated WebSocket that has not sent its
	// RelayDataConnect first frame yet.  Revoke must close this pending socket
	// too; it must not be able to outlive the device authorization decision.
	upgradeRefs  map[string]map[*relayDataConn]struct{}
	pendingPairs int
}

func newRelayDataRegistry() *relayDataRegistry {
	return &relayDataRegistry{
		pairs:       make(map[string]*relayDataPair),
		consumed:    make(map[string]struct{}),
		deviceRefs:  make(map[string]map[*relayDataConn]struct{}),
		upgradeRefs: make(map[string]map[*relayDataConn]struct{}),
	}
}

// activePairCount returns the number of currently paired RelayData sessions.
// Pending single-role endpoints and consumed historical reservations are not
// active transfers. The same mutex that owns pair admission/release makes the
// administrator snapshot safe while data sockets connect or disconnect.
func (r *relayDataRegistry) activePairCount() int {
	r.mutex.Lock()
	defer r.mutex.Unlock()

	active := 0
	for _, pair := range r.pairs {
		if pair.initiator != nil && pair.responder != nil &&
			pair.initiator.paired.Load() && pair.responder.paired.Load() {
			active++
		}
	}
	return active
}

func (r *relayDataRegistry) trackUpgradeLocked(rc *relayDataConn) {
	refs := r.upgradeRefs[rc.deviceID]
	if refs == nil {
		refs = make(map[*relayDataConn]struct{})
		r.upgradeRefs[rc.deviceID] = refs
	}
	refs[rc] = struct{}{}
}

func (r *relayDataRegistry) trackUpgrade(rc *relayDataConn) {
	r.mutex.Lock()
	r.trackUpgradeLocked(rc)
	r.mutex.Unlock()
}

func (r *relayDataRegistry) removeUpgradeLocked(rc *relayDataConn) {
	refs := r.upgradeRefs[rc.deviceID]
	if refs == nil {
		return
	}
	delete(refs, rc)
	if len(refs) == 0 {
		delete(r.upgradeRefs, rc.deviceID)
	}
}

func (r *relayDataRegistry) addDeviceRefLocked(rc *relayDataConn) {
	refs := r.deviceRefs[rc.deviceID]
	if refs == nil {
		refs = make(map[*relayDataConn]struct{})
		r.deviceRefs[rc.deviceID] = refs
	}
	refs[rc] = struct{}{}
}

func (r *relayDataRegistry) removeDeviceRefLocked(rc *relayDataConn) {
	refs := r.deviceRefs[rc.deviceID]
	if refs == nil {
		return
	}
	delete(refs, rc)
	if len(refs) == 0 {
		delete(r.deviceRefs, rc.deviceID)
	}
}

// admitEndpoint consumes one role slot after RelayDataConnect validation.
//
// Each role is one-shot, and a completed reservation is recorded as consumed
// before either token can admit another endpoint. Only the opposite role is
// returned; socket work always happens after releasing the registry lock.
func (r *relayDataRegistry) admitEndpoint(rc *relayDataConn) (peer *relayDataConn, ok bool) {
	r.mutex.Lock()
	r.removeUpgradeLocked(rc)
	if _, alreadyConsumed := r.consumed[rc.reservationID]; alreadyConsumed {
		r.mutex.Unlock()
		return nil, false
	}
	pair := r.pairs[rc.reservationID]
	if pair == nil {
		if r.pendingPairs >= maxPendingRelayDataConns {
			r.mutex.Unlock()
			return nil, false
		}
		pair = &relayDataPair{}
		r.pairs[rc.reservationID] = pair
		r.pendingPairs++
	}

	var slot **relayDataConn
	var other *relayDataConn
	switch rc.role {
	case relayDataRoleInitiator:
		slot = &pair.initiator
		other = pair.responder
	case relayDataRoleResponder:
		slot = &pair.responder
		other = pair.initiator
	default:
		r.mutex.Unlock()
		return nil, false
	}
	if *slot != nil {
		// A role slot is one-shot.  Replacing an endpoint would let a replayed
		// token steal a still-pending pair and made reservation consumption
		// ambiguous.  The caller closes the duplicate outside the registry lock.
		r.mutex.Unlock()
		return nil, false
	}
	*slot = rc
	r.addDeviceRefLocked(rc)

	if pair.initiator != nil && pair.responder != nil {
		if len(r.consumed) >= maxConsumedRelayDataReservations {
			r.mutex.Unlock()
			return nil, false
		}
		if r.pendingPairs > 0 {
			r.pendingPairs--
		}
		peer = other
		rc.link(peer)
		// PairReady is the sole L1 setup signal on the frozen contract.  It is a
		// WebSocket Ping, queued before publishing ready=true, and therefore
		// shares the same single writer as Pong, keepalive, binary, and Close.
		pairReadyQueued := rc.enqueuePairReadyPing() && peer.enqueuePairReadyPing()
		rc.ready.Store(pairReadyQueued)
		peer.ready.Store(pairReadyQueued)
		if pairReadyQueued {
			r.consumed[rc.reservationID] = struct{}{}
			rc.paired.Store(true)
			peer.paired.Store(true)
		}
	}
	r.mutex.Unlock()
	return peer, true
}

// releaseEndpoint removes only the exact endpoint identity.
func (r *relayDataRegistry) releaseEndpoint(rc *relayDataConn) {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	r.removeUpgradeLocked(rc)
	pair := r.pairs[rc.reservationID]
	if pair == nil {
		r.removeDeviceRefLocked(rc)
		return
	}
	wasComplete := pair.initiator != nil && pair.responder != nil
	removed := false
	if pair.initiator == rc {
		pair.initiator = nil
		removed = true
	}
	if pair.responder == rc {
		pair.responder = nil
		removed = true
	}
	if !removed {
		r.removeDeviceRefLocked(rc)
		return
	}
	r.removeDeviceRefLocked(rc)
	rc.ready.Store(false)
	other := pair.initiator
	if other == nil {
		other = pair.responder
	}
	if other != nil {
		other.ready.Store(false)
		other.clearPeer()
	}
	rc.clearPeer()
	if wasComplete {
		delete(r.pairs, rc.reservationID)
	} else if pair.initiator == nil && pair.responder == nil {
		delete(r.pairs, rc.reservationID)
		if r.pendingPairs > 0 {
			r.pendingPairs--
		}
	}
}

// closeDevice closes every data endpoint authenticated as deviceID.  An active
// endpoint also closes its counterpart; a pending endpoint is closed in place.
// The registry lock is released before socket work so revoke cannot block
// registration of unrelated reservations on a slow WebSocket peer.
func (r *relayDataRegistry) closeDevice(deviceID string) {
	r.mutex.Lock()
	targets := make(map[*relayDataConn]struct{})
	for rc := range r.deviceRefs[deviceID] {
		targets[rc] = struct{}{}
		if peer := rc.peerConn(); peer != nil {
			targets[peer] = struct{}{}
		}
	}
	for rc := range r.upgradeRefs[deviceID] {
		targets[rc] = struct{}{}
	}
	r.mutex.Unlock()

	for rc := range targets {
		rc.sendCloseAndShutdown(2, "device revoked")
	}
}

// closeAll is used during server shutdown.  It is deliberately separate from
// closeDevice so shutdown can close every local data socket without pretending
// that a device-level revocation occurred.
func (r *relayDataRegistry) closeAll() {
	r.mutex.Lock()
	targets := make(map[*relayDataConn]struct{})
	for _, pair := range r.pairs {
		if pair.initiator != nil {
			targets[pair.initiator] = struct{}{}
		}
		if pair.responder != nil {
			targets[pair.responder] = struct{}{}
		}
	}
	for _, refs := range r.upgradeRefs {
		for rc := range refs {
			targets[rc] = struct{}{}
		}
	}
	r.mutex.Unlock()

	for rc := range targets {
		rc.sendCloseAndShutdown(2, "relay server shutting down")
	}
}
