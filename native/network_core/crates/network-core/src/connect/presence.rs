//! transport-network v2：Presence → UI-only 提示缓存（设计 §23/§28/§29）。
//!
//! [`PresenceHintCache`] 是 Presence 事件的唯一落点。Presence 事件（snapshot /
//! peer_online / peer_updated / peer_offline，或 v2 的 PresenceHintSnapshot /
//! PeerAvailableHint / PeerUnavailableHint）**只**更新本缓存并向 UI 发出类型化
//! presence 事件；它们**无权**修改 ConnectivityAttempt / CandidateSet /
//! ConnectionSession（§23 / §41 验收项「Presence Event 无权修改 ConnectivityAttempt」）。
//!
//! 权威的建连入口是 Resolve（§10）：即使缓存把 peer 标记为在线，真正能否建连
//! 仍由每次 connect 前的 Resolve 决定。

use std::collections::HashMap;
use std::sync::RwLock;

/// 单个 peer 的 UI 提示状态。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PresenceHint {
    /// 是否在线（仅 UI 提示，非建连权威）。
    pub(crate) online: bool,
    /// 最近一次可见的 generation（v1 兼容字段；仅用于 UI 排序/展示）。
    pub(crate) generation: u64,
}

impl PresenceHint {
    pub(crate) fn new(online: bool, generation: u64) -> Self {
        Self { online, generation }
    }
}

/// UI-only 的 Presence 提示缓存。
///
/// 线程安全：所有方法同步（不跨 await 持有锁），内部使用 `std::sync::RwLock`。
#[derive(Debug, Default)]
pub(crate) struct PresenceHintCache {
    inner: RwLock<HashMap<String, PresenceHint>>,
}

impl PresenceHintCache {
    pub(crate) fn new() -> Self {
        Self {
            inner: RwLock::new(HashMap::new()),
        }
    }

    /// 记录 peer 在线（v1 peer_online / v2 PeerAvailableHint）。
    pub(crate) fn mark_online(&self, peer_id: &str, generation: u64) {
        self.inner
            .write()
            .expect("presence hint cache lock")
            .insert(peer_id.to_string(), PresenceHint::new(true, generation));
    }

    /// 记录 peer 离线（v1 peer_offline / v2 PeerUnavailableHint）。
    pub(crate) fn mark_offline(&self, peer_id: &str) {
        self.inner
            .write()
            .expect("presence hint cache lock")
            .insert(peer_id.to_string(), PresenceHint::new(false, 0));
    }

    /// 全量快照对账：以快照为权威，缺席的已缓存 peer 标记离线并返回被移除的 peer 列表。
    pub(crate) fn reconcile_snapshot(&self, online: &[(String, u64)]) -> Vec<String> {
        let mut inner = self.inner.write().expect("presence hint cache lock");
        let snapshot_ids = online
            .iter()
            .map(|(id, _)| id.clone())
            .collect::<std::collections::HashSet<_>>();
        let dropped = inner
            .keys()
            .filter(|peer_id| !snapshot_ids.contains(*peer_id))
            .cloned()
            .collect::<Vec<_>>();
        inner.retain(|peer_id, _| snapshot_ids.contains(peer_id));
        for (peer_id, generation) in online {
            inner.insert(peer_id.clone(), PresenceHint::new(true, *generation));
        }
        dropped
    }

    /// 读取当前提示（UI 查询）。
    #[allow(dead_code)] // UI-only 查询面：Step 10 Dart 迁移后由上层消费
    pub(crate) fn get(&self, peer_id: &str) -> Option<PresenceHint> {
        self.inner
            .read()
            .expect("presence hint cache lock")
            .get(peer_id)
            .cloned()
    }

    /// 当前缓存条目数（诊断）。
    #[allow(dead_code)]
    pub(crate) fn len(&self) -> usize {
        self.inner.read().expect("presence hint cache lock").len()
    }

    /// 当前缓存的 peer 列表（诊断）。
    #[allow(dead_code)]
    pub(crate) fn peer_ids(&self) -> Vec<String> {
        self.inner
            .read()
            .expect("presence hint cache lock")
            .keys()
            .cloned()
            .collect()
    }
}

#[cfg(test)]
#[path = "../tests/connect/presence.rs"]
mod tests;
