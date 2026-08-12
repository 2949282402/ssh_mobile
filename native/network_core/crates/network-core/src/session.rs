//! Session 生命周期与当前 transport connection 的隔离。

use network_protocol::RouteType;
use network_quic::{send_channel_frame, ChannelFrameKind};
use network_relay::RelayClient;
use quinn::{Connection, VarInt};
use rand::{rngs::OsRng, RngCore};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::connection::{
    ConnectionCapability, ConnectionProfile, GenericFrameKind, GenericRouteHandle, Route,
    RouteTransport,
};

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

/// Session 聚合根只放置 Connection 生命周期和当前 Route；Delivery/Crypto/
/// Transfer 状态在外部按这个 SessionId 关联，不能回退到 Connection map。
struct Session {
    id: SessionId,
    state: SessionState,
    route: Option<ActiveRoute>,
}

/// A route is a composed profile plus its authenticated carrier. The legacy
/// `RouteType` remains only as a compatibility projection for old transfer and
/// UI consumers; generic routes are represented by `profile` directly.
#[derive(Clone)]
pub(crate) struct ActiveRoute {
    profile: ConnectionProfile,
    carrier: ActiveConnection,
}

#[derive(Clone)]
enum ActiveConnection {
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

    fn generic(handle: GenericRouteHandle) -> Self {
        Self {
            profile: handle.profile(),
            carrier: ActiveConnection::Generic(handle),
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

    fn same_carrier(&self, other: &Self) -> bool {
        match (&self.carrier, &other.carrier) {
            (ActiveConnection::Quic(left), ActiveConnection::Quic(right)) => {
                left.stable_id() == right.stable_id()
            }
            (ActiveConnection::Generic(left), ActiveConnection::Generic(right)) => {
                left.id() == right.id()
            }
            (ActiveConnection::Relay(left), ActiveConnection::Relay(right)) => {
                match (left, right) {
                    (Some(left), Some(right)) => Arc::ptr_eq(left, right),
                    (None, None) => true,
                    _ => false,
                }
            }
            _ => false,
        }
    }

    pub(crate) async fn close(&self) {
        match &self.carrier {
            ActiveConnection::Quic(connection) => {
                connection.close(VarInt::from_u32(0), b"session route closed");
            }
            ActiveConnection::Generic(handle) => {
                let _ = handle.close().await;
            }
            ActiveConnection::Relay(_) => {}
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

    /// 绑定一个新的实际 Connection，但保留原有 Session ID。
    pub(crate) async fn attach_connection(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        connection: Connection,
        route: RouteType,
    ) -> bool {
        let mut sessions = self.sessions.write().await;
        let session = match sessions.get_mut(peer_id) {
            Some(session) => session,
            None if expected_session_id.is_none() => sessions
                .entry(peer_id.to_string())
                .or_insert_with(Self::new_session),
            None => {
                drop(sessions);
                connection.close(VarInt::from_u32(0), b"session replaced");
                return false;
            }
        };
        if session.state == SessionState::Closed
            || expected_session_id.is_some_and(|id| id != session.id)
        {
            drop(sessions);
            connection.close(VarInt::from_u32(0), b"session replaced");
            return false;
        }
        if session.state == SessionState::Connected && session.route.is_some() {
            drop(sessions);
            connection.close(VarInt::from_u32(0), b"direct nomination already won");
            return false;
        }
        session.state = SessionState::Connected;
        session.route = Some(ActiveRoute::quic(connection, route));
        true
    }

    /// Attaches an authenticated TCP/WebSocket route without replacing an
    /// already active route. Authentication is completed by the caller before
    /// this method is reached.
    pub(crate) async fn attach_generic_connection(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        connection: GenericRouteHandle,
    ) -> bool {
        if !connection
            .profile()
            .supports(ConnectionCapability::ReliableMessage)
        {
            let _ = connection.close().await;
            return false;
        }
        let mut sessions = self.sessions.write().await;
        let session = match sessions.get_mut(peer_id) {
            Some(session) => session,
            None if expected_session_id.is_none() => sessions
                .entry(peer_id.to_string())
                .or_insert_with(Self::new_session),
            None => {
                drop(sessions);
                let _ = connection.close().await;
                return false;
            }
        };
        if session.state == SessionState::Closed
            || expected_session_id.is_some_and(|id| id != session.id)
            || (session.state == SessionState::Connected && session.route.is_some())
        {
            drop(sessions);
            let _ = connection.close().await;
            return false;
        }
        session.state = SessionState::Connected;
        session.route = Some(ActiveRoute::generic(connection));
        true
    }

    /// Atomically replaces the current Connection for a Session after a new
    /// route has completed authentication. The old handle is returned so the
    /// caller can close it after releasing the Session lock.
    pub(crate) async fn replace_connection_if_current(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        current_connection: &Connection,
        replacement: Connection,
        route: RouteType,
    ) -> Option<Connection> {
        let mut sessions = self.sessions.write().await;
        let session = sessions.get_mut(peer_id)?;
        let is_current = session
            .route
            .as_ref()
            .is_some_and(|route| match &route.carrier {
                ActiveConnection::Quic(connection) => {
                    connection.stable_id() == current_connection.stable_id()
                }
                _ => false,
            });
        if session.id != expected_session_id || session.state == SessionState::Closed || !is_current
        {
            drop(sessions);
            replacement.close(VarInt::from_u32(0), b"session replaced");
            return None;
        }
        let previous = session.route.replace(ActiveRoute::quic(replacement, route));
        session.state = SessionState::Connected;
        match previous {
            Some(ActiveRoute {
                carrier: ActiveConnection::Quic(connection),
                ..
            }) => Some(connection),
            _ => None,
        }
    }

    /// Atomically promotes a connected Relay route to a newly authenticated
    /// direct Connection. The Relay route has no Connection handle, so this
    /// transition has its own guard and cannot accidentally replace a newer
    /// direct route or a closed Session.
    pub(crate) async fn replace_route_if_current(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        expected_route: RouteType,
        replacement: Connection,
        route: RouteType,
    ) -> bool {
        let mut sessions = self.sessions.write().await;
        let Some(session) = sessions.get_mut(peer_id) else {
            replacement.close(VarInt::from_u32(0), b"session replaced");
            return false;
        };
        if session.id != expected_session_id
            || session.state != SessionState::Connected
            || session
                .route
                .as_ref()
                .and_then(|route| route.profile.route().to_wire())
                != Some(expected_route)
            || session
                .route
                .as_ref()
                .is_some_and(|route| !matches!(route.carrier, ActiveConnection::Relay(_)))
        {
            drop(sessions);
            replacement.close(VarInt::from_u32(0), b"session replaced");
            return false;
        }
        session.route = Some(ActiveRoute::quic(replacement, route));
        true
    }

    /// 记录一个没有 Quinn handle 的已连接 Route，例如 Relay 控制面。
    #[cfg(test)]
    async fn mark_route_connected(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        route: RouteType,
    ) -> bool {
        self.mark_relay_route_connected(peer_id, expected_session_id, route, None)
            .await
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

    /// Atomically swaps any authenticated active route while retaining the
    /// logical SessionId. The caller closes the returned old route only after
    /// the swap has become visible to Delivery and receiver tasks.
    pub(crate) async fn replace_active_route_if_current(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        expected_route: &ActiveRoute,
        replacement: ActiveRoute,
    ) -> Option<ActiveRoute> {
        let mut sessions = self.sessions.write().await;
        let Some(session) = sessions.get_mut(peer_id) else {
            drop(sessions);
            replacement.close().await;
            return None;
        };
        let matches_current = session
            .route
            .as_ref()
            .is_some_and(|current| current.same_carrier(expected_route));
        if session.id != expected_session_id
            || session.state != SessionState::Connected
            || !matches_current
        {
            drop(sessions);
            replacement.close().await;
            return None;
        }
        session.state = SessionState::Connected;
        Some(
            session
                .route
                .replace(replacement)
                .expect("matched active route"),
        )
    }

    /// 取得当前可靠 direct Connection；Session 自身不随 Connection drop 消失。
    pub(crate) async fn current_connection(&self, peer_id: &str) -> Option<Connection> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .filter(|session| session.state == SessionState::Connected)
            .and_then(|session| session.route.as_ref())
            .and_then(|route| match &route.carrier {
                ActiveConnection::Quic(connection) => Some(connection.clone()),
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

    pub(crate) async fn current_active_route(&self, peer_id: &str) -> Option<ActiveRoute> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .filter(|session| session.state == SessionState::Connected)
            .and_then(|session| session.route.clone())
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
            ActiveConnection::Quic(connection) => {
                let kind = match kind {
                    GenericFrameKind::DataMessage => ChannelFrameKind::DataMessage,
                    GenericFrameKind::DeliveryAck => ChannelFrameKind::DeliveryAck,
                };
                send_channel_frame(&connection, kind, payload).await
            }
            ActiveConnection::Generic(connection) => connection
                .send(kind, payload)
                .await
                .map_err(|error| std::io::Error::other(error.to_string()).into()),
            ActiveConnection::Relay(Some(relay)) => match kind {
                GenericFrameKind::DataMessage => relay
                    .send_channel_message(relay_token, peer_id, payload)
                    .await
                    .map_err(|error| std::io::Error::other(error.to_string()).into()),
                GenericFrameKind::DeliveryAck => relay
                    .send_channel_ack(relay_token, peer_id, payload)
                    .await
                    .map_err(|error| std::io::Error::other(error.to_string()).into()),
            },
            ActiveConnection::Relay(None) => Err(std::io::Error::new(
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
        let is_current = session.route.as_ref().is_some_and(|route| {
            matches!(&route.carrier, ActiveConnection::Generic(handle) if handle.id() == route_id)
        });
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

    /// 显式断开结束 Session，并关闭仍绑定的 route carrier。
    pub(crate) async fn close(&self, peer_id: &str) {
        let route = {
            let mut sessions = self.sessions.write().await;
            let Some(session) = sessions.get_mut(peer_id) else {
                return;
            };
            session.state = SessionState::Closed;
            session.route.take()
        };
        if let Some(route) = route {
            route.close().await;
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

    /// 检查某次重连任务是否仍属于同一个 Session，且没有被显式关闭或
    /// 其他连接任务完成。
    pub(crate) async fn should_reconnect(&self, peer_id: &str, session_id: SessionId) -> bool {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .is_some_and(|session| {
                session.id == session_id
                    && !matches!(
                        session.state,
                        SessionState::Connected | SessionState::Closed
                    )
            })
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
    use network_nat::PathManager;
    use network_quic::QuicEndpointManager;
    use std::sync::Arc;

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
        assert!(manager.should_reconnect("peer-b", first).await);
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
        assert!(!manager.should_reconnect("peer-b", first).await);
        assert!(manager.should_reconnect("peer-b", second).await);
        manager.close("peer-b").await;
        assert!(!manager.should_reconnect("peer-b", second).await);
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

    #[tokio::test]
    async fn stale_connection_attempt_cannot_attach_to_replaced_session() {
        let manager = SessionManager::new();
        let first = match manager.begin_connect("peer-b").await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        manager.close("peer-b").await;
        let second = match manager.begin_connect("peer-b").await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        assert_ne!(first, second);
        assert!(!manager.should_reconnect("peer-b", first).await);
        assert!(manager.should_reconnect("peer-b", second).await);
    }

    #[tokio::test]
    async fn relay_route_can_be_promoted_atomically_after_direct_connection_is_ready() {
        let manager = SessionManager::new();
        let session_id = match manager.begin_connect("peer-b").await {
            ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        };
        assert!(
            manager
                .mark_route_connected("peer-b", session_id, RouteType::Relay)
                .await
        );

        let server_socket = std::net::UdpSocket::bind("127.0.0.1:0").expect("server socket");
        let server =
            QuicEndpointManager::from_bound_socket(server_socket, Arc::new(PathManager::new()))
                .expect("server endpoint");
        let client_socket = std::net::UdpSocket::bind("127.0.0.1:0").expect("client socket");
        let client =
            QuicEndpointManager::from_bound_socket(client_socket, Arc::new(PathManager::new()))
                .expect("client endpoint");
        let server_endpoint = server.endpoint.clone();
        let accept_task = tokio::spawn(async move {
            let incoming = server_endpoint.accept().await.expect("incoming connection");
            incoming.await.expect("server connection")
        });
        let connection = client
            .endpoint
            .connect(
                server.endpoint.local_addr().expect("server address"),
                "ssh-mobile",
            )
            .expect("create direct connection")
            .await
            .expect("direct connection");
        let server_connection = accept_task.await.expect("accept task");

        assert!(
            manager
                .replace_route_if_current(
                    "peer-b",
                    session_id,
                    RouteType::Relay,
                    connection.clone(),
                    RouteType::QuicDirect,
                )
                .await
        );
        assert_eq!(
            manager.current_route("peer-b").await,
            Some(RouteType::QuicDirect)
        );
        assert_eq!(
            manager
                .current_connection("peer-b")
                .await
                .expect("promoted connection")
                .stable_id(),
            connection.stable_id()
        );

        connection.close(VarInt::from_u32(0), b"test complete");
        server_connection.close(VarInt::from_u32(0), b"test complete");
        client.endpoint.close(VarInt::from_u32(0), b"test complete");
        server.endpoint.close(VarInt::from_u32(0), b"test complete");
    }
}
