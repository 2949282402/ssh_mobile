//! transport-network v2：连接重用注册表（设计 §34/§40）。
//!
//! 每次新的 `connect()` 都 Resolve（§10/§34）。Resolve 之后，如果
//! [`ConnectionRegistry`] 已为该 peer 登记了一条**健康**连接（健康由调用方通过
//! `sessions.is_connected` 确认），且：
//!
//! - peer `runtime_epoch` == Resolve 返回的 epoch，且
//! - 连接 capability 满足本次业务
//!
//! 则允许重用现有 Connection。若 Resolve 返回的 epoch 与已登记 epoch 不同，则必须
//! 关闭旧连接并创建新的 ConnectivityAttempt（§34）。
//!
//! 注册表只保存映射（peer → epoch/capability/session），不持有 Connection 本体；
//! 真正的 Connection 归 SessionManager 的 route 所有。注册表是纯映射，可在单元测试
//! 中独立验证复用规则。

use std::collections::HashMap;
use std::sync::RwLock;

use network_relay::v2::RuntimeEpoch;

use crate::session::SessionId;

/// 已登记的连接摘要。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RegisteredConnection {
    /// Resolve 观察到的对端 runtime_epoch；本地直连（无控制面）时为 `None`。
    pub(crate) remote_runtime_epoch: Option<RuntimeEpoch>,
    /// 连接能力位（本轮固定为 QUIC 基线，§17/§34 capability）。
    pub(crate) capability: u8,
    /// 归属的 ConnectionSession。
    pub(crate) session_id: SessionId,
}

/// 连接重用注册表。
#[derive(Debug, Default)]
pub(crate) struct ConnectionRegistry {
    inner: RwLock<HashMap<String, RegisteredConnection>>,
}

impl ConnectionRegistry {
    pub(crate) fn new() -> Self {
        Self {
            inner: RwLock::new(HashMap::new()),
        }
    }

    /// 按 §34 查询可复用连接。
    ///
    /// 返回 `Some(registered)` 当且仅当已登记连接与 Resolve 返回的 epoch 一致且
    /// capability 满足本次请求。调用方仍需通过 SessionManager 确认该连接健康。
    pub(crate) fn lookup(
        &self,
        peer_id: &str,
        remote_epoch: &Option<RuntimeEpoch>,
        capability: u8,
    ) -> Option<RegisteredConnection> {
        let inner = self.inner.read().expect("connection registry lock");
        let registered = inner.get(peer_id)?;
        if !epochs_match(
            registered.remote_runtime_epoch.as_ref(),
            remote_epoch.as_ref(),
        ) {
            return None;
        }
        if !capability_covers(registered.capability, capability) {
            return None;
        }
        Some(registered.clone())
    }

    /// 登记一条新建立的连接（替换旧条目）。
    pub(crate) fn register(
        &self,
        peer_id: &str,
        remote_epoch: Option<RuntimeEpoch>,
        capability: u8,
        session_id: SessionId,
    ) {
        self.inner
            .write()
            .expect("connection registry lock")
            .insert(
                peer_id.to_string(),
                RegisteredConnection {
                    remote_runtime_epoch: remote_epoch,
                    capability,
                    session_id,
                },
            );
    }

    /// 返回与 Resolve epoch 不一致的旧登记（若有），并移除它；调用方据此关闭旧连接。
    ///
    /// §34：现有 Connection = E7，Resolve = E8 → 必须 Close old + 新建 ConnectivityAttempt。
    /// epoch 都为空（本地直连）时视为匹配，不视为换代。
    pub(crate) fn take_obsolete(
        &self,
        peer_id: &str,
        remote_epoch: &Option<RuntimeEpoch>,
    ) -> Option<RegisteredConnection> {
        let mut inner = self.inner.write().expect("connection registry lock");
        let registered = inner.get(peer_id)?;
        if epochs_match(
            registered.remote_runtime_epoch.as_ref(),
            remote_epoch.as_ref(),
        ) {
            return None;
        }
        inner.remove(peer_id)
    }

    /// 移除指定 peer 的登记（连接关闭/断开时调用）。
    pub(crate) fn unregister(&self, peer_id: &str) {
        self.inner
            .write()
            .expect("connection registry lock")
            .remove(peer_id);
    }

    /// 仅当登记仍归属指定 session 时移除（避免误删后续已替换的登记）。
    pub(crate) fn unregister_if_session(&self, peer_id: &str, session_id: SessionId) {
        let mut inner = self.inner.write().expect("connection registry lock");
        if inner
            .get(peer_id)
            .is_some_and(|registered| registered.session_id == session_id)
        {
            inner.remove(peer_id);
        }
    }
}

/// 两个 epoch 是否匹配：都为空（本地直连）匹配；两者相等匹配；否则不匹配。
fn epochs_match(left: Option<&RuntimeEpoch>, right: Option<&RuntimeEpoch>) -> bool {
    match (left, right) {
        (None, None) => true,
        (Some(left), Some(right)) => left == right,
        _ => false,
    }
}

/// capability 覆盖判定（§34）：registered 覆盖 requested 当且仅当位包含。
/// `requested == 0`（旧调用方未指定）恒被覆盖；QUIC 基线登记
/// (`DEFAULT_CONNECTION_CAPABILITY = message|stream`) 覆盖任意单项请求。
fn capability_covers(registered: u8, requested: u8) -> bool {
    (registered & requested) == requested
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::SessionManager;

    fn epoch(high: u64, low: u64) -> Option<RuntimeEpoch> {
        Some(RuntimeEpoch { high, low })
    }

    async fn session_id(manager: &SessionManager, peer_id: &str) -> SessionId {
        match manager.begin_connect(peer_id).await {
            crate::session::ConnectDecision::Started(id) => id,
            decision => panic!("unexpected decision: {decision:?}"),
        }
    }

    #[tokio::test]
    async fn lookup_reuses_same_epoch_and_capability() {
        let manager = SessionManager::new();
        let session_b = session_id(&manager, "device-b").await;
        let registry = ConnectionRegistry::new();
        registry.register("device-b", epoch(1, 2), 0, session_b);
        let found = registry.lookup("device-b", &epoch(1, 2), 0).expect("reuse");
        assert_eq!(found.session_id, session_b);
    }

    #[tokio::test]
    async fn lookup_returns_none_for_a_different_epoch() {
        let manager = SessionManager::new();
        let session_e7 = session_id(&manager, "device-b").await;
        let registry = ConnectionRegistry::new();
        registry.register("device-b", epoch(7, 8), 0, session_e7);
        assert!(registry.lookup("device-b", &epoch(8, 8), 0).is_none());
        assert!(registry.lookup("device-b", &epoch(7, 9), 0).is_none());
    }

    #[tokio::test]
    async fn take_obsolete_closes_old_when_epoch_changed() {
        let manager = SessionManager::new();
        let session_e7 = session_id(&manager, "device-b").await;
        let registry = ConnectionRegistry::new();
        registry.register("device-b", epoch(7, 8), 0, session_e7);
        let obsolete = registry
            .take_obsolete("device-b", &epoch(8, 8))
            .expect("old epoch must be taken");
        assert_eq!(obsolete.session_id, session_e7);
        assert!(registry.lookup("device-b", &epoch(8, 8), 0).is_none());
    }

    #[tokio::test]
    async fn local_direct_mode_epoch_none_is_reused() {
        let manager = SessionManager::new();
        let session_local = session_id(&manager, "device-b").await;
        let registry = ConnectionRegistry::new();
        registry.register("device-b", None, 0, session_local);
        assert!(registry.lookup("device-b", &None, 0).is_some());
        // 有控制面（epoch=Some）不能复用一个 epoch=None 的本地直连。
        assert!(registry.lookup("device-b", &epoch(1, 1), 0).is_none());
        // epoch=None 本地直连遇到有 epoch 的登记 → 视为换代（take_obsolete）。
        assert!(registry.take_obsolete("device-b", &None).is_none());
    }

    #[tokio::test]
    async fn unregister_if_session_only_removes_matching_session() {
        let manager = SessionManager::new();
        let session_b = session_id(&manager, "device-b").await;
        let session_stale = session_id(&manager, "device-c").await;
        let registry = ConnectionRegistry::new();
        registry.register("device-b", epoch(1, 2), 0, session_b);
        registry.unregister_if_session("device-b", session_stale);
        assert!(registry.lookup("device-b", &epoch(1, 2), 0).is_some());
        registry.unregister_if_session("device-b", session_b);
        assert!(registry.lookup("device-b", &epoch(1, 2), 0).is_none());
    }
}
