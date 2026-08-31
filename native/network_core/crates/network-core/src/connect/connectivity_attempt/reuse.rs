use super::*;

impl ConnectivityAttemptCoordinator {
    /// Reuse an already healthy path before opening the Stage B Resolve →
    /// Offer transaction.  The physical path owner is authoritative for this
    /// fast path: a connected session with the requested capability is already
    /// usable, while an absent/unhealthy path falls through to the
    /// authoritative Resolve and the normal epoch/index checks.
    pub(super) async fn try_reuse_before_control(
        &self,
        peer_id: &str,
        capability: u8,
    ) -> Result<Option<SessionId>, ProtocolError> {
        let state = Arc::clone(&self.state);
        let Some(session_id) = state.connection_sessions.current_session_id(peer_id).await else {
            return Ok(None);
        };
        if !state.path_is_connected(peer_id).await
            || !state.path_supports_capability(peer_id, capability).await
        {
            return Ok(None);
        }

        // A control-plane epoch hint fences the old authenticated transport
        // before this fast path can reuse it.  Normal TTL expiry does not
        // retire a healthy route; a pending/new epoch does, and the regular
        // Stage B Resolve will establish the replacement authority.
        if let Some(registered) = state
            .ready_session_index
            .lookup_registered(peer_id, capability)
        {
            if registered.session_id == session_id {
                let epoch_changed =
                    if let Some(registered_epoch) = registered.remote_runtime_epoch.as_ref() {
                        let cache = state.remote_candidate_cache.read().await;
                        cache.get(peer_id).is_some_and(|entry| {
                            entry.pending_remote_epoch().is_some() || {
                                Some(CandidateSnapshotPolicy::runtime_epoch_from_nat(
                                    entry.runtime_epoch,
                                ))
                            } != Some(
                                registered_epoch.clone(),
                            )
                        })
                    } else {
                        false
                    };
                if epoch_changed {
                    // This coordinator runs under the peer supervisor's
                    // generation. Retire the attempt-local session and path
                    // without disconnecting that supervisor from inside its
                    // own connectivity task.
                    state.fail_session(peer_id, session_id).await;
                    return Ok(None);
                }
            }
        }
        Ok(Some(session_id))
    }

    /// Publish the single success signal for a pre-control or shared
    /// in-progress admission reuse.
    pub(super) async fn finish_reuse(&self, peer_id: &str, session_id: SessionId) {
        let state = Arc::clone(&self.state);
        tracing::info!(
            peer_id = %peer_id,
            session = ?session_id,
            "reused existing healthy connection"
        );
        // 重用成功同样发布 Connected 终态：Dart connect() 把该事件当作成功信号
        // （失败才由命令面发 Failed），不发布会令其等待超时。
        let route = state
            .path_route(peer_id)
            .await
            .unwrap_or(RouteType::Unspecified);
        emit_peer_state(
            &state.event_tx,
            peer_id,
            PeerConnectionState::Connected,
            route,
            None,
        );
        self.set_stage(ConnectivityAttemptState::ConnectedDirect);
    }

    /// 登记一条已建立的连接（§34）。注册表记录连接**实际**能力（由 route profile
    /// 推导），而不是请求时的 class，因此 QUIC/TCP 基线连接可被后续不同 class 的
    /// 请求复用。
    pub(super) async fn register_current(
        &self,
        state: Arc<RuntimeState>,
        peer_id: &str,
        remote_epoch: &Option<RuntimeEpoch>,
        session_id: SessionId,
    ) {
        let Some(capability) = state
            .path_profile(peer_id)
            .await
            .map(profile_capability_mask)
        else {
            return;
        };
        state
            .ready_session_index
            .register(peer_id, remote_epoch.clone(), capability, session_id);
    }
}
