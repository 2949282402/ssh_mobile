//! ConnectionSession 生命周期（transport-network v2，设计 §18）。
//!
//! 每个 transport connection 拥有且仅拥有一个 `ConnectionSession`：新连接建立时
//! 创建新的 `SessionId` 与新的 Noise root；transport 丢失即销毁 Session，不存在
//! 跨 connection 存活的 `SessionState::Disconnected`，也不存在复用旧 `SessionId`
//! 的重连。业务状态（Delivery / Transfer）不属于 Session，由业务 manager 持有。

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

/// Session 自身的生命周期（§18）。`Closed` / `Failed` 是终态；transport 丢失
/// 直接销毁 Session（从注册表移除），因此不存在存活的重连态。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum SessionState {
    Idle,
    Connecting,
    Connected,
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

/// 握手材料安装的决策。Session 与 connection 一一对应（§18），因此唯一允许的
/// 决策是安装**全新** root：`Initialize` 用于直接 admit 一个 `begin_connect`
/// 创建且仍在途中的 Session；`ReplaceWithNew` 用于新连接到达时替换一个已经存在
/// 的旧 Session（新 SessionId + 新 root）。不存在 `ContinueExisting`。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum SessionCryptoDecision {
    Initialize,
    ReplaceWithNew,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct SessionAdmission {
    pub(crate) session_id: SessionId,
    pub(crate) decision: SessionCryptoDecision,
    pub(crate) replaced_session_id: Option<SessionId>,
}

/// Result of the Session admission decision.  The old route is detached but
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
    ///
    /// §18：Session 与 transport connection 一一对应。终态（`Closed` / `Failed`）
    /// 或已销毁（不在注册表）的 Session 都会生成一个**全新** SessionId；不存在
    /// 复用旧 SessionId 的 reconnect。
    pub(crate) async fn begin_connect(&self, peer_id: &str) -> ConnectDecision {
        let mut sessions = self.sessions.write().await;
        if let Some(session) = sessions.get_mut(peer_id) {
            match session.state {
                SessionState::Connected => return ConnectDecision::AlreadyConnected(session.id),
                SessionState::Connecting => {
                    return ConnectDecision::InProgress(session.id);
                }
                SessionState::Closed | SessionState::Failed | SessionState::Idle => {
                    let mut replacement = Self::new_session();
                    replacement.state = SessionState::Connecting;
                    let id = replacement.id;
                    *session = replacement;
                    return ConnectDecision::Started(id);
                }
            }
        }

        let mut session = Self::new_session();
        session.state = SessionState::Connecting;
        let id = session.id;
        sessions.insert(peer_id.to_string(), session);
        ConnectDecision::Started(id)
    }

    /// Admit a completed application handshake into a 1:1 ConnectionSession
    /// (design §18). QUIC, generic routes, and Relay all route through this
    /// gate. A new connection either admits the in-flight `begin_connect`
    /// Session (fresh root, same SessionId) or replaces an existing Session
    /// with a fresh SessionId + fresh root. There is no ContinueExisting.
    pub(crate) async fn admit_authenticated_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        new_remote_binding: &str,
    ) -> Result<SessionAdmissionOutcome, SessionAdmissionError> {
        if new_remote_binding.is_empty() {
            return Err(SessionAdmissionError::InvalidRemoteBinding);
        }

        let mut sessions = self.sessions.write().await;
        let Some(current) = sessions.get_mut(peer_id) else {
            if expected_session_id.is_some() {
                return Err(SessionAdmissionError::StaleSession);
            }
            // Responder 首次 admit：创建一个全新的 1:1 Session。
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

        let binding_changed = current
            .remote_session_binding
            .as_deref()
            .is_some_and(|recorded| recorded != new_remote_binding);

        // §18 1:1：只有 begin_connect 创建、仍在途中的 Session 会被直接 admit（安装
        // 新 root，但保持 SessionId）。Responder 在 simultaneous connect 时也会直接
        // admit 一个本端出站 connect 创建、尚未绑定 remote binding 的 Connecting
        // Session，避免把它替换掉。任何已经带有不同 remote binding 的 Session，或
        // 已经 Connected/Closed/Failed 的 Session，都会被新连接整体替换（新 SessionId +
        // 新 root）——不存在 ContinueExisting。
        let in_flight_initialize = expected_session_id.is_some()
            && current.state == SessionState::Connecting
            && !binding_changed
            || expected_session_id.is_none()
                && current.state == SessionState::Connecting
                && current.remote_session_binding.is_none();
        if in_flight_initialize {
            current.remote_session_binding = Some(new_remote_binding.to_string());
            return Ok(SessionAdmissionOutcome {
                admission: SessionAdmission {
                    session_id: current.id,
                    decision: SessionCryptoDecision::Initialize,
                    replaced_session_id: None,
                },
                detached_route: None,
            });
        }

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

    /// Attaches an authenticated QUIC route to a 1:1 ConnectionSession (§18).
    /// A Session owns exactly one carrier for its whole life; attaching to a
    /// Session that is already `Connected` with a route is rejected (a new
    /// connection must create a new Session). The returned route is detached
    /// atomically and must be closed by the caller after releasing the lock.
    pub(crate) async fn attach_connection_for_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        connection: Connection,
        route: RouteType,
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
        if session.state == SessionState::Connected && session.route.is_some() {
            drop(sessions);
            connection.close(VarInt::from_u32(0), b"direct nomination already won");
            return Err(());
        }
        session.state = SessionState::Connected;
        Ok(session.route.replace(ActiveRoute::quic(connection, route)))
    }

    /// Atomically commits an authenticated GenericRoute scope to a 1:1
    /// ConnectionSession (§18). The driver is released from its paused
    /// pre-attach state while the Session write lock is held; only then is its
    /// unique owner installed as the current route.
    pub(crate) async fn attach_generic_route_for_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        scope: &mut GenericRouteScope,
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
            || (session.state == SessionState::Connected && session.route.is_some())
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

    /// §18 transport 丢失即销毁 Session：仅当断开的 Connection 仍是当前
    /// Connection 时移除该 Session，并把拆下的 route owner 交回调用方做有界
    /// 关闭与 supervised task join。旧 Connection 的收尾任务不会覆盖新 Session。
    pub(crate) async fn destroy_quic_session_if_current(
        &self,
        peer_id: &str,
        connection: &Connection,
    ) -> Option<(SessionId, ActiveRoute)> {
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
        let route = session
            .route
            .take()
            .expect("current QUIC session must own a route");
        sessions.remove(peer_id);
        Some((session_id, route))
    }

    /// §18 transport 丢失即销毁 Session：仅当断开的是当前 GenericRoute 时移除。
    pub(crate) async fn destroy_generic_session_if_current(
        &self,
        peer_id: &str,
        route_id: u64,
    ) -> Option<(SessionId, ActiveRoute)> {
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
        let route = session
            .route
            .take()
            .expect("current generic session must own a route");
        sessions.remove(peer_id);
        Some((session_id, route))
    }

    pub(crate) async fn mark_failed(&self, peer_id: &str, expected_session_id: SessionId) {
        let mut sessions = self.sessions.write().await;
        if let Some(session) = sessions.get_mut(peer_id) {
            if session.id == expected_session_id && session.state == SessionState::Connecting {
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
    use crate::connection::TestBlockingGenericRoute;

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

    #[tokio::test]
    async fn transport_loss_destroys_session_and_reconnect_gets_a_new_id() {
        // §18/§40：transport 丢失即销毁 Session；重新 begin_connect 得到全新 SessionId，
        // 绝不复用旧 id。
        let manager = SessionManager::new();
        let peer_id = "peer-loss";
        let first = match manager.begin_connect(peer_id).await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        let TestBlockingGenericRoute { handle, worker, .. } =
            crate::connection::test_blocking_generic_route();
        let route_id = handle.id();
        manager
            .attach_test_generic_route(peer_id, first, handle)
            .await
            .expect("attach test route");
        assert_eq!(manager.session_id(peer_id).await, Some(first));

        let destroyed = manager
            .destroy_generic_session_if_current(peer_id, route_id)
            .await
            .expect("current route must be destroyed");
        assert_eq!(destroyed.0, first);
        assert_eq!(manager.session_id(peer_id).await, None);

        let second = match manager.begin_connect(peer_id).await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        assert_ne!(first, second);
        drop(worker);
    }

    #[tokio::test]
    async fn in_flight_initiator_admission_keeps_its_session_but_installs_new_root() {
        // §18：begin_connect 创建、仍在途中的 Session 被直接 admit（Initialize），
        // 不生成第二个 SessionId。
        let manager = SessionManager::new();
        let peer_id = "peer-init";
        let first = match manager.begin_connect(peer_id).await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        let admission = manager
            .admit_authenticated_session(peer_id, Some(first), "remote-a")
            .await
            .expect("admit in-flight initiator Session");
        assert_eq!(admission.session_id, first);
        assert_eq!(admission.decision, SessionCryptoDecision::Initialize);
        assert_eq!(admission.replaced_session_id, None);
    }

    #[tokio::test]
    async fn responder_admits_into_an_in_flight_connecting_session() {
        // §18：simultaneous connect 时，responder 直接 admit 本端出站 connect 创建、
        // 尚未绑定 remote binding 的 Connecting Session，避免替换掉它。
        let manager = SessionManager::new();
        let peer_id = "peer-simultaneous";
        let session_id = match manager.begin_connect(peer_id).await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        let admission = manager
            .admit_authenticated_session(peer_id, None, "remote-a")
            .await
            .expect("responder admits into in-flight Session");
        assert_eq!(admission.session_id, session_id);
        assert_eq!(admission.decision, SessionCryptoDecision::Initialize);
        assert_eq!(admission.replaced_session_id, None);
        // 出站 connect 的 admit 仍然成功（同一个 Session）。
        let outbound = manager
            .admit_authenticated_session(peer_id, Some(session_id), "remote-a")
            .await
            .expect("outbound admit after responder admit");
        assert_eq!(outbound.session_id, session_id);
    }

    #[tokio::test]
    async fn new_connection_replaces_an_existing_session_with_a_fresh_id() {
        // §18：新连接到达时若已存在旧 Session（例如对端 runtime 重启 / 并发建连），
        // 必须整体替换——新 SessionId + ReplaceWithNew，绝不 ContinueExisting。
        let manager = SessionManager::new();
        let peer_id = "peer-replace";
        let first = match manager.begin_connect(peer_id).await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        let initialized = manager
            .admit_authenticated_session(peer_id, Some(first), "remote-a")
            .await
            .expect("initial authenticated Session");
        assert_eq!(initialized.session_id, first);
        assert_eq!(initialized.decision, SessionCryptoDecision::Initialize);
        assert_eq!(
            manager
                .current_remote_session_binding(peer_id)
                .await
                .as_deref(),
            Some("remote-a")
        );

        // 同一个 Session 用新 binding 再次 admit（peer restart 信号）→ 必须替换。
        let replaced = manager
            .admit_authenticated_session(peer_id, Some(first), "remote-b")
            .await
            .expect("peer restart replacement");
        assert_ne!(replaced.session_id, first);
        assert_eq!(replaced.decision, SessionCryptoDecision::ReplaceWithNew);
        assert_eq!(replaced.replaced_session_id, Some(first));
        assert_eq!(manager.session_id(peer_id).await, Some(replaced.session_id));
        assert_eq!(
            manager
                .current_remote_session_binding(peer_id)
                .await
                .as_deref(),
            Some("remote-b")
        );

        // 旧 SessionId 再次 admit → StaleSession（旧会话已被销毁）。
        assert!(matches!(
            manager
                .admit_authenticated_session(peer_id, Some(first), "remote-c")
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
