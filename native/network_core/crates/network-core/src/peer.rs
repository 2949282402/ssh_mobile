//! v1 对端注册表、路由选择与异步连接任务。

use network_identity::DeviceIdentity;
use network_nat::{Candidate, CandidateKind, PathManager};
use network_protocol::{
    NetworkError as ProtocolError, NetworkErrorCode, PeerConnectionState, RouteType,
    UpsertPeerCommand,
};
use network_quic::{QuicEndpointManager, QuicPeerSession};
use network_relay::RelayClient;
use quinn::{Connection, Endpoint};
use std::future::Future;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::oneshot;

use crate::events::{emit_peer_state, protocol_error, protocol_error_with_peer};
use crate::runtime::{
    PeerConfig, RuntimeState, PEER_CONNECT_TIMEOUT, RECONNECT_INITIAL_BACKOFF,
    RECONNECT_MAX_ATTEMPTS, RECONNECT_MAX_BACKOFF, RELAY_RACE_DELAY,
};
use crate::session::{ConnectDecision, SessionId};

/// 校验运行时密钥并启动 QUIC 监听器。
pub(crate) async fn configure_runtime(
    state: Arc<RuntimeState>,
    command: network_protocol::ConfigureRuntimeCommand,
) -> Result<(), ProtocolError> {
    if command.device_id.is_empty() || command.device_id.len() > 128 {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "device_id must contain 1-128 characters",
        ));
    }
    let identity_private_key: [u8; 32] = command
        .identity_private_key
        .try_into()
        .map_err(|_| protocol_error(NetworkErrorCode::InvalidArgument, "invalid identity key"))?;
    let e2e_private_key: [u8; 32] = command
        .e2e_private_key
        .try_into()
        .map_err(|_| protocol_error(NetworkErrorCode::InvalidArgument, "invalid E2E key"))?;
    let listen_address = command.listen_address.parse::<SocketAddr>().map_err(|_| {
        protocol_error(
            NetworkErrorCode::InvalidArgument,
            "listen_address must be an IP socket address",
        )
    })?;
    let receive_directory = std::path::PathBuf::from(command.receive_directory);
    if !receive_directory.is_absolute() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "receive_directory must be absolute",
        ));
    }
    if state.endpoint.read().await.is_some() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "network runtime is already configured",
        ));
    }

    let identity = Arc::new(DeviceIdentity::from_private_keys(
        command.device_id,
        identity_private_key,
        e2e_private_key,
    ));
    let manager = QuicEndpointManager::new(listen_address, Arc::new(PathManager::new()))
        .map_err(|error| protocol_error(NetworkErrorCode::QuicError, error.to_string()))?;
    let endpoint = manager.endpoint;
    *state.identity.write().await = Some(identity);
    *state.receive_directory.write().await = Some(receive_directory);
    *state.endpoint.write().await = Some(endpoint.clone());
    tokio::spawn(accept_connections(endpoint, Arc::clone(&state)));
    Ok(())
}

/// 校验并保存一个对端路由及其可信身份密钥。
pub(crate) async fn upsert_peer(
    state: &RuntimeState,
    command: UpsertPeerCommand,
) -> Result<(), ProtocolError> {
    if command.peer_id.is_empty() || command.peer_id.len() > 128 {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer_id must contain 1-128 characters",
        ));
    }
    let endpoint = if command.endpoint_address.is_empty() {
        None
    } else {
        Some(
            command
                .endpoint_address
                .parse::<SocketAddr>()
                .map_err(|_| {
                    protocol_error(
                        NetworkErrorCode::InvalidArgument,
                        "peer endpoint must be an IP socket address",
                    )
                })?,
        )
    };
    let identity_public_key: [u8; 32] = command.identity_public_key.try_into().map_err(|_| {
        protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer identity key must contain 32 bytes",
        )
    })?;
    let e2e_public_key: [u8; 32] = command.e2e_public_key.try_into().map_err(|_| {
        protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer E2E key must contain 32 bytes",
        )
    })?;
    if let Some(endpoint) = endpoint {
        let manager = Arc::new(PathManager::new());
        manager
            .add_candidates(vec![Candidate::new(
                endpoint,
                candidate_kind_for(endpoint),
                "peer-advertised".to_string(),
            )])
            .await;
        state
            .path_managers
            .write()
            .await
            .insert(command.peer_id.clone(), manager);
    } else {
        state.path_managers.write().await.remove(&command.peer_id);
    }
    state.peers.write().await.insert(
        command.peer_id.clone(),
        PeerConfig {
            endpoint,
            identity_public_key,
            e2e_public_key,
        },
    );
    state
        .trusted_peer_keys
        .write()
        .await
        .insert(command.peer_id, identity_public_key);
    Ok(())
}

/// 停止活跃对端任务，并发布类型化断开状态。
pub(crate) async fn disconnect_peer(
    state: &RuntimeState,
    peer_id: String,
) -> Result<(), ProtocolError> {
    if peer_id.is_empty() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer_id is required",
        ));
    }
    state.sessions.close(&peer_id).await;
    emit_peer_state(
        &state.event_tx,
        &peer_id,
        PeerConnectionState::Disconnected,
        RouteType::Unspecified,
        None,
    );
    Ok(())
}

/// 执行 Direct/Relay 连接竞速，并将先 ready 的 Route 绑定到 Session。
pub(crate) async fn connect_peer(
    state: Arc<RuntimeState>,
    peer_id: String,
) -> Result<(), ProtocolError> {
    let endpoint = state.endpoint.read().await.clone().ok_or_else(|| {
        protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "runtime is not configured",
            "connect",
            &peer_id,
        )
    })?;
    let identity = state.identity.read().await.clone().ok_or_else(|| {
        protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "runtime is not configured",
            "connect",
            &peer_id,
        )
    })?;
    let peer = state
        .peers
        .read()
        .await
        .get(&peer_id)
        .cloned()
        .ok_or_else(|| {
            protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                "peer has no configured route",
                "connect",
                &peer_id,
            )
        })?;
    let session_id = match state.sessions.begin_connect(&peer_id).await {
        ConnectDecision::AlreadyConnected(_) | ConnectDecision::InProgress(_) => return Ok(()),
        ConnectDecision::Started(session_id) => session_id,
    };
    let selected_endpoint = match state.path_managers.read().await.get(&peer_id).cloned() {
        Some(manager) => manager
            .select_best_path()
            .await
            .map(|candidate| candidate.endpoint),
        None => peer.endpoint,
    };
    let relay = state.relay.read().await.clone();
    let relay = match relay {
        Some(relay) if relay.is_usable().await => Some(relay),
        _ => None,
    };

    let route = match (selected_endpoint, relay) {
        (Some(peer_endpoint), Some(relay)) => {
            let direct = connect_direct(
                endpoint,
                peer_endpoint,
                identity,
                peer.identity_public_key,
                peer_id.clone(),
            );
            let relay_attempt =
                connect_relay(Arc::clone(&state), relay, peer_id.clone(), RELAY_RACE_DELAY);
            let route = race_first_ready(direct, relay_attempt).await;
            state.relay_lookups.write().await.remove(&peer_id);
            route
        }
        (Some(peer_endpoint), None) => connect_direct(
            endpoint,
            peer_endpoint,
            identity,
            peer.identity_public_key,
            peer_id.clone(),
        )
        .await
        .map(ReadyRoute::Direct),
        (None, Some(relay)) => {
            connect_relay(Arc::clone(&state), relay, peer_id.clone(), Duration::ZERO)
                .await
                .map(|_| ReadyRoute::Relay)
        }
        (None, None) => Err(protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "peer has no usable direct or Relay route",
            "connect",
            &peer_id,
        )),
    };

    match route {
        Ok(ReadyRoute::Direct(connection)) => {
            let attached = state
                .sessions
                .attach_connection(
                    &peer_id,
                    Some(session_id),
                    connection.clone(),
                    RouteType::QuicDirect,
                )
                .await;
            if !attached {
                return Err(protocol_error_with_peer(
                    NetworkErrorCode::Cancelled,
                    "connection completed after Session was closed",
                    "connect",
                    &peer_id,
                ));
            }
            emit_peer_state(
                &state.event_tx,
                &peer_id,
                PeerConnectionState::Connected,
                RouteType::QuicDirect,
                None,
            );
            let _ = state.delivery.recover_session(&peer_id).await;
            tokio::spawn(receive_file_streams(peer_id, connection, state));
            Ok(())
        }
        Ok(ReadyRoute::Relay) => {
            let attached = state
                .sessions
                .mark_route_connected(&peer_id, session_id, RouteType::Relay)
                .await;
            if !attached {
                return Err(protocol_error_with_peer(
                    NetworkErrorCode::Cancelled,
                    "Relay route completed after Session was closed",
                    "connect",
                    &peer_id,
                ));
            }
            emit_peer_state(
                &state.event_tx,
                &peer_id,
                PeerConnectionState::Connected,
                RouteType::Relay,
                None,
            );
            let _ = state.delivery.recover_session(&peer_id).await;
            Ok(())
        }
        Err(error) => {
            state.sessions.mark_failed(&peer_id, session_id).await;
            Err(error)
        }
    }
}

/// Direct QUIC 尝试的总预算为 8 秒，避免连接和认证各自再等待一次。
async fn connect_direct(
    endpoint: Endpoint,
    peer_endpoint: SocketAddr,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
) -> Result<Connection, ProtocolError> {
    let timeout_peer_id = peer_id.clone();
    let attempt = async move {
        let connecting = endpoint.connect(peer_endpoint, "ssh-mobile").map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::QuicError,
                "failed to create QUIC connection",
                "connect",
                &peer_id,
            )
        })?;
        let connection = connecting.await.map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::QuicError,
                "QUIC connection failed",
                "connect",
                &peer_id,
            )
        })?;
        let session = QuicPeerSession::new(connection.clone(), peer_id.clone());
        session
            .perform_handshake(&identity, expected_peer_public_key)
            .await
            .map_err(|_| {
                protocol_error_with_peer(
                    NetworkErrorCode::AuthenticationFailed,
                    "peer authentication failed",
                    "connect",
                    &peer_id,
                )
            })?;
        Ok::<Connection, ProtocolError>(connection)
    };
    tokio::time::timeout(PEER_CONNECT_TIMEOUT, attempt)
        .await
        .map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                "Direct QUIC connection timed out",
                "connect",
                &timeout_peer_id,
            )
        })?
}

/// Relay lookup 在 Direct 启动后延迟 500ms，避免 UDP 被封锁时先浪费完整
/// Direct timeout；没有 Direct candidate 时由调用方传入零延迟。
async fn connect_relay(
    state: Arc<RuntimeState>,
    relay: Arc<RelayClient>,
    peer_id: String,
    delay: Duration,
) -> Result<(), ProtocolError> {
    tokio::time::sleep(delay).await;
    let (lookup_tx, lookup_rx) = oneshot::channel();
    state
        .relay_lookups
        .write()
        .await
        .insert(peer_id.clone(), lookup_tx);
    if relay.lookup_peer(&peer_id).await.is_err() {
        state.relay_lookups.write().await.remove(&peer_id);
        return Err(protocol_error_with_peer(
            NetworkErrorCode::RelayError,
            "Relay peer lookup failed",
            "connect",
            &peer_id,
        ));
    }
    let online = tokio::time::timeout(PEER_CONNECT_TIMEOUT, lookup_rx)
        .await
        .ok()
        .and_then(Result::ok)
        .unwrap_or(false);
    state.relay_lookups.write().await.remove(&peer_id);
    if !online {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::PeerOffline,
            "Relay peer is offline or did not answer lookup",
            "connect",
            &peer_id,
        ));
    }
    Ok(())
}

enum ReadyRoute<T> {
    Direct(T),
    Relay,
}

/// 两条路线都必须以成功为胜出条件；一条路线快速失败时仍等待另一条
/// 路线，只有全部失败才返回错误。
async fn race_first_ready<Direct, Relay, ConnectionT>(
    direct: Direct,
    relay: Relay,
) -> Result<ReadyRoute<ConnectionT>, ProtocolError>
where
    Direct: Future<Output = Result<ConnectionT, ProtocolError>>,
    Relay: Future<Output = Result<(), ProtocolError>>,
{
    tokio::pin!(direct);
    tokio::pin!(relay);
    tokio::select! {
        direct_result = &mut direct => match direct_result {
            Ok(connection) => Ok(ReadyRoute::Direct(connection)),
            Err(direct_error) => relay
                .await
                .map(|_| ReadyRoute::Relay)
                .map_err(|_| direct_error),
        },
        relay_result = &mut relay => match relay_result {
            Ok(()) => Ok(ReadyRoute::Relay),
            Err(relay_error) => direct
                .await
                .map(ReadyRoute::Direct)
                .map_err(|_| relay_error),
        },
    }
}

/// 为路径选择和诊断对端点进行分类。
fn candidate_kind_for(endpoint: SocketAddr) -> CandidateKind {
    match endpoint.ip() {
        std::net::IpAddr::V4(address)
            if address.is_private() || address.is_loopback() || address.is_link_local() =>
        {
            CandidateKind::Lan
        }
        std::net::IpAddr::V6(address)
            if !address.is_loopback() && !address.is_unicast_link_local() =>
        {
            CandidateKind::PublicIpv6
        }
        _ => CandidateKind::ServerReflexive,
    }
}

/// 接受配置运行时的传入 QUIC 连接。
pub(crate) async fn accept_connections(endpoint: Endpoint, state: Arc<RuntimeState>) {
    while let Some(incoming) = endpoint.accept().await {
        let state = Arc::clone(&state);
        tokio::spawn(async move {
            let result = async {
                let connection = incoming.await?;
                let identity = state
                    .identity
                    .read()
                    .await
                    .clone()
                    .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?;
                let session = tokio::time::timeout(
                    PEER_CONNECT_TIMEOUT,
                    QuicPeerSession::accept_trusted(
                        connection,
                        &identity,
                        &state.trusted_peer_keys,
                    ),
                )
                .await
                .map_err(|_| {
                    std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "peer authentication timed out",
                    )
                })??;
                let peer_id = session.peer_device_id.clone();
                let connection = session.connection.clone();
                let attached = state
                    .sessions
                    .attach_connection(&peer_id, None, connection.clone(), RouteType::QuicDirect)
                    .await;
                if !attached {
                    return Err(std::io::Error::other("Session was closed").into());
                }
                emit_peer_state(
                    &state.event_tx,
                    &peer_id,
                    PeerConnectionState::Connected,
                    RouteType::QuicDirect,
                    None,
                );
                let _ = state.delivery.recover_session(&peer_id).await;
                receive_file_streams(peer_id, connection, Arc::clone(&state)).await;
                Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
            }
            .await;
            if let Err(error) = result {
                tracing::warn!("Rejected inbound QUIC connection: {}", error);
            }
        });
    }
}

/// 接受一个已认证对端的双向流。
pub(crate) async fn receive_file_streams(
    peer_id: String,
    connection: Connection,
    state: Arc<RuntimeState>,
) {
    loop {
        match connection.accept_bi().await {
            Ok((send, receive)) => {
                let state = Arc::clone(&state);
                let peer_id = peer_id.clone();
                tokio::spawn(async move {
                    crate::transfer::handle_incoming_file(peer_id, send, receive, state).await;
                });
            }
            Err(_) => {
                let disconnected_session = state
                    .sessions
                    .mark_disconnected_if_current(&peer_id, &connection)
                    .await;
                if let Some(session_id) = disconnected_session {
                    emit_peer_state(
                        &state.event_tx,
                        &peer_id,
                        PeerConnectionState::Disconnected,
                        RouteType::Unspecified,
                        None,
                    );
                    schedule_reconnect(Arc::clone(&state), peer_id.clone(), session_id);
                }
                return;
            }
        }
    }
}

/// 为一个 Session 建立唯一的自动重连任务。
fn schedule_reconnect(state: Arc<RuntimeState>, peer_id: String, session_id: SessionId) {
    tokio::spawn(async move {
        let should_start = {
            let mut tasks = state.reconnect_tasks.write().await;
            match tasks.get(&peer_id).copied() {
                Some(existing) if existing == session_id => false,
                _ => {
                    tasks.insert(peer_id.clone(), session_id);
                    true
                }
            }
        };
        if !should_start {
            return;
        }
        reconnect_loop(Arc::clone(&state), peer_id.clone(), session_id).await;
        let mut tasks = state.reconnect_tasks.write().await;
        if tasks.get(&peer_id).copied() == Some(session_id) {
            tasks.remove(&peer_id);
        }
    });
}

/// 连接丢失后重新走当前 Candidate/Direct/Relay 选择；任务以 Session ID
/// 为边界，显式关闭或新建 Session 后旧任务会自然退出。
async fn reconnect_loop(state: Arc<RuntimeState>, peer_id: String, session_id: SessionId) {
    let mut failures = 0;
    let mut backoff = RECONNECT_INITIAL_BACKOFF;
    let mut last_error = None;
    while failures < RECONNECT_MAX_ATTEMPTS {
        if !state.sessions.should_reconnect(&peer_id, session_id).await {
            return;
        }
        if failures > 0 {
            tokio::time::sleep(backoff).await;
            backoff = std::cmp::min(backoff.saturating_mul(2), RECONNECT_MAX_BACKOFF);
            if !state.sessions.should_reconnect(&peer_id, session_id).await {
                return;
            }
        }
        emit_peer_state(
            &state.event_tx,
            &peer_id,
            PeerConnectionState::Connecting,
            RouteType::Unspecified,
            None,
        );
        match connect_peer(Arc::clone(&state), peer_id.clone()).await {
            Ok(()) if state.sessions.is_connected(&peer_id).await => return,
            Ok(()) => {
                // Another caller may already own the in-flight attempt. Avoid
                // spinning while that attempt is allowed to finish.
                tokio::time::sleep(RECONNECT_INITIAL_BACKOFF).await;
            }
            Err(error) => {
                failures += 1;
                last_error = Some(error);
            }
        }
    }
    if !state.sessions.should_reconnect(&peer_id, session_id).await {
        return;
    }
    emit_peer_state(
        &state.event_tx,
        &peer_id,
        PeerConnectionState::Failed,
        RouteType::Unspecified,
        Some(last_error.unwrap_or_else(|| {
            protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                "automatic reconnect attempts exhausted",
                "reconnect",
                &peer_id,
            )
        })),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn relay_wins_when_direct_is_still_connecting() {
        let route = race_first_ready(
            async {
                tokio::time::sleep(Duration::from_millis(50)).await;
                Ok::<(), ProtocolError>(())
            },
            async {
                tokio::time::sleep(Duration::from_millis(5)).await;
                Ok::<(), ProtocolError>(())
            },
        )
        .await
        .expect("route should become ready");

        assert!(matches!(route, ReadyRoute::Relay));
    }

    #[tokio::test]
    async fn direct_wins_when_relay_is_still_starting() {
        let route = race_first_ready(
            async {
                tokio::time::sleep(Duration::from_millis(5)).await;
                Ok::<(), ProtocolError>(())
            },
            async {
                tokio::time::sleep(Duration::from_millis(50)).await;
                Ok::<(), ProtocolError>(())
            },
        )
        .await
        .expect("route should become ready");

        assert!(matches!(route, ReadyRoute::Direct(())));
    }

    #[tokio::test]
    async fn a_failed_route_does_not_prevent_the_other_route() {
        let route = race_first_ready(
            async {
                Err::<(), ProtocolError>(protocol_error(
                    NetworkErrorCode::QuicError,
                    "direct failed",
                ))
            },
            async { Ok::<(), ProtocolError>(()) },
        )
        .await
        .expect("relay should remain eligible");

        assert!(matches!(route, ReadyRoute::Relay));
    }
}
