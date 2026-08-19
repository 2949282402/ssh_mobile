//! transport-network v2：本地 Discovery 身份与状态（设计 §7/§9/§29）。
//!
//! [`LocalDiscoveryManager`] 只持有**本地**设备的 Discovery 身份：
//!
//! - `runtime_epoch`：Native Runtime 每次启动随机生成的新 128-bit ID（两个 u64，
//!   大端序 high/low）。设备重启后进入新 epoch，同 epoch 内 revision 严格递增，
//!   跨 epoch 不存在大小比较（§7）。
//! - `revision`：epoch 内单调递增，起点 1；网络/候选变化时 `bump_revision()`。
//! - `state`：[`LocalDiscoveryState`] —— 只有收到 DiscoveryAck 才进入 `Published`，
//!   失败超过上限进入 `Degraded`（§9）。
//! - 候选 bundle 与传输能力快照：每次网络变化后重新 gather 刷新。
//!
//! 它**不是**远端 Discovery 真值的持久存储（那属于按次 Resolve 的
//! [`crate::discovery::resolver`]）；本类型只回答「我当前应发布什么」。

use std::sync::Mutex;

use network_relay::v2::{CandidateBundle, DiscoverySnapshot, RuntimeEpoch, TransportCapability};

use crate::discovery::snapshot::build_local_snapshot;

/// 本地 Discovery 状态机（§9）。
///
/// ```text
/// Idle ──trigger──▶ Publishing ──ACK──▶ Published
///                     │
///                     └─超过 max attempts─▶ Degraded
/// ```
///
/// `Degraded` 只表示最近一次发布未确认；控制连接**不需要**因此断开（§9）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LocalDiscoveryState {
    /// 已 begin_epoch 但尚未发布，或 revision 已提升需要重新发布。
    Idle,
    /// 一次 DiscoveryPublish 正在等待 DiscoveryAck。
    Publishing,
    /// 最近一次发布已收到匹配的 ACK。
    Published,
    /// 发布超过有限重试上限仍未确认。
    Degraded,
}

/// [`LocalDiscoveryManager`] 的可变内部状态。
struct LocalDiscoveryInner {
    runtime_epoch: RuntimeEpoch,
    revision: u32,
    state: LocalDiscoveryState,
    candidate_bundle: CandidateBundle,
    transport_capabilities: Vec<TransportCapability>,
}

/// 本地 Discovery 生命周期 owner。
///
/// 所有方法都是同步的（不跨 await 持有锁），因此内部使用 `std::sync::Mutex`
/// 提供 `&self` 级可变性，便于通过 `Arc` 在运行时与发布任务间共享。
pub(crate) struct LocalDiscoveryManager {
    inner: Mutex<LocalDiscoveryInner>,
}

impl LocalDiscoveryManager {
    /// 开始一个新的本地 Discovery 生命周期：生成全新的随机 `runtime_epoch`，
    /// `revision = 1`，状态为 `Idle`。应在 Native Runtime 每次启动时调用一次。
    pub(crate) fn begin_epoch() -> Self {
        let [high, low] = rand::random::<[u64; 2]>();
        Self::with_epoch(high, low, 1)
    }

    /// 用显式 epoch 构造，`revision` 从给定值开始。`begin_epoch` 依赖它；
    /// 测试也用它构造确定性 epoch。
    pub(crate) fn with_epoch(high: u64, low: u64, revision: u32) -> Self {
        Self {
            inner: Mutex::new(LocalDiscoveryInner {
                runtime_epoch: RuntimeEpoch { high, low },
                revision,
                state: LocalDiscoveryState::Idle,
                candidate_bundle: CandidateBundle {
                    candidates: Vec::new(),
                },
                transport_capabilities: Vec::new(),
            }),
        }
    }

    /// 网络/候选变化（interface/IP/NAT/STUN/rebind）后提升 revision（§9）。
    ///
    /// revision 只在同 epoch 内单调递增；溢出使用饱和加（u32 现实不可达）。
    /// 提升后状态回到 `Idle`，表示需要重新发布才能再次进入 `Published`。
    #[allow(dead_code)] // forward path：Step 6 网络变化检测接线后启用
    pub(crate) fn bump_revision(&self) {
        let mut inner = self.inner.lock().expect("local discovery lock");
        inner.revision = inner.revision.saturating_add(1);
        inner.state = LocalDiscoveryState::Idle;
    }

    /// 刷新本地候选 bundle（由 snapshot::candidate_bundle_from_local 提供）。
    pub(crate) fn set_candidate_bundle(&self, bundle: CandidateBundle) {
        self.inner
            .lock()
            .expect("local discovery lock")
            .candidate_bundle = bundle;
    }

    /// 刷新本地传输能力集合（§16/§28 transport registry 落地前的固定集合）。
    pub(crate) fn set_transport_capabilities(&self, capabilities: Vec<TransportCapability>) {
        self.inner
            .lock()
            .expect("local discovery lock")
            .transport_capabilities = capabilities;
    }

    /// 构造当前 DiscoverySnapshot（epoch + revision + capabilities + candidate_bundle）。
    pub(crate) fn snapshot(&self) -> DiscoverySnapshot {
        let inner = self.inner.lock().expect("local discovery lock");
        build_local_snapshot(
            &inner.runtime_epoch,
            inner.revision,
            &inner.transport_capabilities,
            &inner.candidate_bundle,
        )
    }

    /// 标记一次发布已开始（进入 `Publishing`）。
    pub(crate) fn mark_publishing(&self) {
        self.inner.lock().expect("local discovery lock").state = LocalDiscoveryState::Publishing;
    }

    /// 收到匹配 ACK 后标记 `Published`。
    pub(crate) fn mark_published(&self) {
        self.inner.lock().expect("local discovery lock").state = LocalDiscoveryState::Published;
    }

    /// 超过有限重试上限后标记 `Degraded`。
    pub(crate) fn mark_degraded(&self) {
        self.inner.lock().expect("local discovery lock").state = LocalDiscoveryState::Degraded;
    }

    /// 当前 runtime_epoch。
    #[allow(dead_code)] // forward path：Step 6 resolver/connectivity attempt 使用
    pub(crate) fn runtime_epoch(&self) -> RuntimeEpoch {
        self.inner
            .lock()
            .expect("local discovery lock")
            .runtime_epoch
            .clone()
    }

    /// 当前 revision。
    #[allow(dead_code)] // forward path：Step 6 resolver/connectivity attempt 使用
    pub(crate) fn revision(&self) -> u32 {
        self.inner.lock().expect("local discovery lock").revision
    }

    /// 当前本地 Discovery 状态。
    #[allow(dead_code)] // forward path：Step 6 connectivity attempt 使用
    pub(crate) fn state(&self) -> LocalDiscoveryState {
        self.inner.lock().expect("local discovery lock").state
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn begin_epoch_produces_fresh_epoch_and_revision_one() {
        let first = LocalDiscoveryManager::begin_epoch();
        let second = LocalDiscoveryManager::begin_epoch();
        // 两个随机 epoch 必须不同（128-bit 碰撞概率可忽略）。
        assert_ne!(first.runtime_epoch(), second.runtime_epoch());
        assert_eq!(first.revision(), 1);
        assert_eq!(first.state(), LocalDiscoveryState::Idle);
        // high/low 至少构成一个非零的 128-bit 标识。
        let epoch = first.runtime_epoch();
        assert!(epoch.high != 0 || epoch.low != 0);
    }

    #[test]
    fn bump_revision_increments_within_epoch() {
        let manager = LocalDiscoveryManager::begin_epoch();
        let epoch = manager.runtime_epoch();
        manager.bump_revision();
        manager.bump_revision();
        assert_eq!(manager.revision(), 3);
        // epoch 不变：同一次 runtime 生命周期内 revision 单调递增（§7）。
        assert_eq!(manager.runtime_epoch(), epoch);
        // 提升 revision 后回到 Idle，需要重新发布。
        assert_eq!(manager.state(), LocalDiscoveryState::Idle);
    }

    #[test]
    fn snapshot_carries_epoch_revision_capabilities_and_candidates() {
        let manager =
            LocalDiscoveryManager::with_epoch(0x1122_3344_5566_7788, 0x99aa_bbcc_ddee_ff00, 7);
        manager.set_candidate_bundle(CandidateBundle {
            candidates: vec![b"candidate-a".to_vec(), b"candidate-b".to_vec()],
        });
        manager
            .set_transport_capabilities(vec![TransportCapability::Quic, TransportCapability::Tcp]);
        let snapshot = manager.snapshot();
        assert_eq!(
            snapshot.runtime_epoch.as_ref(),
            Some(&RuntimeEpoch {
                high: 0x1122_3344_5566_7788,
                low: 0x99aa_bbcc_ddee_ff00,
            })
        );
        assert_eq!(snapshot.revision, 7);
        assert_eq!(
            snapshot.transport_capabilities,
            vec![
                TransportCapability::Quic as i32,
                TransportCapability::Tcp as i32
            ]
        );
        let bundle = snapshot.candidate_bundle.expect("candidate bundle");
        assert_eq!(
            bundle.candidates,
            vec![b"candidate-a".to_vec(), b"candidate-b".to_vec()]
        );
        // 同一 epoch/revision 的 snapshot 应带非零发布时间。
        assert!(snapshot.published_at_ms != 0);
    }

    #[test]
    fn state_transitions_follow_publish_lifecycle() {
        let manager = LocalDiscoveryManager::begin_epoch();
        manager.mark_publishing();
        assert_eq!(manager.state(), LocalDiscoveryState::Publishing);
        manager.mark_published();
        assert_eq!(manager.state(), LocalDiscoveryState::Published);
        manager.mark_degraded();
        assert_eq!(manager.state(), LocalDiscoveryState::Degraded);
        // bump 后回到 Idle（新 revision 需要重新发布）。
        manager.bump_revision();
        assert_eq!(manager.state(), LocalDiscoveryState::Idle);
    }
}
