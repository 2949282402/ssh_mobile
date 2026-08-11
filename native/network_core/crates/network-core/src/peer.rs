//! v1 对端注册表、路由选择与异步连接任务。

use network_identity::DeviceIdentity;
use network_nat::{
    Candidate, CandidateKind, CandidateSignal, PathManager, MAX_CANDIDATES_PER_SIGNAL,
};
use network_protocol::{
    NetworkError as ProtocolError, NetworkErrorCode, PeerConnectionState, RouteType,
    UpsertPeerCommand,
};
use network_quic::{read_channel_frame, ChannelFrameKind, QuicEndpointManager, QuicPeerSession};
use network_relay::RelayClient;
use quinn::{Connection, Endpoint, VarInt};
use std::future::Future;
use std::net::SocketAddr;
use std::sync::{atomic::Ordering, Arc};
use std::time::Duration;
use tokio::sync::oneshot;
use tokio::task::JoinSet;
use tokio::time::timeout;

use crate::events::{
    emit_peer_state, emit_route_changed, protocol_error, protocol_error_with_peer,
};
use crate::runtime::{
    PeerConfig, RuntimeState, PEER_CONNECT_TIMEOUT, RECONNECT_INITIAL_BACKOFF,
    RECONNECT_MAX_ATTEMPTS, RECONNECT_MAX_BACKOFF, RELAY_RACE_DELAY,
};
use crate::session::{ConnectDecision, SessionId};

const STUN_SERVER_ENV: &str = "SSH_MOBILE_STUN_SERVER";
const STUN_PROBE_TIMEOUT: Duration = Duration::from_millis(750);
const PATH_METRICS_INTERVAL: Duration = Duration::from_secs(2);
const CANDIDATE_SIGNAL_WAIT: Duration = Duration::from_millis(300);
const DIRECT_UPGRADE_PROBE_INTERVAL: Duration = Duration::from_secs(2);
const DIRECT_UPGRADE_STABLE_DURATION: Duration = Duration::from_millis(750);

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
    let path_manager = Arc::new(PathManager::new());
    let (socket, bound_address) = bind_and_gather_candidates(listen_address, &path_manager)
        .await
        .map_err(|error| protocol_error(NetworkErrorCode::QuicError, error.to_string()))?;
    path_manager
        .set_generation(rand::random::<u64>().max(1))
        .await;
    let manager = QuicEndpointManager::from_bound_socket(socket, Arc::clone(&path_manager))
        .map_err(|error| protocol_error(NetworkErrorCode::QuicError, error.to_string()))?;
    let endpoint = manager.endpoint;
    state
        .bound_port
        .store(bound_address.port(), Ordering::Release);
    *state.identity.write().await = Some(identity);
    *state.receive_directory.write().await = Some(receive_directory);
    *state.local_path_manager.write().await = Some(path_manager);
    *state.endpoint.write().await = Some(endpoint.clone());
    tracing::info!(%bound_address, "native UDP socket is shared by candidate discovery and QUIC");
    let mut accept_task = state
        .accept_task
        .lock()
        .map_err(|_| protocol_error(NetworkErrorCode::QuicError, "accept task lock poisoned"))?;
    *accept_task = Some(tokio::spawn(accept_connections(
        endpoint,
        Arc::clone(&state),
    )));
    Ok(())
}

/// Binds exactly one native UDP socket, gathers candidates, and returns that
/// same socket for Quinn to own. Optional STUN discovery is native-only and is
/// enabled with `SSH_MOBILE_STUN_SERVER=host:port`; no client protocol field is
/// needed for deployments that do not configure a STUN server.
async fn bind_and_gather_candidates(
    listen_address: SocketAddr,
    path_manager: &PathManager,
) -> Result<(std::net::UdpSocket, SocketAddr), Box<dyn std::error::Error + Send + Sync>> {
    let socket = std::net::UdpSocket::bind(listen_address)?;
    socket.set_nonblocking(true)?;
    let bound_address = socket.local_addr()?;
    let socket = tokio::net::UdpSocket::from_std(socket)?;

    path_manager
        .add_candidates(network_nat::discover_candidates(bound_address.port()).await)
        .await;
    if let Some(stun_server) = configured_stun_server() {
        if let Some(candidate) = timeout(
            STUN_PROBE_TIMEOUT,
            network_nat::query_stun(&socket, stun_server),
        )
        .await
        .ok()
        .flatten()
        {
            path_manager.add_candidates(vec![candidate]).await;
        }
    }

    Ok((socket.into_std()?, bound_address))
}

fn configured_stun_server() -> Option<SocketAddr> {
    std::env::var(STUN_SERVER_ENV)
        .ok()
        .and_then(|value| value.parse().ok())
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
    state.direct_upgrade_tasks.write().await.remove(&peer_id);
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
    let relay = state.relay.read().await.clone();
    let relay = match relay {
        Some(relay) if relay.is_usable().await => Some(relay),
        _ => None,
    };

    if let Some(relay) = relay.as_ref() {
        let candidate_update = state.candidate_signal_notify.notified();
        if send_candidate_offer(&state, relay, &peer_id).await.is_ok() {
            let _ = timeout(CANDIDATE_SIGNAL_WAIT, candidate_update).await;
        }
    }
    let mut direct_candidates = match state.path_managers.read().await.get(&peer_id).cloned() {
        Some(manager) => manager.ranked_candidates().await,
        None => peer
            .endpoint
            .map(|endpoint| {
                Candidate::new(
                    endpoint,
                    candidate_kind_for(endpoint),
                    "peer-advertised".into(),
                )
            })
            .into_iter()
            .collect(),
    };
    if let Some(endpoint) = peer.endpoint {
        if !direct_candidates
            .iter()
            .any(|candidate| candidate.endpoint == endpoint)
        {
            direct_candidates.push(Candidate::new(
                endpoint,
                candidate_kind_for(endpoint),
                "peer-configured".into(),
            ));
        }
    }

    let route = match (!direct_candidates.is_empty(), relay) {
        (true, Some(relay)) => {
            let direct = connect_direct_candidates(
                endpoint,
                direct_candidates,
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
        (true, None) => connect_direct_candidates(
            endpoint,
            direct_candidates,
            identity,
            peer.identity_public_key,
            peer_id.clone(),
        )
        .await
        .map(ReadyRoute::Direct),
        (false, Some(relay)) => {
            connect_relay(Arc::clone(&state), relay, peer_id.clone(), Duration::ZERO)
                .await
                .map(|_| ReadyRoute::Relay)
        }
        (false, None) => Err(protocol_error_with_peer(
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
            spawn_path_metrics_monitor(
                Arc::clone(&state),
                peer_id.clone(),
                session_id,
                connection.clone(),
            );
            crate::channel::recover_session(Arc::clone(&state), peer_id.clone(), session_id).await;
            crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.clone()).await;
            tokio::spawn(receive_file_streams(
                peer_id.clone(),
                connection.clone(),
                Arc::clone(&state),
            ));
            tokio::spawn(receive_channel_streams(peer_id, connection, state));
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
            crate::channel::recover_session(Arc::clone(&state), peer_id.clone(), session_id).await;
            crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.clone()).await;
            schedule_direct_upgrade(Arc::clone(&state), peer_id, session_id);
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

/// Runs authenticated QUIC attempts for all currently advertised candidates.
/// A candidate is not considered ready until the identity-bound handshake has
/// succeeded; unreachable or unauthenticated candidates cannot block the
/// remaining candidates from winning.
async fn connect_direct_candidates(
    endpoint: Endpoint,
    candidates: Vec<Candidate>,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
) -> Result<Connection, ProtocolError> {
    let mut attempts = JoinSet::new();
    for candidate in candidates.into_iter().take(MAX_CANDIDATES_PER_SIGNAL) {
        let endpoint = endpoint.clone();
        let identity = Arc::clone(&identity);
        let peer_id = peer_id.clone();
        attempts.spawn(async move {
            connect_direct(
                endpoint,
                candidate.endpoint,
                identity,
                expected_peer_public_key,
                peer_id,
            )
            .await
        });
    }
    let mut last_error = None;
    while let Some(result) = attempts.join_next().await {
        match result {
            Ok(Ok(connection)) => {
                attempts.abort_all();
                return Ok(connection);
            }
            Ok(Err(error)) => last_error = Some(error),
            Err(error) => {
                last_error = Some(protocol_error_with_peer(
                    NetworkErrorCode::QuicError,
                    format!("candidate connectivity task failed: {error}"),
                    "connect",
                    &peer_id,
                ));
            }
        }
    }
    Err(last_error.unwrap_or_else(|| {
        protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "candidate set is empty",
            "connect",
            &peer_id,
        )
    }))
}

/// Keeps a Relay-backed Session usable while probing the advertised direct
/// candidates. The task owns no business state and exits when the Session is
/// closed, replaced, or already promoted by another route.
fn schedule_direct_upgrade(state: Arc<RuntimeState>, peer_id: String, session_id: SessionId) {
    tokio::spawn(async move {
        {
            let mut tasks = state.direct_upgrade_tasks.write().await;
            if tasks
                .get(&peer_id)
                .is_some_and(|current| *current == session_id)
            {
                return;
            }
            tasks.insert(peer_id.clone(), session_id);
        }

        direct_upgrade_loop(Arc::clone(&state), peer_id.clone(), session_id).await;

        let mut tasks = state.direct_upgrade_tasks.write().await;
        if tasks
            .get(&peer_id)
            .is_some_and(|current| *current == session_id)
        {
            tasks.remove(&peer_id);
        }
    });
}

async fn direct_upgrade_loop(state: Arc<RuntimeState>, peer_id: String, session_id: SessionId) {
    loop {
        if state.sessions.current_session_id(&peer_id).await != Some(session_id)
            || state.sessions.current_route(&peer_id).await != Some(RouteType::Relay)
        {
            return;
        }

        let endpoint = state.endpoint.read().await.clone();
        let identity = state.identity.read().await.clone();
        let peer = state.peers.read().await.get(&peer_id).cloned();
        let manager = state.path_managers.read().await.get(&peer_id).cloned();
        let Some(endpoint) = endpoint else {
            return;
        };
        let Some(identity) = identity else {
            return;
        };
        let Some(peer) = peer else {
            return;
        };
        let mut candidates = match manager.as_ref() {
            Some(manager) => manager.ranked_candidates().await,
            None => peer
                .endpoint
                .map(|endpoint| {
                    Candidate::new(
                        endpoint,
                        candidate_kind_for(endpoint),
                        "peer-advertised".into(),
                    )
                })
                .into_iter()
                .collect(),
        };
        if let Some(endpoint) = peer.endpoint {
            if !candidates
                .iter()
                .any(|candidate| candidate.endpoint == endpoint)
            {
                candidates.push(Candidate::new(
                    endpoint,
                    candidate_kind_for(endpoint),
                    "peer-configured".into(),
                ));
            }
        }

        if !candidates.is_empty() {
            match connect_direct_candidates(
                endpoint,
                candidates,
                identity,
                peer.identity_public_key,
                peer_id.clone(),
            )
            .await
            {
                Ok(connection) => {
                    // Require a short stable window before replacing Relay;
                    // a transient UDP success must not cause route flapping.
                    tokio::time::sleep(DIRECT_UPGRADE_STABLE_DURATION).await;
                    if state.sessions.current_session_id(&peer_id).await != Some(session_id)
                        || state.sessions.current_route(&peer_id).await != Some(RouteType::Relay)
                    {
                        connection.close(VarInt::from_u32(0), b"upgrade superseded");
                        return;
                    }
                    let remote_endpoint = connection.remote_address();
                    let stats = connection.stats();
                    if !state
                        .sessions
                        .replace_route_if_current(
                            &peer_id,
                            session_id,
                            RouteType::Relay,
                            connection.clone(),
                            RouteType::QuicDirect,
                        )
                        .await
                    {
                        return;
                    }
                    if let Some(manager) = manager {
                        manager
                            .record_quic_sample(
                                remote_endpoint,
                                connection.rtt(),
                                stats.path.sent_packets,
                                stats.path.lost_packets,
                            )
                            .await;
                        let _ = manager.activate_path(remote_endpoint).await;
                        let candidate = manager.get_candidate(remote_endpoint).await;
                        emit_route_changed(
                            &state.event_tx,
                            &peer_id,
                            RouteType::QuicDirect,
                            remote_endpoint,
                            candidate.as_ref().map_or(0, |candidate| candidate.rtt_ms),
                            candidate
                                .as_ref()
                                .map_or(0.0, |candidate| candidate.loss_rate),
                        );
                    } else {
                        emit_route_changed(
                            &state.event_tx,
                            &peer_id,
                            RouteType::QuicDirect,
                            remote_endpoint,
                            connection.rtt().as_millis().min(u32::MAX as u128) as u32,
                            0.0,
                        );
                    }
                    spawn_path_metrics_monitor(
                        Arc::clone(&state),
                        peer_id.clone(),
                        session_id,
                        connection.clone(),
                    );
                    crate::channel::recover_session(
                        Arc::clone(&state),
                        peer_id.clone(),
                        session_id,
                    )
                    .await;
                    crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.clone())
                        .await;
                    tokio::spawn(receive_file_streams(
                        peer_id.clone(),
                        connection.clone(),
                        Arc::clone(&state),
                    ));
                    tokio::spawn(receive_channel_streams(peer_id, connection, state));
                    return;
                }
                Err(error) => {
                    tracing::debug!(peer_id = %peer_id, error = %error.message, "background direct probe failed; Relay remains active");
                }
            }
        }
        tokio::time::sleep(DIRECT_UPGRADE_PROBE_INTERVAL).await;
    }
}

async fn send_candidate_offer(
    state: &RuntimeState,
    relay: &RelayClient,
    peer_id: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let local_manager = state
        .local_path_manager
        .read()
        .await
        .clone()
        .ok_or_else(|| std::io::Error::other("local candidate manager is unavailable"))?;
    let generation = local_manager.generation().await.max(1);
    let candidates = local_manager.ranked_candidates().await;
    let signal = CandidateSignal::offer(
        generation,
        candidates.iter().map(Candidate::advertisement).collect(),
    );
    let payload = serde_json::to_vec(&signal)?;
    let token = hex::encode(rand::random::<[u8; 16]>());
    relay
        .send_candidate_offer(&token, peer_id, &payload)
        .await?;
    Ok(())
}

/// Starts native-only path quality sampling for one authenticated direct
/// Connection. The task exits as soon as SessionManager observes a different
/// current Connection.
fn spawn_path_metrics_monitor(
    state: Arc<RuntimeState>,
    peer_id: String,
    session_id: SessionId,
    connection: Connection,
) {
    tokio::spawn(async move {
        monitor_direct_path(state, peer_id, session_id, connection).await;
    });
}

async fn monitor_direct_path(
    state: Arc<RuntimeState>,
    peer_id: String,
    session_id: SessionId,
    connection: Connection,
) {
    let manager = state.path_managers.read().await.get(&peer_id).cloned();
    let Some(manager) = manager else {
        return;
    };

    loop {
        let current = state.sessions.current_connection(&peer_id).await;
        if current
            .as_ref()
            .is_none_or(|current| current.stable_id() != connection.stable_id())
        {
            return;
        }

        let endpoint = connection.remote_address();
        let stats = connection.stats();
        manager
            .record_quic_sample(
                endpoint,
                connection.rtt(),
                stats.path.sent_packets,
                stats.path.lost_packets,
            )
            .await;
        if manager
            .get_active_path()
            .await
            .is_none_or(|active| active.endpoint != endpoint)
        {
            let _ = manager.activate_path(endpoint).await;
        }
        if let Some(candidate) = manager.get_candidate(endpoint).await {
            emit_route_changed(
                &state.event_tx,
                &peer_id,
                RouteType::QuicDirect,
                candidate.endpoint,
                candidate.rtt_ms,
                candidate.loss_rate,
            );
        }

        if let Some(candidate) = manager.better_path_than_active().await {
            if migrate_direct_path(
                Arc::clone(&state),
                peer_id.clone(),
                session_id,
                connection.clone(),
                candidate,
            )
            .await
            {
                return;
            }
        }
        tokio::time::sleep(PATH_METRICS_INTERVAL).await;
    }
}

/// Establishes and authenticates a better candidate before atomically
/// replacing the Session connection. Existing streams stay owned by the old
/// connection until the replacement is ready.
async fn migrate_direct_path(
    state: Arc<RuntimeState>,
    peer_id: String,
    session_id: SessionId,
    current_connection: Connection,
    candidate: Candidate,
) -> bool {
    if candidate.endpoint == current_connection.remote_address() {
        return false;
    }
    let endpoint = match state.endpoint.read().await.clone() {
        Some(endpoint) => endpoint,
        None => return false,
    };
    let identity = match state.identity.read().await.clone() {
        Some(identity) => identity,
        None => return false,
    };
    let peer = match state.peers.read().await.get(&peer_id).cloned() {
        Some(peer) => peer,
        None => return false,
    };
    let replacement = match connect_direct(
        endpoint,
        candidate.endpoint,
        identity,
        peer.identity_public_key,
        peer_id.clone(),
    )
    .await
    {
        Ok(connection) => connection,
        Err(error) => {
            tracing::debug!(
                peer_id = %peer_id,
                endpoint = %candidate.endpoint,
                error = %error.message,
                "better direct path failed authentication"
            );
            return false;
        }
    };
    let Some(previous) = state
        .sessions
        .replace_connection_if_current(
            &peer_id,
            session_id,
            &current_connection,
            replacement.clone(),
            RouteType::QuicDirect,
        )
        .await
    else {
        return false;
    };
    previous.close(VarInt::from_u32(0), b"route migrated");
    if let Some(manager) = state.path_managers.read().await.get(&peer_id).cloned() {
        let _ = manager.activate_path(candidate.endpoint).await;
    }
    emit_route_changed(
        &state.event_tx,
        &peer_id,
        RouteType::QuicDirect,
        candidate.endpoint,
        candidate.rtt_ms,
        candidate.loss_rate,
    );
    spawn_path_metrics_monitor(
        Arc::clone(&state),
        peer_id.clone(),
        session_id,
        replacement.clone(),
    );
    crate::channel::recover_session(Arc::clone(&state), peer_id.clone(), session_id).await;
    crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.clone()).await;
    tokio::spawn(receive_file_streams(
        peer_id.clone(),
        replacement.clone(),
        Arc::clone(&state),
    ));
    tokio::spawn(receive_channel_streams(peer_id, replacement, state));
    true
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
                if let Some(session_id) = state.sessions.current_session_id(&peer_id).await {
                    spawn_path_metrics_monitor(
                        Arc::clone(&state),
                        peer_id.clone(),
                        session_id,
                        connection.clone(),
                    );
                    crate::channel::recover_session(
                        Arc::clone(&state),
                        peer_id.clone(),
                        session_id,
                    )
                    .await;
                }
                crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.clone())
                    .await;
                tokio::spawn(receive_channel_streams(
                    peer_id.clone(),
                    connection.clone(),
                    Arc::clone(&state),
                ));
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
                handle_connection_disconnect(&state, &peer_id, &connection).await;
                return;
            }
        }
    }
}

/// 接收一条 QUIC 单向 Delivery stream；stream 关闭只影响当前 Connection，
/// 逻辑消息仍由 DeliveryManager 在下一条 Connection 上恢复。
pub(crate) async fn receive_channel_streams(
    peer_id: String,
    connection: Connection,
    state: Arc<RuntimeState>,
) {
    loop {
        match connection.accept_uni().await {
            Ok(mut receive) => {
                let state = Arc::clone(&state);
                let peer_id = peer_id.clone();
                tokio::spawn(async move {
                    match read_channel_frame(&mut receive).await {
                        Ok((ChannelFrameKind::DataMessage, payload)) => {
                            if let Err(error) =
                                crate::channel::handle_data_message(&state, &peer_id, &payload)
                                    .await
                            {
                                tracing::debug!(peer_id = %peer_id, error = %error, "rejected QUIC DataMessage");
                            }
                        }
                        Ok((ChannelFrameKind::DeliveryAck, payload)) => {
                            if let Err(error) =
                                crate::channel::handle_delivery_ack(&state, &peer_id, &payload)
                                    .await
                            {
                                tracing::debug!(peer_id = %peer_id, error = %error, "rejected QUIC DeliveryAck");
                            }
                        }
                        Err(error) => {
                            tracing::debug!(peer_id = %peer_id, error = %error, "QUIC channel stream failed");
                        }
                    }
                });
            }
            Err(_) => {
                handle_connection_disconnect(&state, &peer_id, &connection).await;
                return;
            }
        }
    }
}

async fn handle_connection_disconnect(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    connection: &Connection,
) {
    let disconnected_session = state
        .sessions
        .mark_disconnected_if_current(peer_id, connection)
        .await;
    if let Some(session_id) = disconnected_session {
        emit_peer_state(
            &state.event_tx,
            peer_id,
            PeerConnectionState::Disconnected,
            RouteType::Unspecified,
            None,
        );
        schedule_reconnect(Arc::clone(state), peer_id.to_string(), session_id);
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

    #[tokio::test]
    async fn failed_authenticated_direct_probe_keeps_relay_eligible() {
        let route = race_first_ready(
            async {
                Err::<(), ProtocolError>(protocol_error(
                    NetworkErrorCode::AuthenticationFailed,
                    "candidate identity rejected",
                ))
            },
            async { Ok::<(), ProtocolError>(()) },
        )
        .await
        .expect("Relay must remain available after direct auth failure");

        assert!(matches!(route, ReadyRoute::Relay));
    }
}
