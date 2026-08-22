//! Peer-owned physical paths and bounded business leases.
//!
//! A [`PeerPathManager`] owns the physical carriers for one peer.  The
//! registry only indexes weak references so it can revoke paths during peer
//! teardown without becoming a second carrier owner.  [`PathHandle`] is a
//! copyable, non-owning identity; [`PathLease`] holds the explicit reference
//! that keeps one [`PhysicalPath`] alive for a borrower and releases it when
//! the operation ends.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use network_protocol::RouteType;
use network_quic::{send_channel_frame, ChannelFrameKind};
use network_relay::RelayDataClient;
use quinn::{Connection, VarInt};

use crate::connection::{
    ConnectionProfile, GenericFrameKind, GenericRouteHandle, Route, RouteTopology, RouteTransport,
};
use crate::errors::CoreNetworkError;
use crate::task_supervisor::{CancellationToken, TaskLease};

use super::peer_supervisor::PeerId;

pub(crate) const MAX_READY_PATHS_PER_PEER: usize = 8;
pub(crate) const MAX_PATH_LEASES: usize = 32;

const GENERIC_ROUTE_CLOSE_TIMEOUT: Duration = Duration::from_secs(1);

type PathIoResult = Result<(), Box<dyn std::error::Error + Send + Sync>>;
type PathIoFuture = Pin<Box<dyn Future<Output = PathIoResult> + Send>>;

/// Owns the generic route driver and receiver leases while a route is being
/// staged for publication. The path owner takes this value only after the
/// authenticated route wins its admission race.
pub(crate) struct GenericRouteOwner {
    handle: GenericRouteHandle,
    driver_task: TaskLease,
    receiver_task: TaskLease,
    route_stop: CancellationToken,
    stopping: Arc<AtomicBool>,
    committed: bool,
}

impl GenericRouteOwner {
    pub(crate) fn new(
        handle: GenericRouteHandle,
        driver_task: TaskLease,
        receiver_task: TaskLease,
        route_stop: CancellationToken,
        stopping: Arc<AtomicBool>,
    ) -> Self {
        Self {
            handle,
            driver_task,
            receiver_task,
            route_stop,
            stopping,
            committed: false,
        }
    }

    pub(crate) fn handle(&self) -> &GenericRouteHandle {
        &self.handle
    }

    async fn close(mut self) {
        self.stopping.store(true, Ordering::Release);
        if !self.committed {
            self.route_stop.cancel();
            self.receiver_task.cancel().await;
            self.driver_task.cancel().await;
            return;
        }
        self.receiver_task.cancel().await;
        match tokio::time::timeout(GENERIC_ROUTE_CLOSE_TIMEOUT, self.handle.close()).await {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                tracing::debug!(route_id = self.handle.id(), %error, "generic route close failed")
            }
            Err(_) => tracing::debug!(route_id = self.handle.id(), "generic route close timed out"),
        }
        self.route_stop.cancel();
        self.driver_task.cancel().await;
    }
}

impl Drop for GenericRouteOwner {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Release);
        self.route_stop.cancel();
        self.receiver_task.abort_now();
        self.driver_task.abort_now();
    }
}

/// Staged generic route between task startup and physical-path publication.
pub(crate) struct GenericRouteScope {
    owner: Option<GenericRouteOwner>,
    commit: Option<tokio::sync::oneshot::Sender<()>>,
}

impl GenericRouteScope {
    pub(crate) fn new(
        handle: GenericRouteHandle,
        driver_task: TaskLease,
        receiver_task: TaskLease,
        route_stop: CancellationToken,
        stopping: Arc<AtomicBool>,
        commit: tokio::sync::oneshot::Sender<()>,
    ) -> Self {
        Self {
            owner: Some(GenericRouteOwner::new(
                handle,
                driver_task,
                receiver_task,
                route_stop,
                stopping,
            )),
            commit: Some(commit),
        }
    }

    pub(crate) fn profile(&self) -> Option<ConnectionProfile> {
        self.owner.as_ref().map(|owner| owner.handle().profile())
    }

    pub(crate) fn commit_and_take_owner(&mut self) -> Result<GenericRouteOwner, ()> {
        let commit = self.commit.take().ok_or(())?;
        commit.send(()).map_err(|_| ())?;
        let mut owner = self.owner.take().ok_or(())?;
        owner.committed = true;
        Ok(owner)
    }

    pub(crate) async fn close(mut self) {
        if let Some(owner) = self.owner.take() {
            owner.close().await;
        }
    }
}

/// A route carrier owned by the peer path layer. It is intentionally kept
/// separate from ConnectionSessionStore: the store records admission facts,
/// while this value owns the authenticated transport and its I/O handles.
pub(crate) struct ActiveRoute {
    profile: ConnectionProfile,
    carrier: ActiveConnection,
}

enum ActiveConnection {
    Quic(Connection),
    Generic(GenericRouteOwner),
    #[cfg(test)]
    GenericTest(GenericRouteHandle),
    Relay(Option<Arc<RelayDataClient>>),
}

#[derive(Clone)]
enum RouteViewCarrier {
    Quic(Connection),
    Generic(GenericRouteHandle),
    #[cfg(test)]
    GenericTest(GenericRouteHandle),
    Relay(Option<Arc<RelayDataClient>>),
}

/// Cloneable, non-owning I/O projection used by a leased business operation.
#[derive(Clone)]
pub(crate) enum StreamCarrier {
    Quic(Connection),
    Generic(GenericRouteHandle),
    #[cfg(test)]
    GenericTest(GenericRouteHandle),
    Relay(Option<Arc<RelayDataClient>>),
}

impl ActiveRoute {
    pub(crate) fn quic(connection: Connection, route: RouteType) -> Self {
        Self {
            profile: ConnectionProfile::for_route(route)
                .expect("QUIC and Relay route types have a composed profile"),
            carrier: ActiveConnection::Quic(connection),
        }
    }

    pub(crate) fn generic(owner: GenericRouteOwner) -> Self {
        Self {
            profile: owner.handle().profile(),
            carrier: ActiveConnection::Generic(owner),
        }
    }

    #[cfg(test)]
    pub(crate) fn generic_test(handle: GenericRouteHandle) -> Self {
        Self {
            profile: handle.profile(),
            carrier: ActiveConnection::GenericTest(handle),
        }
    }

    pub(crate) fn relay(client: Option<Arc<RelayDataClient>>) -> Self {
        Self {
            profile: ConnectionProfile::new(Route::relay(RouteTransport::WebSocket)),
            carrier: ActiveConnection::Relay(client),
        }
    }

    pub(crate) fn profile(&self) -> ConnectionProfile {
        self.profile
    }

    fn connection(&self) -> Option<Connection> {
        match self.view().carrier {
            RouteViewCarrier::Quic(connection) => Some(connection),
            _ => None,
        }
    }

    fn stream_carrier(&self) -> Option<StreamCarrier> {
        Some(match self.view().carrier {
            RouteViewCarrier::Quic(connection) => StreamCarrier::Quic(connection),
            RouteViewCarrier::Generic(handle) => StreamCarrier::Generic(handle),
            #[cfg(test)]
            RouteViewCarrier::GenericTest(handle) => StreamCarrier::GenericTest(handle),
            RouteViewCarrier::Relay(client) => StreamCarrier::Relay(client),
        })
    }

    fn relay_data(&self) -> Option<Arc<RelayDataClient>> {
        match self.view().carrier {
            RouteViewCarrier::Relay(client) => client,
            _ => None,
        }
    }

    fn view(&self) -> RouteView {
        let carrier = match &self.carrier {
            ActiveConnection::Quic(connection) => RouteViewCarrier::Quic(connection.clone()),
            ActiveConnection::Generic(owner) => RouteViewCarrier::Generic(owner.handle().clone()),
            #[cfg(test)]
            ActiveConnection::GenericTest(handle) => RouteViewCarrier::GenericTest(handle.clone()),
            ActiveConnection::Relay(client) => RouteViewCarrier::Relay(client.clone()),
        };
        RouteView {
            profile: self.profile,
            carrier,
        }
    }

    pub(crate) async fn close(self) {
        match self.carrier {
            ActiveConnection::Quic(connection) => {
                connection.close(VarInt::from_u32(0), b"physical path closed");
            }
            ActiveConnection::Generic(owner) => owner.close().await,
            #[cfg(test)]
            ActiveConnection::GenericTest(handle) => {
                let _ = handle.close().await;
            }
            ActiveConnection::Relay(Some(client)) => client.request_disconnect().await,
            ActiveConnection::Relay(None) => {}
        }
    }
}

#[derive(Clone)]
struct RouteView {
    profile: ConnectionProfile,
    carrier: RouteViewCarrier,
}

async fn send_route_view(
    view: RouteView,
    relay_token: &str,
    kind: GenericFrameKind,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let is_stream = matches!(
        kind,
        GenericFrameKind::StreamBytes
            | GenericFrameKind::StreamOpen
            | GenericFrameKind::StreamClose
    );
    if is_stream
        && !view
            .profile
            .supports(crate::connection::ConnectionCapability::ReliableStream)
        || !is_stream
            && !view
                .profile
                .supports(crate::connection::ConnectionCapability::ReliableMessage)
    {
        return Err(std::io::Error::other("physical path lacks requested capability").into());
    }
    match view.carrier {
        RouteViewCarrier::Quic(connection) => {
            let kind = match kind {
                GenericFrameKind::DataMessage => ChannelFrameKind::DataMessage,
                GenericFrameKind::DeliveryAck => ChannelFrameKind::DeliveryAck,
                _ => {
                    return Err(
                        std::io::Error::other("stream frames require QUIC bi-stream").into(),
                    )
                }
            };
            send_channel_frame(&connection, kind, payload).await
        }
        RouteViewCarrier::Generic(handle) => handle
            .send(kind, payload)
            .await
            .map_err(|error| std::io::Error::other(error.to_string()).into()),
        #[cfg(test)]
        RouteViewCarrier::GenericTest(handle) => handle
            .send(kind, payload)
            .await
            .map_err(|error| std::io::Error::other(error.to_string()).into()),
        RouteViewCarrier::Relay(Some(relay)) => match kind {
            GenericFrameKind::DataMessage => {
                crate::relay::send_relay_channel_message(&relay, relay_token, payload)
                    .await
                    .map_err(|error| std::io::Error::other(error.to_string()).into())
            }
            GenericFrameKind::DeliveryAck => {
                crate::relay::send_relay_channel_ack(&relay, relay_token, payload)
                    .await
                    .map_err(|error| std::io::Error::other(error.to_string()).into())
            }
            GenericFrameKind::StreamBytes
            | GenericFrameKind::StreamOpen
            | GenericFrameKind::StreamClose => {
                crate::relay::send_relay_stream_frame(&relay, relay_token, payload)
                    .await
                    .map_err(|error| std::io::Error::other(error.to_string()).into())
            }
        },
        RouteViewCarrier::Relay(None) => Err(std::io::Error::new(
            std::io::ErrorKind::NotConnected,
            "Relay path unavailable",
        )
        .into()),
    }
}

/// The two path topologies owned by one peer supervisor.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PathKind {
    Direct,
    Relay,
}

impl PathKind {
    fn from_profile(profile: ConnectionProfile) -> Self {
        match profile.topology() {
            RouteTopology::Direct => Self::Direct,
            RouteTopology::Relay => Self::Relay,
        }
    }
}

/// A bounded Direct probe can coexist with an already Ready Direct path.
/// Candidate execution remains in `ConnectivityAttempt`; this value is only
/// the peer-owned lifecycle/selection record.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct DirectProbe {
    pub(crate) generation: u64,
    pub(crate) required_capabilities: u8,
    pub(crate) deadline: Instant,
}

impl DirectProbe {
    fn extend(&mut self, required_capabilities: u8, deadline: Instant) {
        self.required_capabilities |= required_capabilities;
        self.deadline = self.deadline.max(deadline);
    }

    pub(crate) fn is_expired(&self, now: Instant) -> bool {
        now >= self.deadline
    }
}

/// Result of selecting a physical path. The enum never owns a carrier; the
/// caller must acquire a [`PathLease`] for the selected topology.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PathSelection {
    Direct,
    Relay,
}

/// The lifecycle reason delivered to a carrier when its owner closes it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PathCloseReason {
    NormalRetire,
    HardClose,
    SecurityFailure,
}

/// A physical carrier transferred into a [`PhysicalPath`].
///
/// The trait intentionally consumes the carrier on close. This makes the
/// ownership boundary explicit: a handle or lease can never close a carrier
/// without the physical-path owner first revoking or retiring it. Production
/// adapters can wrap a QUIC connection, generic route owner, or Relay data
/// client in this trait without changing the path state machine or wire
/// contract.
pub(crate) trait PathCarrier: Send + 'static {
    fn close(self: Box<Self>, reason: PathCloseReason);

    fn connection(&self) -> Option<Connection> {
        None
    }

    fn stream_carrier(&self) -> Option<StreamCarrier> {
        None
    }

    fn relay_data(&self) -> Option<Arc<RelayDataClient>> {
        None
    }

    fn send_channel_frame(
        &self,
        _relay_token: &str,
        _kind: GenericFrameKind,
        _payload: &[u8],
    ) -> PathIoFuture {
        Box::pin(async {
            Err(std::io::Error::new(
                std::io::ErrorKind::NotConnected,
                "physical path I/O unavailable",
            )
            .into())
        })
    }
}

/// A metadata-only carrier used by the compatibility helper and unit tests.
/// Real connection admission should use
/// [`PeerPathManager::publish_ready_with_carrier`].
struct NoopPathCarrier;

impl PathCarrier for NoopPathCarrier {
    fn close(self: Box<Self>, _reason: PathCloseReason) {}
}

/// Adapter used by the path owner when a caller has an authenticated
/// [`ActiveRoute`] in hand. The route is moved into the physical path; a
/// projection or handle never receives a clone of it.
struct ActiveRouteCarrier {
    route: Option<ActiveRoute>,
}

impl PathCarrier for ActiveRouteCarrier {
    fn close(mut self: Box<Self>, _reason: PathCloseReason) {
        let Some(route) = self.route.take() else {
            return;
        };
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(async move { route.close().await });
        }
    }

    fn connection(&self) -> Option<Connection> {
        self.route.as_ref().and_then(ActiveRoute::connection)
    }

    fn stream_carrier(&self) -> Option<StreamCarrier> {
        self.route.as_ref().and_then(ActiveRoute::stream_carrier)
    }

    fn relay_data(&self) -> Option<Arc<RelayDataClient>> {
        self.route.as_ref().and_then(ActiveRoute::relay_data)
    }

    fn send_channel_frame(
        &self,
        relay_token: &str,
        kind: GenericFrameKind,
        payload: &[u8],
    ) -> PathIoFuture {
        let Some(view) = self.route.as_ref().map(ActiveRoute::view) else {
            return Box::pin(async {
                Err(std::io::Error::new(
                    std::io::ErrorKind::NotConnected,
                    "physical path unavailable",
                )
                .into())
            });
        };
        let relay_token = relay_token.to_owned();
        let payload = payload.to_owned();
        Box::pin(async move { send_route_view(view, &relay_token, kind, &payload).await })
    }
}

/// Convenient adapter for callers that already own a concrete carrier and
/// only need to supply its close operation to the path owner.
struct CallbackPathCarrier {
    close: Option<Box<dyn FnOnce(PathCloseReason) + Send>>,
}

impl PathCarrier for CallbackPathCarrier {
    fn close(mut self: Box<Self>, reason: PathCloseReason) {
        if let Some(close) = self.close.take() {
            close(reason);
        }
    }
}

pub(crate) fn callback_path_carrier<F>(close: F) -> Box<dyn PathCarrier>
where
    F: FnOnce(PathCloseReason) + Send + 'static,
{
    Box::new(CallbackPathCarrier {
        close: Some(Box::new(close)),
    })
}

/// A non-owning identity for one physical path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PathHandle {
    id: u64,
    peer_id: PeerId,
    profile: ConnectionProfile,
    capability_mask: u8,
}

impl PathHandle {
    pub(crate) fn id(&self) -> u64 {
        self.id
    }

    pub(crate) fn peer_id(&self) -> &PeerId {
        &self.peer_id
    }

    pub(crate) fn profile(&self) -> ConnectionProfile {
        self.profile
    }

    pub(crate) fn capability_mask(&self) -> u8 {
        self.capability_mask
    }

    pub(crate) fn kind(&self) -> PathKind {
        PathKind::from_profile(self.profile)
    }
}

/// A non-owning runtime projection of a path. It is safe to retain as an
/// index entry, but it cannot keep the physical carrier alive. An operation
/// must explicitly upgrade it into a [`PathLease`] before using the path.
#[derive(Clone)]
pub(crate) struct PathProjection {
    handle: PathHandle,
    path: Weak<PhysicalPath>,
}

impl PathProjection {
    pub(crate) fn handle(&self) -> &PathHandle {
        &self.handle
    }

    pub(crate) fn is_alive(&self) -> bool {
        self.path.upgrade().is_some_and(|path| path.is_active())
    }

    pub(crate) fn acquire(&self) -> Result<PathLease, CoreNetworkError> {
        let path = self.path.upgrade().ok_or(CoreNetworkError::StaleAttempt)?;
        if path.handle() != &self.handle {
            return Err(CoreNetworkError::StaleAttempt);
        }
        path.try_acquire()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PhysicalPathState {
    Ready,
    Draining,
    Closed(PathCloseReason),
}

struct PhysicalPathInner {
    state: PhysicalPathState,
    carrier: Option<Box<dyn PathCarrier>>,
    leases: usize,
    last_activity: Instant,
}

/// The sole owner of one authenticated Direct or Relay carrier.
pub(crate) struct PhysicalPath {
    handle: PathHandle,
    inner: Mutex<PhysicalPathInner>,
}

impl PhysicalPath {
    fn new(handle: PathHandle, carrier: Box<dyn PathCarrier>, created_at: Instant) -> Arc<Self> {
        Arc::new(Self {
            handle,
            inner: Mutex::new(PhysicalPathInner {
                state: PhysicalPathState::Ready,
                carrier: Some(carrier),
                leases: 0,
                last_activity: created_at,
            }),
        })
    }

    fn handle(&self) -> &PathHandle {
        &self.handle
    }

    fn profile(&self) -> ConnectionProfile {
        self.handle.profile()
    }

    fn supports(&self, required_capabilities: u8) -> bool {
        self.handle.capability_mask() & required_capabilities == required_capabilities
    }

    fn is_ready(&self) -> bool {
        matches!(
            self.inner.lock().expect("physical path lock").state,
            PhysicalPathState::Ready
        )
    }

    fn is_active(&self) -> bool {
        matches!(
            self.inner.lock().expect("physical path lock").state,
            PhysicalPathState::Ready | PhysicalPathState::Draining
        )
    }

    fn is_acquirable(&self, required_capabilities: u8) -> bool {
        let inner = self.inner.lock().expect("physical path lock");
        matches!(inner.state, PhysicalPathState::Ready) && self.supports(required_capabilities)
    }

    fn lease_count(&self) -> usize {
        self.inner.lock().expect("physical path lock").leases
    }

    fn has_carrier(&self) -> bool {
        self.inner
            .lock()
            .expect("physical path lock")
            .carrier
            .is_some()
    }

    fn connection(&self) -> Option<Connection> {
        self.inner
            .lock()
            .expect("physical path lock")
            .carrier
            .as_ref()
            .and_then(|carrier| carrier.connection())
    }

    fn stream_carrier(&self) -> Option<StreamCarrier> {
        self.inner
            .lock()
            .expect("physical path lock")
            .carrier
            .as_ref()
            .and_then(|carrier| carrier.stream_carrier())
    }

    fn relay_data(&self) -> Option<Arc<RelayDataClient>> {
        self.inner
            .lock()
            .expect("physical path lock")
            .carrier
            .as_ref()
            .and_then(|carrier| carrier.relay_data())
    }

    async fn send_channel_frame(
        &self,
        relay_token: &str,
        kind: GenericFrameKind,
        payload: &[u8],
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let send = {
            let inner = self.inner.lock().expect("physical path lock");
            inner
                .carrier
                .as_ref()
                .map(|carrier| carrier.send_channel_frame(relay_token, kind, payload))
        };
        match send {
            Some(send) => send.await,
            None => Err(std::io::Error::new(
                std::io::ErrorKind::NotConnected,
                "physical path unavailable",
            )
            .into()),
        }
    }

    fn try_acquire(self: &Arc<Self>) -> Result<PathLease, CoreNetworkError> {
        let mut inner = self.inner.lock().expect("physical path lock");
        if !matches!(inner.state, PhysicalPathState::Ready) {
            return Err(CoreNetworkError::StaleAttempt);
        }
        if inner.leases >= MAX_PATH_LEASES {
            return Err(CoreNetworkError::ResourceLimit("path leases"));
        }
        inner.leases += 1;
        inner.last_activity = Instant::now();
        Ok(PathLease {
            handle: self.handle.clone(),
            path: Arc::clone(self),
            released: false,
        })
    }

    fn retire_normal(&self) -> bool {
        let carrier = {
            let mut inner = self.inner.lock().expect("physical path lock");
            match inner.state {
                PhysicalPathState::Ready => {
                    inner.state = PhysicalPathState::Draining;
                }
                PhysicalPathState::Draining => {}
                PhysicalPathState::Closed(_) => return false,
            }
            if inner.leases == 0 {
                inner.state = PhysicalPathState::Closed(PathCloseReason::NormalRetire);
                inner.carrier.take()
            } else {
                None
            }
        };
        close_carrier(carrier, PathCloseReason::NormalRetire);
        true
    }

    fn close_with_reason(&self, reason: PathCloseReason) -> bool {
        let carrier = {
            let mut inner = self.inner.lock().expect("physical path lock");
            if matches!(inner.state, PhysicalPathState::Closed(_)) {
                return false;
            }
            inner.state = PhysicalPathState::Closed(reason);
            inner.carrier.take()
        };
        close_carrier(carrier, reason);
        true
    }

    fn release_lease(&self) {
        let carrier = {
            let mut inner = self.inner.lock().expect("physical path lock");
            if inner.leases == 0 {
                return;
            }
            inner.leases -= 1;
            if inner.leases == 0 && matches!(inner.state, PhysicalPathState::Draining) {
                inner.state = PhysicalPathState::Closed(PathCloseReason::NormalRetire);
                inner.carrier.take()
            } else {
                if matches!(inner.state, PhysicalPathState::Ready) {
                    inner.last_activity = Instant::now();
                }
                None
            }
        };
        close_carrier(carrier, PathCloseReason::NormalRetire);
    }

    fn record_activity(&self) {
        let mut inner = self.inner.lock().expect("physical path lock");
        if matches!(inner.state, PhysicalPathState::Ready) {
            inner.last_activity = Instant::now();
        }
    }

    fn is_ephemeral_idle(&self, now: Instant) -> bool {
        let inner = self.inner.lock().expect("physical path lock");
        matches!(inner.state, PhysicalPathState::Ready)
            && inner.leases == 0
            && now.saturating_duration_since(inner.last_activity)
                >= super::EPHEMERAL_PATH_IDLE_TIMEOUT
    }
}

impl Drop for PhysicalPath {
    fn drop(&mut self) {
        // A manager normally retires or hard-closes before dropping its last
        // owner. This guard keeps an unexpected owner drop from leaking the
        // transferred carrier.
        let _ = self.close_with_reason(PathCloseReason::HardClose);
    }
}

fn close_carrier(carrier: Option<Box<dyn PathCarrier>>, reason: PathCloseReason) {
    if let Some(carrier) = carrier {
        carrier.close(reason);
    }
}

/// An explicit reservation held by one business operation.
///
/// The lease owns only a reference to the peer-owned [`PhysicalPath`]. It
/// never owns the carrier and cannot make a new lease after retirement.
pub(crate) struct PathLease {
    handle: PathHandle,
    path: Arc<PhysicalPath>,
    released: bool,
}

impl PathLease {
    pub(crate) fn handle(&self) -> &PathHandle {
        &self.handle
    }

    pub(crate) fn profile(&self) -> ConnectionProfile {
        self.handle.profile()
    }

    /// Borrow the underlying QUIC connection for the duration of this lease.
    /// The returned connection is an I/O handle, never an independent path
    /// owner.
    pub(crate) fn connection(&self) -> Option<Connection> {
        self.path.connection()
    }

    /// Borrow a cloneable transport I/O view while this lease is active.
    pub(crate) fn stream_carrier(&self) -> Option<StreamCarrier> {
        self.path.stream_carrier()
    }

    pub(crate) fn relay_data(&self) -> Option<Arc<RelayDataClient>> {
        self.path.relay_data()
    }

    pub(crate) async fn send_channel_frame(
        &self,
        relay_token: &str,
        kind: GenericFrameKind,
        payload: &[u8],
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.path
            .send_channel_frame(relay_token, kind, payload)
            .await
    }

    /// A hard close or security failure becomes visible to existing borrowers
    /// immediately. A normal drain remains active until the last lease is
    /// released, at which point the carrier is closed.
    pub(crate) fn is_active(&self) -> bool {
        self.path.is_active()
    }

    /// Explicitly release this business reservation. `Drop` remains the
    /// safety net for callers that leave the operation through an error path.
    pub(crate) fn release(mut self) {
        self.release_inner();
    }

    #[cfg(test)]
    fn lease_count(&self) -> usize {
        self.path.lease_count()
    }

    fn release_inner(&mut self) {
        if !self.released {
            self.released = true;
            self.path.release_lease();
        }
    }
}

impl Drop for PathLease {
    fn drop(&mut self) {
        self.release_inner();
    }
}

/// Weak path index used by runtime-level peer teardown and by borrowed handle
/// lookup. It never owns a carrier; the corresponding [`PeerPathManager`]
/// owns every strong [`PhysicalPath`] reference.
#[derive(Default)]
pub(crate) struct PathRegistry {
    next_id: AtomicU64,
    paths: Mutex<HashMap<PeerId, HashMap<u64, Weak<PhysicalPath>>>>,
}

impl PathRegistry {
    pub(crate) fn new() -> Self {
        Self {
            next_id: AtomicU64::new(1),
            paths: Mutex::new(HashMap::new()),
        }
    }

    fn create_path(
        &self,
        peer_id: &PeerId,
        profile: ConnectionProfile,
        carrier: Box<dyn PathCarrier>,
        created_at: Instant,
    ) -> Result<Arc<PhysicalPath>, CoreNetworkError> {
        let capability_mask = super::profile_capability_mask(profile);
        if capability_mask == 0 {
            carrier.close(PathCloseReason::HardClose);
            return Err(CoreNetworkError::CapabilityUnavailable);
        }

        let mut paths = self.paths.lock().expect("path registry lock");
        let peer_paths = paths.entry(peer_id.clone()).or_default();
        peer_paths.retain(|_, path| path.strong_count() > 0);
        if peer_paths.len() >= MAX_READY_PATHS_PER_PEER {
            carrier.close(PathCloseReason::HardClose);
            return Err(CoreNetworkError::ResourceLimit("ready paths"));
        }

        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let handle = PathHandle {
            id,
            peer_id: peer_id.clone(),
            profile,
            capability_mask,
        };
        let path = PhysicalPath::new(handle, carrier, created_at);
        peer_paths.insert(id, Arc::downgrade(&path));
        Ok(path)
    }

    fn lookup(&self, handle: &PathHandle) -> Option<Arc<PhysicalPath>> {
        let mut paths = self.paths.lock().expect("path registry lock");
        let peer_id = handle.peer_id().clone();
        let (path, empty) = match paths.get_mut(&peer_id) {
            Some(peer_paths) => {
                let path = peer_paths
                    .get(&handle.id())
                    .and_then(Weak::upgrade)
                    .filter(|path| path.handle() == handle);
                if path.is_none() {
                    peer_paths.remove(&handle.id());
                }
                (path, peer_paths.is_empty())
            }
            None => (None, false),
        };
        if empty {
            paths.remove(&peer_id);
        }
        path
    }

    fn take_entry(&self, handle: &PathHandle) -> Option<Weak<PhysicalPath>> {
        let mut paths = self.paths.lock().expect("path registry lock");
        let peer_id = handle.peer_id().clone();
        let (entry, empty) = match paths.get_mut(&peer_id) {
            Some(peer_paths) => {
                let entry = peer_paths.remove(&handle.id());
                (entry, peer_paths.is_empty())
            }
            None => (None, false),
        };
        if empty {
            paths.remove(&peer_id);
        }
        entry
    }

    pub(crate) fn acquire(&self, handle: &PathHandle) -> Result<PathLease, CoreNetworkError> {
        self.lookup(handle)
            .ok_or(CoreNetworkError::StaleAttempt)?
            .try_acquire()
    }

    /// Select the best indexed ready path for a capability without making the
    /// registry a route owner. A stale weak entry is simply skipped.
    pub(crate) fn select_compatible_ready_path(
        &self,
        peer_id: &PeerId,
        required_capabilities: u8,
    ) -> Result<PathLease, CoreNetworkError> {
        let candidates = {
            let mut paths = self.paths.lock().expect("path registry lock");
            let Some(peer_paths) = paths.get_mut(peer_id) else {
                return Err(CoreNetworkError::NoRoute);
            };
            let candidates = peer_paths
                .values()
                .filter_map(Weak::upgrade)
                .collect::<Vec<_>>();
            peer_paths.retain(|_, path| path.strong_count() > 0);
            candidates
        };

        let mut candidates = candidates;
        candidates.sort_by_key(|path| (path_preference(path.profile()), path.handle().id()));
        for path in candidates.into_iter().rev() {
            if !path.is_acquirable(required_capabilities) {
                continue;
            }
            match path.try_acquire() {
                Ok(lease) => return Ok(lease),
                Err(CoreNetworkError::StaleAttempt) => continue,
                Err(error) => return Err(error),
            }
        }
        Err(CoreNetworkError::NoRoute)
    }

    pub(crate) fn revoke(&self, handle: &PathHandle) -> bool {
        let Some(entry) = self.take_entry(handle) else {
            return false;
        };
        if let Some(path) = entry.upgrade() {
            path.close_with_reason(PathCloseReason::HardClose);
        }
        true
    }

    /// Normal retirement removes the weak index immediately, then lets the
    /// physical owner close after any existing leases drain.
    pub(crate) fn drain(&self, handle: &PathHandle) -> bool {
        let Some(entry) = self.take_entry(handle) else {
            return false;
        };
        if let Some(path) = entry.upgrade() {
            path.retire_normal();
        }
        true
    }

    pub(crate) fn security_failure(&self, handle: &PathHandle) -> bool {
        let Some(entry) = self.take_entry(handle) else {
            return false;
        };
        if let Some(path) = entry.upgrade() {
            path.close_with_reason(PathCloseReason::SecurityFailure);
        }
        true
    }

    pub(crate) fn lease_count(&self, handle: &PathHandle) -> Option<usize> {
        self.lookup(handle).map(|path| path.lease_count())
    }

    fn is_acquirable(&self, handle: &PathHandle) -> bool {
        self.lookup(handle)
            .is_some_and(|path| path.is_acquirable(0))
    }

    pub(crate) fn revoke_peer(&self, peer_id: &PeerId) -> usize {
        let entries = self
            .paths
            .lock()
            .expect("path registry lock")
            .remove(peer_id)
            .map(|paths| paths.into_values().collect::<Vec<_>>())
            .unwrap_or_default();
        let count = entries.len();
        for entry in entries {
            if let Some(path) = entry.upgrade() {
                path.close_with_reason(PathCloseReason::HardClose);
            }
        }
        count
    }
}

/// Direct path state. A ready Direct path may have a separate bounded probe
/// in flight; [`PeerPathManager::direct_probe`] exposes that demand.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum DirectPathState {
    None,
    Probe,
    Ready,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RelayPathState {
    None,
    Ready,
}

/// Per-peer physical path owner. Direct and Relay are independent slots, so
/// both may be Ready at once; business selection happens only when a caller
/// requests a capability and acquires a lease.
pub(crate) struct PeerPathManager {
    peer_id: PeerId,
    registry: Arc<PathRegistry>,
    direct_path: Option<Arc<PhysicalPath>>,
    direct_ready: Vec<PathHandle>,
    relay_path: Option<Arc<PhysicalPath>>,
    relay_ready: Option<PathHandle>,
    draining_paths: Vec<Arc<PhysicalPath>>,
    direct_probe: Option<DirectProbe>,
    draining: bool,
    hard_closed: bool,
}

impl PeerPathManager {
    pub(crate) fn new(peer_id: PeerId, registry: Arc<PathRegistry>) -> Self {
        Self {
            peer_id,
            registry,
            direct_path: None,
            direct_ready: Vec::new(),
            relay_path: None,
            relay_ready: None,
            draining_paths: Vec::new(),
            direct_probe: None,
            draining: false,
            hard_closed: false,
        }
    }

    pub(crate) fn peer_id(&self) -> &PeerId {
        &self.peer_id
    }

    /// Kept as a one-element slice for compatibility with existing path
    /// observations. The actual carrier is held by `direct_path`.
    pub(crate) fn direct_ready(&self) -> &[PathHandle] {
        &self.direct_ready
    }

    pub(crate) fn relay_ready(&self) -> Option<&PathHandle> {
        self.relay_ready.as_ref()
    }

    /// Return a weak projection tied to this manager's path identity. This is
    /// the integration seam for RuntimeState: it can index a PathHandle or
    /// PathProjection without retaining a second carrier lifetime owner.
    pub(crate) fn projection(&self, handle: &PathHandle) -> Option<PathProjection> {
        self.path_for_handle(handle).map(|path| PathProjection {
            handle: path.handle().clone(),
            path: Arc::downgrade(path),
        })
    }

    /// Transfer an authenticated route into the peer path owner. The route's
    /// carrier is moved into `PhysicalPath`; callers retain only the returned
    /// non-owning handle/projection and later acquire a `PathLease`.
    pub(crate) fn publish_ready_with_route(
        &mut self,
        route: ActiveRoute,
    ) -> Result<PathHandle, CoreNetworkError> {
        let profile = route.profile();
        self.publish_ready_with_carrier(
            profile,
            Box::new(ActiveRouteCarrier { route: Some(route) }),
        )
    }

    pub(crate) fn direct_state(&self) -> DirectPathState {
        if self
            .direct_path
            .as_ref()
            .is_some_and(|path| path.is_ready())
        {
            DirectPathState::Ready
        } else if self.direct_probe.is_some() {
            DirectPathState::Probe
        } else {
            DirectPathState::None
        }
    }

    pub(crate) fn relay_state(&self) -> RelayPathState {
        if self.relay_path.as_ref().is_some_and(|path| path.is_ready()) {
            RelayPathState::Ready
        } else {
            RelayPathState::None
        }
    }

    pub(crate) fn direct_probe(&self) -> Option<&DirectProbe> {
        self.direct_probe.as_ref()
    }

    pub(crate) fn publish_ready(
        &mut self,
        profile: ConnectionProfile,
    ) -> Result<PathHandle, CoreNetworkError> {
        self.publish_ready_with_carrier_at(profile, Box::new(NoopPathCarrier), Instant::now())
    }

    pub(crate) fn publish_ready_with_carrier(
        &mut self,
        profile: ConnectionProfile,
        carrier: Box<dyn PathCarrier>,
    ) -> Result<PathHandle, CoreNetworkError> {
        self.publish_ready_with_carrier_at(profile, carrier, Instant::now())
    }

    fn publish_ready_with_carrier_at(
        &mut self,
        profile: ConnectionProfile,
        carrier: Box<dyn PathCarrier>,
        created_at: Instant,
    ) -> Result<PathHandle, CoreNetworkError> {
        if self.draining || self.hard_closed {
            return Err(CoreNetworkError::Cancelled);
        }

        let kind = PathKind::from_profile(profile);
        let new_capability_mask = super::profile_capability_mask(profile);
        if new_capability_mask == 0 {
            carrier.close(PathCloseReason::HardClose);
            return Err(CoreNetworkError::CapabilityUnavailable);
        }

        // A path can be closed externally through the weak registry during
        // peer teardown. Do not let that dead slot block the next
        // authenticated publication.
        match kind {
            PathKind::Direct
                if self
                    .direct_path
                    .as_ref()
                    .is_some_and(|path| !path.is_ready()) =>
            {
                self.take_direct();
            }
            PathKind::Relay
                if self
                    .relay_path
                    .as_ref()
                    .is_some_and(|path| !path.is_ready()) =>
            {
                self.take_relay();
            }
            _ => {}
        }

        let old_path = match kind {
            PathKind::Direct => self.direct_path.as_ref(),
            PathKind::Relay => self.relay_path.as_ref(),
        };

        if let Some(old_path) = old_path {
            let old_capability_mask = old_path.handle().capability_mask();
            let needed_capabilities = match kind {
                PathKind::Direct => self
                    .direct_probe
                    .as_ref()
                    .map(|probe| probe.required_capabilities),
                PathKind::Relay => None,
            };
            let strict_needed_superset = new_capability_mask != old_capability_mask
                && new_capability_mask & old_capability_mask == old_capability_mask
                && needed_capabilities.is_some_and(|needed| new_capability_mask & needed == needed);

            // Once a compatible Ready path exists, it is the winner. An
            // equivalent or weaker late path is a failed attempt, not a
            // replacement. Only a capability superset needed by an active
            // Direct demand may promote and normal-retire the old path.
            if !strict_needed_superset {
                carrier.close(PathCloseReason::HardClose);
                return Err(CoreNetworkError::StaleAttempt);
            }
        } else if kind == PathKind::Direct
            && self.direct_probe.as_ref().is_some_and(|probe| {
                new_capability_mask & probe.required_capabilities != probe.required_capabilities
            })
        {
            // With no Ready path, the first authenticated path still has to
            // satisfy the capability that caused the Direct probe.
            carrier.close(PathCloseReason::HardClose);
            return Err(CoreNetworkError::CapabilityUnavailable);
        }

        let path = self
            .registry
            .create_path(&self.peer_id, profile, carrier, created_at)?;
        let handle = path.handle().clone();
        let old_path = match kind {
            PathKind::Direct => self.take_direct(),
            PathKind::Relay => self.take_relay(),
        };
        if let Some(old_path) = old_path {
            self.retire_path(old_path, PathCloseReason::NormalRetire);
        }
        match kind {
            PathKind::Direct => {
                self.direct_ready.push(handle.clone());
                self.direct_path = Some(path);
                self.direct_probe = None;
            }
            PathKind::Relay => {
                self.relay_ready = Some(handle.clone());
                self.relay_path = Some(path);
            }
        }
        Ok(handle)
    }

    /// Start or extend one Direct probe. A stronger request extends the
    /// current demand rather than creating another physical establishment.
    pub(crate) fn ensure_direct_probe(
        &mut self,
        generation: u64,
        required_capabilities: u8,
        budget: Duration,
    ) -> Result<&DirectProbe, CoreNetworkError> {
        if self.draining || self.hard_closed {
            return Err(CoreNetworkError::Cancelled);
        }
        let deadline = Instant::now() + budget;
        match self.direct_probe.as_mut() {
            Some(probe) => {
                if probe.generation != generation {
                    return Err(CoreNetworkError::StaleAttempt);
                }
                probe.extend(required_capabilities, deadline);
            }
            None => {
                self.direct_probe = Some(DirectProbe {
                    generation,
                    required_capabilities,
                    deadline,
                });
            }
        }
        Ok(self.direct_probe.as_ref().expect("probe just installed"))
    }

    pub(crate) fn finish_direct_probe(&mut self, generation: u64) -> bool {
        if self
            .direct_probe
            .as_ref()
            .is_some_and(|probe| probe.generation == generation)
        {
            self.direct_probe = None;
            true
        } else {
            false
        }
    }

    /// Select Direct immediately when compatible. If it is unavailable, an
    /// already Ready Relay is usable while Direct probing continues.
    pub(crate) fn select(&self, required_capabilities: u8) -> Option<PathSelection> {
        if self
            .direct_path
            .as_ref()
            .is_some_and(|path| path.is_acquirable(required_capabilities))
        {
            return Some(PathSelection::Direct);
        }
        if self
            .relay_path
            .as_ref()
            .is_some_and(|path| path.is_acquirable(required_capabilities))
        {
            return Some(PathSelection::Relay);
        }
        None
    }

    pub(crate) fn acquire(
        &self,
        required_capabilities: u8,
    ) -> Result<(PathSelection, PathLease), CoreNetworkError> {
        if let Some(path) = self.direct_path.as_ref() {
            if path.is_acquirable(required_capabilities) {
                match path.try_acquire() {
                    Ok(lease) => return Ok((PathSelection::Direct, lease)),
                    Err(CoreNetworkError::StaleAttempt) => {}
                    Err(error) => return Err(error),
                }
            }
        }
        if let Some(path) = self.relay_path.as_ref() {
            if path.is_acquirable(required_capabilities) {
                match path.try_acquire() {
                    Ok(lease) => return Ok((PathSelection::Relay, lease)),
                    Err(CoreNetworkError::StaleAttempt) => {}
                    Err(error) => return Err(error),
                }
            }
        }
        Err(CoreNetworkError::NoRoute)
    }

    pub(crate) fn normal_drain(&mut self) {
        self.draining = true;
        self.direct_probe = None;
        self.retire_all(PathCloseReason::NormalRetire);
        self.reap_draining_paths();
    }

    pub(crate) fn hard_close(&mut self) {
        self.hard_closed = true;
        self.draining = true;
        self.direct_probe = None;
        self.retire_all(PathCloseReason::HardClose);
        self.close_draining_paths(PathCloseReason::HardClose);
    }

    pub(crate) fn hard_close_relay(&mut self) {
        if let Some(path) = self.take_relay() {
            self.retire_path(path, PathCloseReason::HardClose);
        }
    }

    pub(crate) fn hard_close_direct(&mut self) {
        self.direct_probe = None;
        if let Some(path) = self.take_direct() {
            self.retire_path(path, PathCloseReason::HardClose);
        }
    }

    /// Security failures use the hard-close path so no existing lease can
    /// keep a compromised carrier usable.
    pub(crate) fn security_failure(&mut self) {
        self.hard_closed = true;
        self.draining = true;
        self.direct_probe = None;
        self.retire_all(PathCloseReason::SecurityFailure);
        self.close_draining_paths(PathCloseReason::SecurityFailure);
    }

    pub(crate) fn record_activity(&self) {
        if let Some(path) = self.direct_path.as_ref() {
            path.record_activity();
        }
        if let Some(path) = self.relay_path.as_ref() {
            path.record_activity();
        }
    }

    /// Retire every Ready path that has had no borrower for the fixed 60s
    /// ephemeral-path window. The caller supplies `now` so tests do not sleep.
    pub(crate) fn retire_ephemeral(&mut self, now: Instant) -> usize {
        if self.draining || self.hard_closed {
            return 0;
        }

        let direct_expired = self
            .direct_path
            .as_ref()
            .is_some_and(|path| path.is_ephemeral_idle(now));
        let relay_expired = self
            .relay_path
            .as_ref()
            .is_some_and(|path| path.is_ephemeral_idle(now));
        let mut retired = 0;
        if direct_expired {
            if let Some(path) = self.take_direct() {
                self.retire_path(path, PathCloseReason::NormalRetire);
                retired += 1;
            }
        }
        if relay_expired {
            if let Some(path) = self.take_relay() {
                self.retire_path(path, PathCloseReason::NormalRetire);
                retired += 1;
            }
        }
        retired
    }

    pub(crate) fn ephemeral_idle(&self, now: Instant) -> bool {
        !self.draining
            && !self.hard_closed
            && (self.direct_path.is_some() || self.relay_path.is_some())
            && self
                .direct_path
                .as_ref()
                .is_none_or(|path| path.is_ephemeral_idle(now))
            && self
                .relay_path
                .as_ref()
                .is_none_or(|path| path.is_ephemeral_idle(now))
    }

    fn take_direct(&mut self) -> Option<Arc<PhysicalPath>> {
        self.direct_ready.clear();
        self.direct_path.take()
    }

    fn take_relay(&mut self) -> Option<Arc<PhysicalPath>> {
        self.relay_ready = None;
        self.relay_path.take()
    }

    fn path_for_handle(&self, handle: &PathHandle) -> Option<&Arc<PhysicalPath>> {
        self.direct_path
            .as_ref()
            .filter(|path| path.handle() == handle)
            .or_else(|| {
                self.relay_path
                    .as_ref()
                    .filter(|path| path.handle() == handle)
            })
            .or_else(|| {
                self.draining_paths
                    .iter()
                    .find(|path| path.handle() == handle)
            })
    }

    fn retire_path(&mut self, path: Arc<PhysicalPath>, reason: PathCloseReason) {
        let handle = path.handle().clone();
        match reason {
            PathCloseReason::NormalRetire => {
                let _ = self.registry.drain(&handle);
                path.retire_normal();
                if path.is_active() {
                    self.draining_paths.push(path);
                }
            }
            PathCloseReason::HardClose => {
                let _ = self.registry.revoke(&handle);
                path.close_with_reason(PathCloseReason::HardClose);
            }
            PathCloseReason::SecurityFailure => {
                let _ = self.registry.security_failure(&handle);
                path.close_with_reason(PathCloseReason::SecurityFailure);
            }
        }
    }

    fn close_draining_paths(&mut self, reason: PathCloseReason) {
        for path in self.draining_paths.drain(..) {
            path.close_with_reason(reason);
        }
    }

    fn reap_draining_paths(&mut self) {
        self.draining_paths.retain(|path| path.is_active());
    }

    fn retire_all(&mut self, reason: PathCloseReason) {
        let direct = self.take_direct();
        let relay = self.take_relay();
        if let Some(path) = direct {
            self.retire_path(path, reason);
        }
        if let Some(path) = relay {
            self.retire_path(path, reason);
        }
    }
}

impl Drop for PeerPathManager {
    fn drop(&mut self) {
        self.hard_close();
    }
}

fn path_preference(profile: ConnectionProfile) -> u8 {
    match (profile.topology(), profile.transport()) {
        (RouteTopology::Direct, RouteTransport::Quic) => 4,
        (RouteTopology::Direct, RouteTransport::Tcp) => 3,
        (RouteTopology::Direct, RouteTransport::WebSocket) => 2,
        (RouteTopology::Relay, _) => 1,
        _ => 0,
    }
}

#[cfg(test)]
#[path = "../tests/connect/path.rs"]
mod tests;
