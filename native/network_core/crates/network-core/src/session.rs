//! Session 生命周期与当前 transport connection 的隔离。

use network_protocol::RouteType;
use quinn::{Connection, VarInt};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::RwLock;

/// 标识一次跨 Connection 的业务会话。
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) struct SessionId(u64);

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

/// Session 聚合根。当前阶段只放置 Connection 生命周期和 Route 状态；
/// Delivery/Crypto/Transfer 状态会在各自阶段接入，不回退到 Connection map。
struct Session {
    id: SessionId,
    state: SessionState,
    active_route: RouteType,
    connection: Option<Connection>,
}

/// App Scope 内唯一的 Session owner。
pub(crate) struct SessionManager {
    next_id: AtomicU64,
    sessions: RwLock<HashMap<String, Session>>,
}

impl SessionManager {
    pub(crate) fn new() -> Self {
        Self {
            next_id: AtomicU64::new(1),
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
                    let mut replacement = self.new_session();
                    replacement.state = SessionState::Connecting;
                    let id = replacement.id;
                    *session = replacement;
                    return ConnectDecision::Started(id);
                }
                SessionState::Idle => {
                    session.state = SessionState::Connecting;
                    session.active_route = RouteType::Unspecified;
                    session.connection = None;
                    return ConnectDecision::Started(session.id);
                }
                SessionState::Disconnected | SessionState::Failed => {
                    session.state = SessionState::Reconnecting;
                    session.active_route = RouteType::Unspecified;
                    session.connection = None;
                    return ConnectDecision::Started(session.id);
                }
            }
        }

        let mut session = self.new_session();
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
                .or_insert_with(|| self.new_session()),
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
        session.state = SessionState::Connected;
        session.active_route = route;
        session.connection = Some(connection);
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
            .connection
            .as_ref()
            .is_some_and(|connection| connection.stable_id() == current_connection.stable_id());
        if session.id != expected_session_id || session.state == SessionState::Closed || !is_current
        {
            drop(sessions);
            replacement.close(VarInt::from_u32(0), b"session replaced");
            return None;
        }
        let previous = session.connection.replace(replacement);
        session.state = SessionState::Connected;
        session.active_route = route;
        previous
    }

    /// 记录一个没有 Quinn handle 的已连接 Route，例如 Relay 控制面。
    pub(crate) async fn mark_route_connected(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        route: RouteType,
    ) -> bool {
        let mut sessions = self.sessions.write().await;
        let Some(session) = sessions.get_mut(peer_id) else {
            return false;
        };
        if session.state == SessionState::Closed || session.id != expected_session_id {
            return false;
        }
        session.state = SessionState::Connected;
        session.active_route = route;
        session.connection = None;
        true
    }

    /// 取得当前可靠 direct Connection；Session 自身不随 Connection drop 消失。
    pub(crate) async fn current_connection(&self, peer_id: &str) -> Option<Connection> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .filter(|session| session.state == SessionState::Connected)
            .and_then(|session| session.connection.clone())
    }

    pub(crate) async fn current_session_id(&self, peer_id: &str) -> Option<SessionId> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .map(|session| session.id)
    }

    /// 返回当前逻辑 Session 的 active Route；Relay 没有 Quinn handle。
    pub(crate) async fn current_route(&self, peer_id: &str) -> Option<RouteType> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .filter(|session| session.state == SessionState::Connected)
            .map(|session| session.active_route)
    }

    pub(crate) async fn is_connected(&self, peer_id: &str) -> bool {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .is_some_and(|session| session.state == SessionState::Connected)
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
            .connection
            .as_ref()
            .is_some_and(|current| current.stable_id() == connection.stable_id());
        if !is_current {
            return None;
        }
        let session_id = session.id;
        session.connection = None;
        session.active_route = RouteType::Unspecified;
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
        session.connection = None;
        session.active_route = RouteType::Unspecified;
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
                session.connection = None;
                session.active_route = RouteType::Unspecified;
                session.state = SessionState::Failed;
            }
        }
    }

    /// 显式断开结束 Session，并关闭仍绑定的 QUIC Connection。
    pub(crate) async fn close(&self, peer_id: &str) {
        let connection = {
            let mut sessions = self.sessions.write().await;
            let Some(session) = sessions.get_mut(peer_id) else {
                return;
            };
            session.state = SessionState::Closed;
            session.active_route = RouteType::Unspecified;
            session.connection.take()
        };
        if let Some(connection) = connection {
            connection.close(VarInt::from_u32(0), b"session closed");
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

    fn new_session(&self) -> Session {
        Session {
            id: SessionId(self.next_id.fetch_add(1, Ordering::Relaxed)),
            state: SessionState::Idle,
            active_route: RouteType::Unspecified,
            connection: None,
        }
    }
}

impl SessionId {
    /// Delivery 使用独立的 Session key，避免把 peer_id 错当成 SessionId。
    pub(crate) fn wire_key(self) -> String {
        format!("{:016x}", self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
