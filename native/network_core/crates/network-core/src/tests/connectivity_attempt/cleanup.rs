/// Close a test-owned session and unregister its path without adding a
/// production lifecycle/test hook to the coordinator.
pub(crate) async fn close_session_and_unregister(
    state: Arc<RuntimeState>,
    peer_id: String,
    session_id: SessionId,
) {
    let _ = state.close_transport_path(&peer_id).await;
    state
        .connection_sessions
        .retire_session(&peer_id, session_id)
        .await;
    state.cancel_session_tasks(&peer_id, session_id).await;
    state
        .ready_session_index
        .unregister_if_session(&peer_id, session_id);
    let _ = state.peer_supervisors.disconnect(&peer_id);
    state.delivery.close_peer(&peer_id).await;
}
