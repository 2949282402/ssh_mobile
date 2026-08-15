//! Session 生命周期与当前 transport connection 的隔离。

use network_protocol::RouteType;
use network_quic::{send_channel_frame, ChannelFrameKind};
use network_relay::RelayClient;
use quinn::{Connection, VarInt};
use rand::{rngs::OsRng, RngCore};
use std::collections::HashMap;
use std::ops::Deref;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::Duration;
use tokio::sync::{oneshot, RwLock};
use tokio::time::timeout;

use crate::connection::{
    ConnectionCapability, ConnectionProfile, GenericFrameKind, GenericRouteHandle, Route,
    RouteTransport,
};
use crate::task_supervisor::{CancellationToken, TaskLease};

/// 标识一次跨 Connection 的业务会话。
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) struct SessionId([u8; SESSION_ID_BYTES]);

pub(crate) const SESSION_ID_BYTES: usize = 16;

/// Session 自身的生命周期；Connection 断开只会让 Session 进入
/// Disconnected，而不会销毁 Session。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum SessionState {
    Idle,
    Connecting,
    Connected,
    Reconnecting,
    Disconnected,
    Closed,
    Failed,
}

/// 当前连接尝试对已有 Session 的处理结果。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ConnectDecision {
    Started(SessionId),
    AlreadyConnected(SessionId),
    InProgress(SessionId),
}

/// Decides whether authenticated handshake material belongs to the current
/// logical Session or starts a new one.  The decision is made from the
/// peer's binding, never from a transport route or a local alias.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum SessionCryptoDecision {
    Initialize,
    ContinueExisting,
    ReplaceWithNew,
}

/// Compare a newly authenticated peer binding with the binding recorded by
/// the current logical Session.
pub(crate) fn evaluate_remote_session(
    current_remote_binding: Option<&str>,
    new_remote_binding: &str,
) -> SessionCryptoDecision {
    match current_remote_binding {
        None => SessionCryptoDecision::Initialize,
        Some(current) if current == new_remote_binding => SessionCryptoDecision::ContinueExisting,
        Some(_) => SessionCryptoDecision::ReplaceWithNew,
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct SessionAdmission {
    pub(crate) session_id: SessionId,
    pub(crate) decision: SessionCryptoDecision,
    pub(crate) replaced_session_id: Option<SessionId>,
}

/// Result of the Session continuity decision.  The old route is detached but
/// deliberately not closed here: closing a carrier is the Runtime/Session
/// lifecycle owner's job, and GenericRoute carries supervised task leases that
/// must be stopped outside the Session lock.
pub(crate) struct SessionAdmissionOutcome {
    pub(crate) admission: SessionAdmission,
    pub(crate) detached_route: Option<ActiveRoute>,
}

impl Deref for SessionAdmissionOutcome {
    type Target = SessionAdmission;

    fn deref(&self) -> &Self::Target {
        &self.admission
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum SessionAdmissionError {
    StaleSession,
    InvalidRemoteBinding,
}

/// Session 聚合根只放置 Connection 生命周期和当前 Route；Delivery/Crypto/
/// Transfer 状态在外部按这个 SessionId 关联，不能回退到 Connection map。
struct Session {
    id: SessionId,
    remote_session_binding: Option<String>,
    state: SessionState,
    route: Option<ActiveRoute>,
}

const GENERIC_ROUTE_CLOSE_TIMEOUT: Duration = Duration::from_secs(1);

/// Owns the GenericRoute driver and receiver task leases as one route-local
/// resource.  The Session owns this value after atomic attach/commit.
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

    fn handle(&self) -> &GenericRouteHandle {
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
        // Stop the consumer first. Its drop guard observes `stopping` and
        // therefore does not race a graceful command-channel close.
        self.receiver_task.cancel().await;

        let close_result = timeout(GENERIC_ROUTE_CLOSE_TIMEOUT, self.handle.close()).await;
        match close_result {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                tracing::debug!(route_id = self.handle.id(), %error, "generic route graceful close failed");
            }
            Err(_) => {
                tracing::debug!(
                    route_id = self.handle.id(),
                    "generic route graceful close timed out"
                );
            }
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

/// Staged GenericRoute owner used between task startup and Session attach.
/// `commit_and_take_owner` is called while the Session write lock is held, so
/// no caller can observe a current route before the driver has been released
/// from its paused pre-attach state.
pub(crate) struct GenericRouteScope {
    owner: Option<GenericRouteOwner>,
    commit: Option<oneshot::Sender<()>>,
}

impl GenericRouteScope {
    pub(crate) fn new(
        handle: GenericRouteHandle,
        driver_task: TaskLease,
        receiver_task: TaskLease,
        route_stop: CancellationToken,
        stopping: Arc<AtomicBool>,
        commit: oneshot::Sender<()>,
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
        self.owner.as_ref().map(|owner| owner.handle.profile())
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

/// A route is a composed profile plus its authenticated carrier. The legacy
/// `RouteType` remains only as a compatibility projection for old transfer and
/// UI consumers; generic routes are represented by `profile` directly.
pub(crate) struct ActiveRoute {
    profile: ConnectionProfile,
    carrier: ActiveConnection,
}

enum ActiveConnection {
    Quic(Connection),
    Generic(GenericRouteOwner),
    #[cfg(test)]
    GenericTest(GenericRouteHandle),
    Relay(Option<Arc<RelayClient>>),
}

/// Cloneable non-owning view used by Delivery and route-selection observers.
/// It never carries a GenericRoute task lease and therefore cannot close or
/// outlive the Session's unique ActiveRoute owner.
#[derive(Clone)]
pub(crate) struct RouteView {
    profile: ConnectionProfile,
    carrier: RouteViewCarrier,
}

#[derive(Clone)]
enum RouteViewCarrier {
    Quic(Connection),
    Generic(GenericRouteHandle),
    Relay(Option<Arc<RelayClient>>),
}

impl ActiveRoute {
    pub(crate) fn quic(connection: Connection, route: RouteType) -> Self {
        let profile = ConnectionProfile::for_route(route)
            .expect("QUIC and Relay route types have a composed profile");
        Self {
            profile,
            carrier: ActiveConnection::Quic(connection),
        }
    }

    fn generic(owner: GenericRouteOwner) -> Self {
        Self {
            profile: owner.handle().profile(),
            carrier: ActiveConnection::Generic(owner),
        }
    }

    #[cfg(test)]
    fn generic_test(handle: GenericRouteHandle) -> Self {
        Self {
            profile: handle.profile(),
            carrier: ActiveConnection::GenericTest(handle),
        }
    }

    fn relay(client: Option<Arc<RelayClient>>) -> Self {
        Self {
            profile: ConnectionProfile::new(Route::relay(RouteTransport::WebSocket)),
            carrier: ActiveConnection::Relay(client),
        }
    }

    pub(crate) fn profile(&self) -> ConnectionProfile {
        self.profile
    }

    fn view(&self) -> RouteView {
        let carrier = match &self.carrier {
            ActiveConnection::Quic(connection) => RouteViewCarrier::Quic(connection.clone()),
            ActiveConnection::Generic(owner) => RouteViewCarrier::Generic(owner.handle().clone()),
            #[cfg(test)]
            ActiveConnection::GenericTest(handle) => RouteViewCarrier::Generic(handle.clone()),
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
                connection.close(VarInt::from_u32(0), b"session route closed");
            }
            ActiveConnection::Generic(owner) => {
                owner.close().await;
            }
            #[cfg(test)]
            ActiveConnection::GenericTest(handle) => {
                let _ = handle.close().await;
            }
            ActiveConnection::Relay(_) => {}
        }
    }
}

#[cfg(test)]
impl RouteView {
    /// Test-only transport interruption helper. Production callers can only
    /// close the unique ActiveRoute owner through Session teardown.
    pub(crate) async fn close_for_test(&self) {
        match &self.carrier {
            RouteViewCarrier::Quic(connection) => {
                connection.close(VarInt::from_u32(0), b"test route interruption");
            }
            RouteViewCarrier::Generic(handle) => {
                let _ = handle.close().await;
            }
            RouteViewCarrier::Relay(_) => {}
        }
    }
}

/// App Scope 内唯一的 Session owner。
pub(crate) struct SessionManager {
    sessions: RwLock<HashMap<String, Session>>,
}

impl SessionManager {
    pub(crate) fn new() -> Self {
        Self {
            sessions: RwLock::new(HashMap::new()),
        }
    }

    /// 开始一次连接尝试，已连接或已有连接任务时不重复创建 Session。
    pub(crate) async fn begin_connect(&self, peer_id: &str) -> ConnectDecision {
        let mut sessions = self.sessions.write().await;
        if let Some(session) = sessions.get_mut(peer_id) {
            match session.state {
                SessionState::Connected => return ConnectDecision::AlreadyConnected(session.id),
                SessionState::Connecting | SessionState::Reconnecting => {
                    return ConnectDecision::InProgress(session.id);
                }
                SessionState::Closed => {
                    let mut replacement = Self::new_session();
                    replacement.state = SessionState::Connecting;
                    let id = replacement.id;
                    *session = replacement;
                    return ConnectDecision::Started(id);
                }
                SessionState::Idle => {
                    session.state = SessionState::Connecting;
                    session.route = None;
                    return ConnectDecision::Started(session.id);
                }
                SessionState::Disconnected | SessionState::Failed => {
                    session.state = SessionState::Reconnecting;
                    session.route = None;
                    return ConnectDecision::Started(session.id);
                }
            }
        }

        let mut session = Self::new_session();
        session.state = SessionState::Connecting;
        let id = session.id;
        sessions.insert(peer_id.to_string(), session);
        ConnectDecision::Started(id)
    }

    /// Admit a completed application handshake into the logical Session
    /// lifecycle.  This is the single continuity gate shared by QUIC, generic
    /// routes, and Relay.  The old route is detached before it is closed so
    /// stale callbacks cannot observe it as the current route after a peer
    /// runtime restart.
    pub(crate) async fn admit_authenticated_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        new_remote_binding: &str,
    ) -> Result<SessionAdmissionOutcome, SessionAdmissionError> {
        if new_remote_binding.is_empty() {
            return Err(SessionAdmissionError::InvalidRemoteBinding);
        }

        let (admission, old_route) = {
            let mut sessions = self.sessions.write().await;
            let Some(current) = sessions.get_mut(peer_id) else {
                if expected_session_id.is_some() {
                    return Err(SessionAdmissionError::StaleSession);
                }
                let mut session = Self::new_session();
                session.remote_session_binding = Some(new_remote_binding.to_string());
                session.state = SessionState::Connecting;
                let admission = SessionAdmission {
                    session_id: session.id,
                    decision: SessionCryptoDecision::Initialize,
                    replaced_session_id: None,
                };
                sessions.insert(peer_id.to_string(), session);
                return Ok(SessionAdmissionOutcome {
                    admission,
                    detached_route: None,
                });
            };

            if expected_session_id.is_some_and(|expected| expected != current.id) {
                return Err(SessionAdmissionError::StaleSession);
            }

            if current.state == SessionState::Closed {
                let replaced_session_id = current.id;
                let old_route = current.route.take();
                let mut replacement = Self::new_session();
                replacement.remote_session_binding = Some(new_remote_binding.to_string());
                replacement.state = SessionState::Connecting;
                let admission = SessionAdmission {
                    session_id: replacement.id,
                    decision: SessionCryptoDecision::ReplaceWithNew,
                    replaced_session_id: Some(replaced_session_id),
                };
                *current = replacement;
                (admission, old_route)
            } else {
                let decision = evaluate_remote_session(
                    current.remote_session_binding.as_deref(),
                    new_remote_binding,
                );
                match decision {
                    SessionCryptoDecision::Initialize | SessionCryptoDecision::ContinueExisting => {
                        current.remote_session_binding = Some(new_remote_binding.to_string());
                        (
                            SessionAdmission {
                                session_id: current.id,
                                decision,
                                replaced_session_id: None,
                            },
                            None,
                        )
                    }
                    SessionCryptoDecision::ReplaceWithNew => {
                        let replaced_session_id = current.id;
                        let old_route = current.route.take();
                        let mut replacement = Self::new_session();
                        replacement.remote_session_binding = Some(new_remote_binding.to_string());
                        replacement.state = SessionState::Connecting;
                        let admission = SessionAdmission {
                            session_id: replacement.id,
                            decision,
                            replaced_session_id: Some(replaced_session_id),
                        };
                        *current = replacement;
                        (admission, old_route)
                    }
                }
            }
        };

        Ok(SessionAdmissionOutcome {
            admission,
            detached_route: old_route,
        })
    }

    /// Completes the responder side of one authenticated handshake after the
    /// initiator has selected its final local binding. This updates the
    /// reservation made from the initiator's Hello without opening a second
    /// replacement decision for the same handshake.
    pub(crate) async fn finalize_authenticated_session(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        remote_session_binding: &str,
    ) -> Result<(), SessionAdmissionError> {
        if remote_session_binding.is_empty() {
            return Err(SessionAdmissionError::InvalidRemoteBinding);
        }
        let mut sessions = self.sessions.write().await;
        let Some(session) = sessions.get_mut(peer_id) else {
            return Err(SessionAdmissionError::StaleSession);
        };
        if session.id != expected_session_id || session.state == SessionState::Closed {
            return Err(SessionAdmissionError::StaleSession);
        }
        session.remote_session_binding = Some(remote_session_binding.to_string());
        Ok(())
    }

    /// Attaches an authenticated QUIC route, optionally replacing the active
    /// carrier for the same logical Session. The returned route is detached
    /// atomically and must be closed by the caller after releasing the lock.
    pub(crate) async fn attach_connection_for_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        connection: Connection,
        route: RouteType,
        replace_current: bool,
    ) -> Result<Option<ActiveRoute>, ()> {
        let mut sessions = self.sessions.write().await;
        let session = match sessions.get_mut(peer_id) {
            Some(session) => session,
            None if expected_session_id.is_none() => sessions
                .entry(peer_id.to_string())
                .or_insert_with(Self::new_session),
            None => {
                drop(sessions);
                connection.close(VarInt::from_u32(0), b"session replaced");
                return Err(());
            }
        };
        if session.state == SessionState::Closed
            || expected_session_id.is_some_and(|id| id != session.id)
        {
            drop(sessions);
            connection.close(VarInt::from_u32(0), b"session replaced");
            return Err(());
        }
        if session.state == SessionState::Connected && session.route.is_some() && !replace_current {
            drop(sessions);
            connection.close(VarInt::from_u32(0), b"direct nomination already won");
            return Err(());
        }
        session.state = SessionState::Connected;
        Ok(session.route.replace(ActiveRoute::quic(connection, route)))
    }

    /// Atomically commits an authenticated GenericRoute scope. The driver is
    /// released from its paused pre-attach state while the Session write lock
    /// is held; only then is its unique owner installed as the current route.
    pub(crate) async fn attach_generic_route_for_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        scope: &mut GenericRouteScope,
        replace_current: bool,
    ) -> Result<Option<ActiveRoute>, ()> {
        let profile = scope.profile().ok_or(())?;
        if !profile.supports(ConnectionCapability::ReliableMessage) {
            return Err(());
        }
        let mut sessions = self.sessions.write().await;
        let session = match sessions.get_mut(peer_id) {
            Some(session) => session,
            None if expected_session_id.is_none() => sessions
                .entry(peer_id.to_string())
                .or_insert_with(Self::new_session),
            None => {
                return Err(());
            }
        };
        if session.state == SessionState::Closed
            || expected_session_id.is_some_and(|id| id != session.id)
            || (session.state == SessionState::Connected
                && session.route.is_some()
                && !replace_current)
        {
            return Err(());
        }
        let owner = scope.commit_and_take_owner()?;
        session.state = SessionState::Connected;
        Ok(session.route.replace(ActiveRoute::generic(owner)))
    }

    #[cfg(test)]
    pub(crate) async fn attach_test_generic_route(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        handle: GenericRouteHandle,
    ) -> Result<(), ()> {
        let mut sessions = self.sessions.write().await;
        let session = sessions.get_mut(peer_id).ok_or(())?;
        if session.id != expected_session_id || session.state == SessionState::Closed {
            return Err(());
        }
        session.state = SessionState::Connected;
        session.route = Some(ActiveRoute::generic_test(handle));
        Ok(())
    }

    pub(crate) async fn mark_relay_route_connected(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        route: RouteType,
        relay: Option<Arc<RelayClient>>,
    ) -> bool {
        let mut sessions = self.sessions.write().await;
        let Some(session) = sessions.get_mut(peer_id) else {
            return false;
        };
        if session.state == SessionState::Closed || session.id != expected_session_id {
            return false;
        }
        session.state = SessionState::Connected;
        session.route = match route {
            RouteType::Relay => Some(ActiveRoute::relay(relay)),
            _ => None,
        };
        true
    }

    /// 取得当前可靠 direct Connection；Session 自身不随 Connection drop 消失。
    pub(crate) async fn current_connection(&self, peer_id: &str) -> Option<Connection> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .filter(|session| session.state == SessionState::Connected)
            .and_then(|session| session.route.as_ref())
            .and_then(|route| match route.view().carrier {
                RouteViewCarrier::Quic(connection) => Some(connection),
                _ => None,
            })
    }

    pub(crate) async fn current_session_id(&self, peer_id: &str) -> Option<SessionId> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .map(|session| session.id)
    }

    #[cfg(test)]
    pub(crate) async fn current_remote_session_binding(&self, peer_id: &str) -> Option<String> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .and_then(|session| session.remote_session_binding.clone())
    }

    /// Returns the composed profile of the current authenticated route.
    pub(crate) async fn current_profile(&self, peer_id: &str) -> Option<ConnectionProfile> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .filter(|session| session.state == SessionState::Connected)
            .and_then(|session| session.route.as_ref())
            .map(ActiveRoute::profile)
    }

    pub(crate) async fn current_active_route(&self, peer_id: &str) -> Option<RouteView> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .filter(|session| session.state == SessionState::Connected)
            .and_then(|session| session.route.as_ref().map(ActiveRoute::view))
    }

    /// Returns the old flat projection for compatibility surfaces. Generic
    /// routes intentionally return `Unspecified`; callers needing routing
    /// semantics must use `current_profile`.
    pub(crate) async fn current_route(&self, peer_id: &str) -> Option<RouteType> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .filter(|session| session.state == SessionState::Connected)
            .and_then(|session| session.route.as_ref())
            .map(|route| {
                route
                    .profile
                    .route()
                    .to_wire()
                    .unwrap_or(RouteType::Unspecified)
            })
    }

    /// Sends one Delivery data/ACK frame through the current route capability.
    /// The caller supplies the opaque token required by the Relay protocol;
    /// no caller branches on QUIC, TCP, WebSocket, UDP, or Relay.
    pub(crate) async fn send_channel_frame(
        &self,
        peer_id: &str,
        relay_token: &str,
        kind: GenericFrameKind,
        payload: &[u8],
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let route = self.current_active_route(peer_id).await.ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::NotConnected, "route unavailable")
        })?;
        if !route
            .profile
            .supports(ConnectionCapability::ReliableMessage)
        {
            return Err(std::io::Error::other("route does not support reliable messages").into());
        }
        match route.carrier {
            RouteViewCarrier::Quic(connection) => {
                let kind = match kind {
                    GenericFrameKind::DataMessage => ChannelFrameKind::DataMessage,
                    GenericFrameKind::DeliveryAck => ChannelFrameKind::DeliveryAck,
                };
                send_channel_frame(&connection, kind, payload).await
            }
            RouteViewCarrier::Generic(connection) => connection
                .send(kind, payload)
                .await
                .map_err(|error| std::io::Error::other(error.to_string()).into()),
            RouteViewCarrier::Relay(Some(relay)) => match kind {
                GenericFrameKind::DataMessage => relay
                    .send_channel_message(relay_token, peer_id, payload)
                    .await
                    .map_err(|error| std::io::Error::other(error.to_string()).into()),
                GenericFrameKind::DeliveryAck => relay
                    .send_channel_ack(relay_token, peer_id, payload)
                    .await
                    .map_err(|error| std::io::Error::other(error.to_string()).into()),
            },
            RouteViewCarrier::Relay(None) => Err(std::io::Error::new(
                std::io::ErrorKind::NotConnected,
                "Relay route unavailable",
            )
            .into()),
        }
    }

    pub(crate) async fn is_connected(&self, peer_id: &str) -> bool {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .is_some_and(|session| {
                session.state == SessionState::Connected && session.route.is_some()
            })
    }

    /// 仅当断开的 Connection 仍是当前 Connection 时才更新 Session，避免旧
    /// Connection 的收尾任务覆盖已经接入的新 Connection。
    pub(crate) async fn mark_disconnected_if_current(
        &self,
        peer_id: &str,
        connection: &Connection,
    ) -> Option<SessionId> {
        let mut sessions = self.sessions.write().await;
        let session = sessions.get_mut(peer_id)?;
        let is_current = session
            .route
            .as_ref()
            .is_some_and(|route| match &route.carrier {
                ActiveConnection::Quic(current) => current.stable_id() == connection.stable_id(),
                _ => false,
            });
        if !is_current {
            return None;
        }
        let session_id = session.id;
        session.route = None;
        session.state = SessionState::Disconnected;
        Some(session_id)
    }

    pub(crate) async fn mark_generic_disconnected_if_current(
        &self,
        peer_id: &str,
        route_id: u64,
    ) -> Option<SessionId> {
        let mut sessions = self.sessions.write().await;
        let session = sessions.get_mut(peer_id)?;
        let current_generic = session.route.as_ref().is_some_and(|route| {
            matches!(&route.carrier, ActiveConnection::Generic(owner) if owner.handle().id() == route_id)
        });
        let is_current = {
            #[cfg(test)]
            {
                current_generic
                    || session.route.as_ref().is_some_and(|route| {
                        matches!(&route.carrier, ActiveConnection::GenericTest(handle) if handle.id() == route_id)
                    })
            }
            #[cfg(not(test))]
            {
                current_generic
            }
        };
        if !is_current {
            return None;
        }
        let session_id = session.id;
        session.route = None;
        session.state = SessionState::Disconnected;
        Some(session_id)
    }

    /// 在没有具体 Connection handle 时记录一次断开，主要用于后续
    /// ConnectionManager/恢复任务接入前的状态边界。
    #[cfg(test)]
    async fn mark_disconnected(&self, peer_id: &str) -> bool {
        let mut sessions = self.sessions.write().await;
        let Some(session) = sessions.get_mut(peer_id) else {
            return false;
        };
        session.route = None;
        session.state = SessionState::Disconnected;
        true
    }

    pub(crate) async fn mark_failed(&self, peer_id: &str, expected_session_id: SessionId) {
        let mut sessions = self.sessions.write().await;
        if let Some(session) = sessions.get_mut(peer_id) {
            if session.id == expected_session_id
                && matches!(
                    session.state,
                    SessionState::Connecting | SessionState::Reconnecting
                )
            {
                session.route = None;
                session.state = SessionState::Failed;
            }
        }
    }

    /// 显式断开结束 Session，并把绑定的 route owner 返回给 Runtime 做
    /// 有界关闭与 supervised task join。
    pub(crate) async fn close(&self, peer_id: &str) -> Option<ActiveRoute> {
        {
            let mut sessions = self.sessions.write().await;
            let session = sessions.get_mut(peer_id)?;
            session.state = SessionState::Closed;
            session.route.take()
        }
    }

    #[cfg(test)]
    async fn session_id(&self, peer_id: &str) -> Option<SessionId> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .map(|session| session.id)
    }

    #[cfg(test)]
    async fn state(&self, peer_id: &str) -> Option<SessionState> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .map(|session| session.state)
    }

    fn new_session() -> Session {
        Session {
            id: SessionId::random(),
            remote_session_binding: None,
            state: SessionState::Idle,
            route: None,
        }
    }
}

impl SessionId {
    fn random() -> Self {
        let mut bytes = [0u8; SESSION_ID_BYTES];
        OsRng.fill_bytes(&mut bytes);
        Self(bytes)
    }

    /// Delivery 使用独立的 Session key，避免把 peer_id 错当成 SessionId。
    pub(crate) fn wire_key(self) -> String {
        hex::encode(self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn new_session_ids_are_random_128_bit_lowercase_hex() {
        let manager = SessionManager::new();
        let first = match manager.begin_connect("peer-a").await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        let second = match manager.begin_connect("peer-b").await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        let first_key = first.wire_key();
        let second_key = second.wire_key();

        assert_eq!(first_key.len(), SESSION_ID_BYTES * 2);
        assert_eq!(second_key.len(), SESSION_ID_BYTES * 2);
        assert!(first_key
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()));
        assert!(second_key
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()));
        assert_ne!(first, second);
        assert_ne!(first_key, second_key);
    }

    #[tokio::test]
    async fn transient_disconnect_keeps_session_id_for_reconnect() {
        let manager = SessionManager::new();
        let first = match manager.begin_connect("peer-b").await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        assert_eq!(
            manager.state("peer-b").await,
            Some(SessionState::Connecting)
        );

        assert!(manager.mark_disconnected("peer-b").await);
        assert_eq!(
            manager.state("peer-b").await,
            Some(SessionState::Disconnected)
        );

        let second = match manager.begin_connect("peer-b").await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        assert_eq!(first, second);
        assert_eq!(manager.session_id("peer-b").await, Some(first));
    }

    #[tokio::test]
    async fn concurrent_connect_is_merged_while_in_progress() {
        // §40 Concurrency：同 peer 并发 connect 合并——已有连接任务在途时返回
        // InProgress（不重复创建 Session/建连）。
        let manager = SessionManager::new();
        let first = match manager.begin_connect("peer-b").await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        // 仍在 Connecting（任务在途）→ 第二次 begin_connect 合并。
        assert!(matches!(
            manager.begin_connect("peer-b").await,
            ConnectDecision::InProgress(session_id) if session_id == first
        ));
        // 已有健康连接 → AlreadyConnected。
        assert!(
            manager
                .mark_relay_route_connected("peer-b", first, RouteType::Relay, None)
                .await
        );
        assert!(matches!(
            manager.begin_connect("peer-b").await,
            ConnectDecision::AlreadyConnected(session_id) if session_id == first
        ));
    }

    #[test]
    fn remote_session_binding_decision_is_explicit() {
        assert_eq!(
            evaluate_remote_session(None, "remote-a"),
            SessionCryptoDecision::Initialize
        );
        assert_eq!(
            evaluate_remote_session(Some("remote-a"), "remote-a"),
            SessionCryptoDecision::ContinueExisting
        );
        assert_eq!(
            evaluate_remote_session(Some("remote-a"), "remote-b"),
            SessionCryptoDecision::ReplaceWithNew
        );
    }

    #[tokio::test]
    async fn same_remote_binding_preserves_session_and_changed_binding_replaces_it() {
        let manager = SessionManager::new();
        let first = match manager.begin_connect("peer-b").await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        let initialized = manager
            .admit_authenticated_session("peer-b", Some(first), "remote-a")
            .await
            .expect("initial authenticated Session");
        assert_eq!(initialized.session_id, first);
        assert_eq!(initialized.decision, SessionCryptoDecision::Initialize);
        assert_eq!(
            manager
                .current_remote_session_binding("peer-b")
                .await
                .as_deref(),
            Some("remote-a")
        );

        manager.mark_disconnected("peer-b").await;
        let reconnect = match manager.begin_connect("peer-b").await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        assert_eq!(reconnect, first);
        let continued = manager
            .admit_authenticated_session("peer-b", Some(reconnect), "remote-a")
            .await
            .expect("same remote Session");
        assert_eq!(continued.session_id, first);
        assert_eq!(continued.decision, SessionCryptoDecision::ContinueExisting);

        let replaced = manager
            .admit_authenticated_session("peer-b", Some(first), "remote-b")
            .await
            .expect("peer restart replacement");
        assert_ne!(replaced.session_id, first);
        assert_eq!(replaced.decision, SessionCryptoDecision::ReplaceWithNew);
        assert_eq!(replaced.replaced_session_id, Some(first));
        assert_eq!(
            manager.session_id("peer-b").await,
            Some(replaced.session_id)
        );
        assert_eq!(
            manager
                .current_remote_session_binding("peer-b")
                .await
                .as_deref(),
            Some("remote-b")
        );
        assert!(matches!(
            manager
                .admit_authenticated_session("peer-b", Some(first), "remote-c")
                .await,
            Err(SessionAdmissionError::StaleSession)
        ));
    }

    #[tokio::test]
    async fn explicit_close_ends_session_before_a_new_session_is_created() {
        let manager = SessionManager::new();
        let first = match manager.begin_connect("peer-b").await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        manager.close("peer-b").await;
        assert_eq!(manager.state("peer-b").await, Some(SessionState::Closed));

        let second = match manager.begin_connect("peer-b").await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        assert_ne!(first, second);
        manager.close("peer-b").await;
    }

    #[tokio::test]
    async fn explicit_close_does_not_recover_delivery_into_replacement_session() {
        let manager = SessionManager::new();
        let delivery = crate::delivery::DeliveryManager::new();
        let first = match manager.begin_connect("peer-b").await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        delivery
            .enqueue(
                &first.wire_key(),
                "control",
                b"old-session".to_vec(),
                crate::delivery::DeliveryPolicy::Acked,
                Default::default(),
            )
            .await
            .expect("enqueue old session message");
        manager.close("peer-b").await;
        let second = match manager.begin_connect("peer-b").await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        assert_ne!(first, second);
        assert!(delivery
            .recover_session(&second.wire_key())
            .await
            .messages
            .is_empty());
        assert_eq!(
            delivery
                .recover_session(&first.wire_key())
                .await
                .messages
                .len(),
            1
        );
    }
}
