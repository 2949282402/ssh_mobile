//! transport-network v2：已就绪 Session 摘要索引（设计 §34/§40）。
//!
//! 新的 `connect()` 在进入控制面前先让 Runtime 的路径 owner 复用已经健康且
//! capability-compatible 的现有 path；这条 fast path 不会发出 target-less
//! ConnectivityOffer。若需要创建/替换连接，Stage B 仍然先 Resolve（§10/§34）。
//! Resolve 之后，如果 [`ReadySessionIndex`] 已为该 peer 登记了一条连接摘要
//! （健康由调用方通过 Runtime 的 PeerPathManager 确认），且：
//!
//! - peer `runtime_epoch` == Resolve 返回的 epoch，且
//! - 连接 capability 满足本次业务
//!
//! 则允许调用方尝试重用现有 Connection。若 Resolve 返回的 epoch 与已登记 epoch 不同，则必须
//! 关闭旧连接并创建新的 ConnectivityAttempt（§34）。
//!
//! 该索引只保存映射（peer → epoch/capability/session），不持有 Connection 本体；
//! 真正的 Connection 归 Runtime 的 PeerPathManager/PhysicalRoute 所有，健康判断也只能由
//! 路径 owner 完成。索引是纯映射，可在单元测试中独立验证复用规则。

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

/// 连接摘要索引；不是连接 owner，也不是 connectivity truth。
#[derive(Debug, Default)]
pub(crate) struct ReadySessionIndex {
    inner: RwLock<HashMap<String, RegisteredConnection>>,
}

impl ReadySessionIndex {
    pub(crate) fn new() -> Self {
        Self {
            inner: RwLock::new(HashMap::new()),
        }
    }

    /// 按 §34 查询可复用连接。
    ///
    /// 返回 `Some(registered)` 当且仅当已登记连接与 Resolve 返回的 epoch 一致且
    /// capability 满足本次请求。调用方仍需通过 Runtime 的 PeerPathManager 确认该路径健康。
    #[cfg(test)]
    pub(crate) fn lookup(
        &self,
        peer_id: &str,
        remote_epoch: &Option<RuntimeEpoch>,
        capability: u8,
    ) -> Option<RegisteredConnection> {
        let inner = self.inner.read().expect("ready session index lock");
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

    /// Return the current capability-compatible registration without applying
    /// a new Resolve epoch. This is only for the pre-control healthy-path
    /// fast path; new/replacement attempts must continue to use [`Self::lookup`]
    /// with the authoritative Resolve epoch.
    pub(crate) fn lookup_registered(
        &self,
        peer_id: &str,
        capability: u8,
    ) -> Option<RegisteredConnection> {
        let inner = self.inner.read().expect("ready session index lock");
        let registered = inner.get(peer_id)?;
        capability_covers(registered.capability, capability).then(|| registered.clone())
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
            .expect("ready session index lock")
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
        let mut inner = self.inner.write().expect("ready session index lock");
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
            .expect("ready session index lock")
            .remove(peer_id);
    }

    /// 仅当登记仍归属指定 session 时移除（避免误删后续已替换的登记）。
    pub(crate) fn unregister_if_session(&self, peer_id: &str, session_id: SessionId) {
        let mut inner = self.inner.write().expect("ready session index lock");
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
#[path = "../tests/connect/ready_index.rs"]
mod tests;
