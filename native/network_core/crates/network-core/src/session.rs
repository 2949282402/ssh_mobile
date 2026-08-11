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
        connection: Connection,
        route: RouteType,
    ) -> SessionId {
        let mut sessions = self.sessions.write().await;
        let session = sessions
            .entry(peer_id.to_string())
            .or_insert_with(|| self.new_session());
        session.state = SessionState::Connected;
        session.active_route = route;
        session.connection = Some(connection);
        session.id
    }

    /// 记录一个没有 Quinn handle 的已连接 Route，例如 Relay 控制面。
    pub(crate) async fn mark_route_connected(&self, peer_id: &str, route: RouteType) -> SessionId {
        let mut sessions = self.sessions.write().await;
        let session = sessions
            .entry(peer_id.to_string())
            .or_insert_with(|| self.new_session());
        session.state = SessionState::Connected;
        session.active_route = route;
        session.connection = None;
        session.id
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

    /// 仅当断开的 Connection 仍是当前 Connection 时才更新 Session，避免旧
    /// Connection 的收尾任务覆盖已经接入的新 Connection。
    pub(crate) async fn mark_disconnected_if_current(
        &self,
        peer_id: &str,
        connection: &Connection,
    ) -> bool {
        let mut sessions = self.sessions.write().await;
        let Some(session) = sessions.get_mut(peer_id) else {
            return false;
        };
        let is_current = session
            .connection
            .as_ref()
            .is_some_and(|current| current.stable_id() == connection.stable_id());
        if !is_current {
            return false;
        }
        session.connection = None;
        session.active_route = RouteType::Unspecified;
        session.state = SessionState::Disconnected;
        true
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

    pub(crate) async fn mark_failed(&self, peer_id: &str) {
        let mut sessions = self.sessions.write().await;
        if let Some(session) = sessions.get_mut(peer_id) {
            if matches!(
                session.state,
                SessionState::Connecting | SessionState::Reconnecting
            ) {
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
    }
}
