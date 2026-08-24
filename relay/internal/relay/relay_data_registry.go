// Relay Data one-shot role registry, admission quotas, and lifecycle ownership.

package relay

import (
	"context"
	"sync"
	"time"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

const (
	// Consumed one-shot reservations are independently bounded. Their entries
	// expire only after two complete maximum reservation windows, so a token
	// cannot be replayed while an earlier copy could still be in flight.
	maxConsumedRelayDataReservations = 65536
	relayDataConsumedRetention       = 2 * (time.Duration(reservationLifetimeMaxS)*time.Second +
		time.Duration(v2.RESERVATION_EXPIRY_GRACE_S)*time.Second)
	// relayDataCloseTimeout is the total graceful-plus-forced shutdown budget for
	// every RelayData pump owned by one registry.
	relayDataCloseTimeout = 5 * time.Second
)

type relayDataRole uint8

const (
	relayDataRoleInitiator relayDataRole = iota + 1
	relayDataRoleResponder
)

type relayDataPair struct {
	initiator          *relayDataConn
	responder          *relayDataConn
	active             bool
	replacementPending bool
	reservation        Reservation
}

type relayDataUpgradeAdmission uint8

const (
	relayDataUpgradeAccepted relayDataUpgradeAdmission = iota
	relayDataUpgradeClosed
	relayDataUpgradeCapacity
)

// relayDataUpgradeLease reserves an upgraded-without-Connect slot before the
// HTTP 101 response. All fields are owned by registry.mutex.
type relayDataUpgradeLease struct {
	registry             *relayDataRegistry
	deviceID             string
	enrollmentGeneration int64
	active               bool
}

// release is safe on every HTTP failure path and after closeDevice/closeAll
// invalidated the lease.
func (l *relayDataUpgradeLease) release() {
	if l == nil || l.registry == nil {
		return
	}
	l.registry.mutex.Lock()
	l.registry.invalidateUpgradeLeaseLocked(l)
	l.registry.mutex.Unlock()
}

// relayDataRegistry links the initiator/responder endpoints for one
// reservation. Roles are fixed by the authenticated device and token, never by
// arrival order. The registry also owns every RelayData pump lifecycle.
type relayDataRegistry struct {
	mutex sync.Mutex
	pairs map[string]*relayDataPair

	maxSessions  int
	maxUpgrades  int
	pendingPairs int
	activePairs  int
	upgradeSlots int

	// consumed is process-local because this deployment deliberately has one
	// live RelayData instance. Tombstones expire lazily after a conservative
	// replay window; active sockets retain their in-memory reservation.
	consumed map[string]time.Time

	// deviceRefs indexes endpoints after RelayDataConnect admission.
	deviceRefs map[string]map[*relayDataConn]struct{}
	// upgradeRefs indexes authenticated WebSockets that have not yet admitted a
	// RelayDataConnect frame.
	upgradeRefs map[string]map[*relayDataConn]struct{}
	// upgradeLeases cover the pre-101 interval. Per-device indexing lets revoke
	// invalidate a request even if Upgrade returns after the revocation.
	upgradeLeases    map[*relayDataUpgradeLease]struct{}
	upgradeLeaseRefs map[string]map[*relayDataUpgradeLease]struct{}
	// pumpEndpoints retains only endpoints whose owned read/write pumps have not
	// both converged. It lets bounded shutdown force-close sockets even after an
	// endpoint has already left the pending/active pair maps.
	pumpEndpoints map[*relayDataConn]struct{}

	lifecycleCtx    context.Context
	lifecycleCancel context.CancelFunc
	closed          bool
	closeOnce       sync.Once
	closeDone       chan struct{}
	pumps           sync.WaitGroup
}

func newRelayDataRegistry(maxSessions int) *relayDataRegistry {
	if maxSessions <= 0 {
		maxSessions = defaultMaxTransferSessions
	}
	lifecycleCtx, lifecycleCancel := context.WithCancel(context.Background())
	return &relayDataRegistry{
		pairs:            make(map[string]*relayDataPair),
		maxSessions:      maxSessions,
		maxUpgrades:      2 * maxSessions,
		consumed:         make(map[string]time.Time),
		deviceRefs:       make(map[string]map[*relayDataConn]struct{}),
		upgradeRefs:      make(map[string]map[*relayDataConn]struct{}),
		upgradeLeases:    make(map[*relayDataUpgradeLease]struct{}),
		upgradeLeaseRefs: make(map[string]map[*relayDataUpgradeLease]struct{}),
		pumpEndpoints:    make(map[*relayDataConn]struct{}),
		lifecycleCtx:     lifecycleCtx,
		lifecycleCancel:  lifecycleCancel,
		closeDone:        make(chan struct{}),
	}
}

// activePairCount returns the real number of currently paired RelayData
// sessions. Pending endpoints and historical tombstones are excluded.
func (r *relayDataRegistry) activePairCount() int {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	return r.activePairs
}

// retryReservation returns the role-token binding only for an active pair or
// the fresh pending pair created by replacing one. Initial pending admission
// remains governed solely by the shared reservation TTL.
func (r *relayDataRegistry) retryReservation(reservationID string) (Reservation, bool) {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	pair := r.pairs[reservationID]
	if pair == nil || (!pair.active && !pair.replacementPending) {
		return Reservation{}, false
	}
	return pair.reservation, true
}

// beginUpgrade atomically reserves capacity before HTTP 101. The slot remains
// charged while Upgrade is in progress and, after startEndpoint, until the
// first RelayDataConnect frame leaves upgradeRefs.
func (r *relayDataRegistry) beginUpgrade(deviceID string, generation ...int64) (*relayDataUpgradeLease, relayDataUpgradeAdmission) {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	if r.closed {
		return nil, relayDataUpgradeClosed
	}
	if r.upgradeSlots >= r.maxUpgrades {
		return nil, relayDataUpgradeCapacity
	}
	enrollmentGeneration := int64(0)
	if len(generation) > 0 {
		enrollmentGeneration = generation[0]
	}
	lease := &relayDataUpgradeLease{
		registry:             r,
		deviceID:             deviceID,
		enrollmentGeneration: enrollmentGeneration,
		active:               true,
	}
	r.upgradeLeases[lease] = struct{}{}
	refs := r.upgradeLeaseRefs[deviceID]
	if refs == nil {
		refs = make(map[*relayDataUpgradeLease]struct{})
		r.upgradeLeaseRefs[deviceID] = refs
	}
	refs[lease] = struct{}{}
	r.upgradeSlots++
	return lease, relayDataUpgradeAccepted
}

func (r *relayDataRegistry) invalidateUpgradeLeaseLocked(lease *relayDataUpgradeLease) {
	if lease == nil || !lease.active {
		return
	}
	lease.active = false
	delete(r.upgradeLeases, lease)
	refs := r.upgradeLeaseRefs[lease.deviceID]
	delete(refs, lease)
	if len(refs) == 0 {
		delete(r.upgradeLeaseRefs, lease.deviceID)
	}
	if r.upgradeSlots > 0 {
		r.upgradeSlots--
	}
}

// startEndpoint is the immediately-active form used by focused registry tests.
// HTTP admission uses stageEndpoint followed by a durable post-registration
// recheck and activateEndpoint.
func (r *relayDataRegistry) startEndpoint(lease *relayDataUpgradeLease, rc *relayDataConn) bool {
	if !r.stageEndpoint(lease, rc) {
		return false
	}
	return r.activateEndpoint(rc)
}

// stageEndpoint converts a pre-101 lease into a tracked endpoint and starts
// both owned pumps behind rc's activation barrier. Add happens under the same
// mutex as the closed gate, so closeAll cannot start Wait before a late Add.
func (r *relayDataRegistry) stageEndpoint(lease *relayDataUpgradeLease, rc *relayDataConn) bool {
	if lease == nil || rc == nil {
		return false
	}
	r.mutex.Lock()
	if r.closed || lease.registry != r || !lease.active || rc.isTerminal() {
		r.mutex.Unlock()
		return false
	}
	lease.active = false
	delete(r.upgradeLeases, lease)
	leaseRefs := r.upgradeLeaseRefs[lease.deviceID]
	delete(leaseRefs, lease)
	if len(leaseRefs) == 0 {
		delete(r.upgradeLeaseRefs, lease.deviceID)
	}
	refs := r.upgradeRefs[rc.deviceID]
	if refs == nil {
		refs = make(map[*relayDataConn]struct{})
		r.upgradeRefs[rc.deviceID] = refs
	}
	refs[rc] = struct{}{}
	if rc.activation == nil {
		rc.activation = make(chan struct{})
	}
	rc.lifecycleCtx = r.lifecycleCtx
	r.pumpEndpoints[rc] = struct{}{}
	r.pumps.Add(2)
	r.mutex.Unlock()

	go func() {
		defer r.pumps.Done()
		rc.write()
	}()
	go func() {
		defer func() {
			r.mutex.Lock()
			delete(r.pumpEndpoints, rc)
			r.mutex.Unlock()
			r.pumps.Done()
		}()
		rc.read()
	}()
	return true
}

// activateEndpoint releases a staged endpoint only while it is still tracked
// and the registry remains open. Lifecycle invalidation removes/ closes it
// first, making this commit fail closed.
func (r *relayDataRegistry) activateEndpoint(rc *relayDataConn) bool {
	if rc == nil {
		return false
	}
	r.mutex.Lock()
	refs := r.upgradeRefs[rc.deviceID]
	_, tracked := refs[rc]
	active := !r.closed && tracked && !rc.isTerminal()
	if active {
		rc.admissionActive.Store(true)
		rc.activationOnce.Do(func() { close(rc.activation) })
	}
	r.mutex.Unlock()
	if !active {
		rc.close()
	}
	return active
}

// removeUpgradeLocked releases an upgraded-without-Connect slot exactly once.
func (r *relayDataRegistry) removeUpgradeLocked(rc *relayDataConn) {
	refs := r.upgradeRefs[rc.deviceID]
	if refs == nil {
		return
	}
	if _, ok := refs[rc]; !ok {
		return
	}
	delete(refs, rc)
	if len(refs) == 0 {
		delete(r.upgradeRefs, rc.deviceID)
	}
	if r.upgradeSlots > 0 {
		r.upgradeSlots--
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

func (r *relayDataRegistry) pruneConsumedLocked(now time.Time) {
	for reservationID, expiresAt := range r.consumed {
		if !expiresAt.After(now) {
			delete(r.consumed, reservationID)
		}
	}
}

// admitEndpoint consumes one role slot after RelayDataConnect validation. All
// capacity decisions precede slot/deviceRefs mutation, so a rejected second
// role cannot leak partial pair state.
func (r *relayDataRegistry) admitEndpoint(rc *relayDataConn) (peer *relayDataConn, ok bool) {
	if rc == nil {
		return nil, false
	}
	r.mutex.Lock()
	displaced := make([]*relayDataConn, 0, 2)
	defer func() {
		r.mutex.Unlock()
		for _, endpoint := range displaced {
			endpoint.sendCloseAndShutdown(2, "relay data endpoint replaced")
		}
	}()
	r.removeUpgradeLocked(rc)
	if r.closed || rc.isTerminal() {
		return nil, false
	}

	var selectRole func(*relayDataPair) (**relayDataConn, *relayDataConn)
	switch rc.role {
	case relayDataRoleInitiator:
		selectRole = func(pair *relayDataPair) (**relayDataConn, *relayDataConn) {
			return &pair.initiator, pair.responder
		}
	case relayDataRoleResponder:
		selectRole = func(pair *relayDataPair) (**relayDataConn, *relayDataConn) {
			return &pair.responder, pair.initiator
		}
	default:
		return nil, false
	}

	now := time.Now()
	pair := r.pairs[rc.reservationID]
	if expiresAt, consumed := r.consumed[rc.reservationID]; consumed {
		if expiresAt.After(now) {
			if pair == nil || (!pair.active && !pair.replacementPending) {
				return nil, false
			}
		} else {
			delete(r.consumed, rc.reservationID)
		}
	}

	if pair == nil {
		if r.pendingPairs >= r.maxSessions {
			return nil, false
		}
		pair = &relayDataPair{reservation: rc.res}
		r.pairs[rc.reservationID] = pair
		r.pendingPairs++
	}
	slot, other := selectRole(pair)
	if replaced := *slot; replaced != nil {
		if !pair.active {
			*slot = rc
			pair.reservation = rc.res
			r.removeDeviceRefLocked(replaced)
			r.addDeviceRefLocked(rc)
			replaced.markTerminal()
			replaced.clearPeer()
			displaced = append(displaced, replaced)
			return nil, true
		}

		// A retry against an active role invalidates the complete old pair. The
		// retry becomes the first endpoint of a fresh pending pair; the counterpart
		// must reconnect and receive a new one-shot PairReady with it.
		for _, endpoint := range []*relayDataConn{pair.initiator, pair.responder} {
			if endpoint == nil {
				continue
			}
			r.removeDeviceRefLocked(endpoint)
			endpoint.markTerminal()
			endpoint.clearPeer()
			displaced = append(displaced, endpoint)
		}
		pair.initiator = nil
		pair.responder = nil
		pair.active = false
		pair.replacementPending = true
		pair.reservation = rc.res
		if r.activePairs > 0 {
			r.activePairs--
		}
		r.pendingPairs++
		slot, _ = selectRole(pair)
		*slot = rc
		r.addDeviceRefLocked(rc)
		return nil, true
	}
	if other != nil {
		if r.activePairs >= r.maxSessions {
			return nil, false
		}
		if len(r.consumed) >= maxConsumedRelayDataReservations {
			r.pruneConsumedLocked(now)
			if len(r.consumed) >= maxConsumedRelayDataReservations {
				return nil, false
			}
		}
	}

	*slot = rc
	r.addDeviceRefLocked(rc)
	if other == nil {
		return nil, true
	}

	peer = other
	rc.link(peer)
	rc.pairReadySent.Store(false)
	peer.pairReadySent.Store(false)
	// PairReady is the sole L1 setup signal and shares each endpoint's writer
	// queue. Both frames share a two-phase decision barrier: an early writer may
	// dequeue but cannot publish until both queues accept their frame and all
	// registry state below is committed.
	pairReadyDecision := newRelayDataPairReadyDecision()
	currentQueued := rc.enqueuePairReadyPing(pairReadyDecision)
	peerQueued := false
	if currentQueued {
		peerQueued = peer.enqueuePairReadyPing(pairReadyDecision)
	}
	pairReadyQueued := currentQueued && peerQueued
	if !pairReadyQueued {
		pair.initiator = nil
		pair.responder = nil
		delete(r.pairs, rc.reservationID)
		if r.pendingPairs > 0 {
			r.pendingPairs--
		}
		r.removeDeviceRefLocked(rc)
		r.removeDeviceRefLocked(peer)
		rc.markTerminal()
		peer.markTerminal()
		rc.clearPeer()
		peer.clearPeer()
		pairReadyDecision.resolve(false)
		return peer, false
	}

	pair.active = true
	pair.replacementPending = false
	r.pendingPairs--
	r.activePairs++
	r.consumed[rc.reservationID] = now.Add(relayDataConsumedRetention)
	rc.ready.Store(true)
	peer.ready.Store(true)
	rc.paired.Store(true)
	peer.paired.Store(true)
	pairReadyDecision.resolve(true)
	return peer, true
}

// forwardEndpoint linearizes every pre-encoded opaque business-frame handoff
// with pair invalidation. Encoding and its potentially large allocation happen
// before registry.mutex; the critical section contains only state rechecks,
// flow reservation, and the non-blocking queue insert. A frame is therefore
// either committed before revocation or rejected after it, with no
// check-then-enqueue gap. The writer independently discards any pre-terminal
// buffered business frame that was not yet on the wire.
func (r *relayDataRegistry) forwardEndpoint(rc *relayDataConn, frame relayDataOutboundFrame) bool {
	if rc == nil || len(frame.data) == 0 || frame.pairReady != nil || frame.allowedAfterTerminal {
		return false
	}
	r.mutex.Lock()
	defer r.mutex.Unlock()
	if r.closed || rc.isTerminal() || !rc.ready.Load() || !rc.pairReadySent.Load() {
		return false
	}
	pair := r.pairs[rc.reservationID]
	if pair == nil || !pair.active {
		return false
	}
	var other *relayDataConn
	switch {
	case pair.initiator == rc:
		other = pair.responder
	case pair.responder == rc:
		other = pair.initiator
	default:
		return false
	}
	if other == nil || other.isTerminal() || !other.ready.Load() || rc.peerConn() != other {
		return false
	}
	return other.enqueue(frame)
}

// releaseEndpoint removes only the exact endpoint identity.
func (r *relayDataRegistry) releaseEndpoint(rc *relayDataConn) {
	if rc == nil {
		return
	}
	r.mutex.Lock()
	defer r.mutex.Unlock()
	rc.markTerminal()
	r.releaseEndpointLocked(rc)
}

// releaseEndpointLocked detaches exact registry ownership. The caller owns
// registry.mutex and marks rc terminal first for lifecycle invalidation.
func (r *relayDataRegistry) releaseEndpointLocked(rc *relayDataConn) {
	r.removeUpgradeLocked(rc)
	pair := r.pairs[rc.reservationID]
	if pair == nil {
		r.removeDeviceRefLocked(rc)
		return
	}
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
	other := pair.initiator
	if other == nil {
		other = pair.responder
	}
	if other != nil {
		other.markTerminal()
		other.clearPeer()
	}
	rc.clearPeer()
	if pair.active {
		delete(r.pairs, rc.reservationID)
		if r.activePairs > 0 {
			r.activePairs--
		}
	} else if pair.initiator == nil && pair.responder == nil {
		delete(r.pairs, rc.reservationID)
		if r.pendingPairs > 0 {
			r.pendingPairs--
		}
	}
}

// closeDevice closes every endpoint authenticated as deviceID. An active
// endpoint also closes its counterpart. Pre-101 leases are invalidated first,
// so a concurrent Upgrade cannot register after the lifecycle decision.
func (r *relayDataRegistry) closeDevice(deviceID string) {
	r.closeDeviceBeforeGeneration(deviceID, 0)
}

// closeDeviceBeforeGeneration is the generation-aware re-enrollment form of
// closeDevice. cutoff <= 0 closes every endpoint (revocation/shutdown). A
// positive cutoff closes only endpoints and pre-upgrade leases authenticated
// under an older enrollment, so a delayed kick event cannot kill the new one.
func (r *relayDataRegistry) closeDeviceBeforeGeneration(deviceID string, cutoff int64) {
	r.mutex.Lock()
	for lease := range r.upgradeLeaseRefs[deviceID] {
		if cutoff <= 0 || lease.enrollmentGeneration < cutoff {
			r.invalidateUpgradeLeaseLocked(lease)
		}
	}
	targets := make(map[*relayDataConn]struct{})
	for rc := range r.deviceRefs[deviceID] {
		if cutoff > 0 && rc.enrollmentGeneration >= cutoff {
			continue
		}
		targets[rc] = struct{}{}
		if peer := rc.peerConn(); peer != nil {
			targets[peer] = struct{}{}
		}
	}
	for rc := range r.upgradeRefs[deviceID] {
		if cutoff > 0 && rc.enrollmentGeneration >= cutoff {
			continue
		}
		targets[rc] = struct{}{}
	}
	// This is the revocation linearization point. Mark every affected endpoint,
	// including an active counterpart, terminal while forwardEndpoint and new
	// admission are excluded by the same registry mutex. Detach pair/upgrade
	// ownership before unlocking so retryReservation cannot resurrect it.
	for rc := range targets {
		rc.markTerminal()
	}
	for rc := range targets {
		r.releaseEndpointLocked(rc)
	}
	r.mutex.Unlock()

	for rc := range targets {
		rc.waitForWriteQuiescence()
		// A PairReady write that began before revocation may have completed while
		// the lifecycle call waited. Reassert derived terminal flags before return;
		// terminal already dominated forwarding throughout the wait.
		rc.markTerminal()
	}
	for rc := range targets {
		// Queue the terminal frame only after every pre-revocation socket write has
		// quiesced. The single writer may flush this Close asynchronously, but no
		// business frame can start after the lifecycle method returns.
		rc.sendCloseAndShutdown(2, "device revoked")
	}
}

// deviceIDs snapshots every device with local RelayData state, including
// pre-101 requests, for data-only revocation reconciliation.
func (r *relayDataRegistry) deviceIDs() []string {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	ids := make(map[string]struct{}, len(r.deviceRefs)+len(r.upgradeRefs)+len(r.upgradeLeaseRefs))
	for deviceID := range r.deviceRefs {
		ids[deviceID] = struct{}{}
	}
	for deviceID := range r.upgradeRefs {
		ids[deviceID] = struct{}{}
	}
	for deviceID := range r.upgradeLeaseRefs {
		ids[deviceID] = struct{}{}
	}
	result := make([]string, 0, len(ids))
	for deviceID := range ids {
		result = append(result, deviceID)
	}
	return result
}

// closeAll permanently closes registration under the standard RelayData
// shutdown budget. Repeated calls are safe.
func (r *relayDataRegistry) closeAll() {
	ctx, cancel := context.WithTimeout(context.Background(), relayDataCloseTimeout)
	defer cancel()
	r.closeAllWithContext(ctx)
}

// closeAllWithContext first cancels the registry-owned lease-I/O context, then
// gives queued RelayDataClose frames one drain window before force-closing every
// remaining socket. A reservation implementation that ignores cancellation can
// delay its own goroutine, but it cannot make the server shutdown unbounded.
func (r *relayDataRegistry) closeAllWithContext(ctx context.Context) {
	if ctx == nil {
		ctx = context.Background()
	}
	r.closeOnce.Do(func() {
		r.mutex.Lock()
		r.closed = true
		r.lifecycleCancel()
		for lease := range r.upgradeLeases {
			r.invalidateUpgradeLeaseLocked(lease)
		}
		targets := make([]*relayDataConn, 0, len(r.pumpEndpoints))
		for rc := range r.pumpEndpoints {
			rc.markTerminal()
			targets = append(targets, rc)
		}
		for _, rc := range targets {
			r.releaseEndpointLocked(rc)
		}
		r.mutex.Unlock()

		for _, rc := range targets {
			rc.sendCloseAndShutdown(2, "relay server shutting down")
		}
		pumpsDone := make(chan struct{})
		go func() {
			r.pumps.Wait()
			close(pumpsDone)
		}()
		drainTimer := time.NewTimer(relayDataDrainTimeout)
		select {
		case <-pumpsDone:
			if !drainTimer.Stop() {
				select {
				case <-drainTimer.C:
				default:
				}
			}
			close(r.closeDone)
			return
		case <-drainTimer.C:
		case <-ctx.Done():
		}
		for _, rc := range targets {
			rc.forceSocketClose()
		}
		select {
		case <-pumpsDone:
		case <-ctx.Done():
		}
		close(r.closeDone)
	})
	select {
	case <-r.closeDone:
	case <-ctx.Done():
	}
}
