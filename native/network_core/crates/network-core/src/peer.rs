//! v1 对端注册表、路由选择与异步连接任务。

// v1 PathManager remote_* 桥接方法在 Step 11 前仍被 v1 代码使用（§38 Step 5 已将它们
// 标记 deprecated）；保持 v1 行为不变，仅抑制 lint，additive-first。
#![allow(deprecated)]

use network_identity::DeviceIdentity;
use network_nat::{Candidate, CandidateKind, PathManager, MAX_CANDIDATES_PER_SIGNAL};
use network_protocol::{
    NetworkError as ProtocolError, NetworkErrorCode, PeerConnectionState, RouteType,
    UpsertPeerCommand,
};
use network_quic::{read_channel_frame, ChannelFrameKind, QuicEndpointManager, QuicPeerSession};
use network_relay::RelayClient;
use network_transport::{TcpTransport, Transport, WebSocketTransport};
use quinn::{Connection, Endpoint};
use std::future::Future;
use std::net::SocketAddr;
use std::sync::{atomic::Ordering, Arc};
use std::time::{Duration, Instant};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinSet;
use tokio::time::timeout;

use crate::connection::{
    prepare_generic_route, GenericConnection, GenericFrameKind, GenericInboundFrame,
    GenericRouteHandle, GenericRouteRuntime, RouteTopology, RouteTransport,
};
use crate::crypto_handshake::SessionCryptoMaterial;
use crate::events::{
    emit_peer_state, emit_peer_state_profile, emit_route_changed, protocol_error,
    protocol_error_with_peer,
};
use crate::generic_auth::{authenticate_initiator, authenticate_responder};
use crate::runtime::{
    PeerConfig, RuntimeState, SessionAdmissionLease, MAX_PENDING_RELAY_CRYPTO_HANDSHAKES,
    PEER_CONNECT_TIMEOUT,
};
use crate::session::{ActiveRoute, GenericRouteScope, SessionId};

const STUN_SERVERS_ENV: &str = "SSH_MOBILE_STUN_SERVERS";
const STUN_PROBE_TIMEOUT: Duration = Duration::from_millis(750);
const GENERIC_ROUTE_CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const GENERIC_ROUTE_TASK_START_TIMEOUT: Duration = Duration::from_secs(1);

pub(crate) struct AuthenticatedGenericRoute {
    pub(crate) scope: GenericRouteScope,
    pub(crate) endpoint: SocketAddr,
    pub(crate) crypto: SessionCryptoMaterial,
    pub(crate) admission: SessionAdmissionLease,
}

pub(crate) enum ConnectedRoute {
    Quic {
        connection: Connection,
        crypto: SessionCryptoMaterial,
        admission: SessionAdmissionLease,
    },
    Generic(AuthenticatedGenericRoute),
}

pub(crate) struct DirectRouteAttempt {
    pub(crate) state: Arc<RuntimeState>,
    pub(crate) endpoint: Endpoint,
    pub(crate) candidates: Vec<Candidate>,
    pub(crate) identity: Arc<DeviceIdentity>,
    pub(crate) expected_peer_public_key: [u8; 32],
    pub(crate) peer_id: String,
    pub(crate) session_binding: String,
    pub(crate) session_id: SessionId,
    pub(crate) attempt_id: String,
    pub(crate) connect_window: Duration,
}

/// Installs the fresh Noise root for a Session admission（§18 1:1）. The root is
/// always new per connection; there is no ContinueExisting path. Responder
/// handshakes use this after selecting the final local binding before sending
/// the RootSeed.
pub(crate) async fn install_admitted_crypto(
    state: &RuntimeState,
    peer_id: &str,
    admission: &SessionAdmissionLease,
    crypto: &SessionCryptoMaterial,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if state
        .install_crypto_material(peer_id, &admission.session_id.wire_key(), crypto)
        .is_err()
    {
        state
            .sessions
            .mark_failed(peer_id, admission.session_id)
            .await;
        return Err(std::io::Error::other("application E2EE install failed").into());
    }
    Ok(())
}

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
        .set_generation(monotonic_candidate_generation())
        .await;
    let manager = QuicEndpointManager::from_bound_socket(socket, Arc::clone(&path_manager))
        .map_err(|error| protocol_error(NetworkErrorCode::QuicError, error.to_string()))?;
    let endpoint = manager.endpoint;
    let tcp_socket = std::net::TcpListener::bind(bound_address).map_err(|error| {
        protocol_error(
            NetworkErrorCode::IoError,
            format!("failed to bind TCP fallback listener: {error}"),
        )
    })?;
    tcp_socket
        .set_nonblocking(true)
        .map_err(|error| protocol_error(NetworkErrorCode::IoError, error.to_string()))?;
    let tcp_listener = TcpListener::from_std(tcp_socket).map_err(|error| {
        protocol_error(
            NetworkErrorCode::IoError,
            format!("failed to configure TCP fallback listener: {error}"),
        )
    })?;
    state
        .bound_port
        .store(bound_address.port(), Ordering::Release);
    *state.identity.write().await = Some(identity);
    *state.receive_directory.write().await = Some(receive_directory);
    *state.local_path_manager.write().await = Some(path_manager);
    *state.endpoint.write().await = Some(endpoint.clone());
    tracing::info!(%bound_address, "native UDP socket is shared by candidate discovery and QUIC");
    let task_id = state
        .task_supervisor
        .spawn_runtime(
            "quic-accept",
            accept_connections(endpoint, Arc::clone(&state)),
        )
        .ok_or_else(|| {
            protocol_error(NetworkErrorCode::Cancelled, "network runtime is stopping")
        })?;
    {
        // 作用域限定 MutexGuard 生命周期，避免跨 await 持有非 Send 的 guard。
        let mut accept_task = state.accept_task.lock().map_err(|_| {
            protocol_error(NetworkErrorCode::QuicError, "accept task lock poisoned")
        })?;
        *accept_task = Some(task_id);
    }
    let tcp_task_id = state
        .task_supervisor
        .spawn_runtime(
            "tcp-accept",
            accept_tcp_connections(tcp_listener, Arc::clone(&state)),
        )
        .ok_or_else(|| {
            protocol_error(NetworkErrorCode::Cancelled, "network runtime is stopping")
        })?;
    {
        let mut tcp_accept_task = state.tcp_accept_task.lock().map_err(|_| {
            protocol_error(NetworkErrorCode::IoError, "TCP accept task lock poisoned")
        })?;
        *tcp_accept_task = Some(tcp_task_id);
    }
    // transport-network v2：运行时配置完成（identity + 本地候选已就绪）后初始化本地
    // Discovery 生命周期（新 runtime_epoch + revision=1）。additive-first：不触碰 v1
    // upload_discovery / peer_presence。
    crate::discovery::begin_epoch(&state).await;
    Ok(())
}

/// Binds exactly one native UDP socket, gathers candidates, and returns that
/// same socket for Quinn to own. Optional STUN discovery is native-only and is
/// enabled with `SSH_MOBILE_STUN_SERVERS=host:port,host:port`; no client
/// protocol field is needed for deployments that do not configure STUN.
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
    for stun_server in configured_stun_servers() {
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

fn configured_stun_servers() -> Vec<SocketAddr> {
    std::env::var(STUN_SERVERS_ENV)
        .ok()
        .map(|value| {
            value
                .split(',')
                .filter_map(|entry| {
                    let entry = entry.trim();
                    if entry.is_empty() {
                        None
                    } else {
                        match entry.parse() {
                            Ok(server) => Some(server),
                            Err(error) => {
                                tracing::debug!(%entry, %error, "ignoring invalid STUN server");
                                None
                            }
                        }
                    }
                })
                .take(8)
                .collect()
        })
        .unwrap_or_default()
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
    // transport-network v2：upsert 只保存配置 endpoint 与可信密钥；对端候选不再存
    // 全局 path_manager（§12/§29）。每次 connect 前由 ConnectionOrchestrator 经 Resolve
    // 获取权威 Discovery，本地配置 endpoint 作为 Direct 候选追加。
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
    let session_id = state.sessions.current_session_id(&peer_id).await;
    if let Some(route) = state.sessions.close(&peer_id).await {
        route.close().await;
    }
    if let Some(session_id) = session_id {
        state.cancel_session_tasks(&peer_id, session_id).await;
        // Explicit Peer disconnect releases receive-side active handlers and
        // ordered buffers. A transient Connection loss takes a different path
        // (Session destroyed) and must keep them for Delivery recovery（§20）——
        // 因此清理只发生在用户显式断开时，transport 丢失不清理。
        state.delivery.close_peer(&peer_id).await;
    }
    // transport-network v2：断开时注销连接登记（§34）。
    state.connection_registry.unregister(&peer_id);
    emit_peer_state(
        &state.event_tx,
        &peer_id,
        PeerConnectionState::Disconnected,
        RouteType::Unspecified,
        None,
    );
    Ok(())
}

/// Direct QUIC 尝试的总预算为 8 秒，避免连接和认证各自再等待一次。
pub(crate) async fn connect_direct(
    endpoint: Endpoint,
    peer_endpoint: SocketAddr,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
    attempt_id: String,
    connect_window: Duration,
) -> Result<Connection, ProtocolError> {
    let timeout_peer_id = peer_id.clone();
    tracing::debug!(
        peer_id = %peer_id,
        attempt_id = %attempt_id,
        ?connect_window,
        remote = %peer_endpoint,
        "starting authenticated QUIC candidate attempt"
    );
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
    tokio::time::timeout(connect_window.min(PEER_CONNECT_TIMEOUT), attempt)
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

#[allow(clippy::too_many_arguments)]
pub(crate) async fn connect_direct_with_crypto(
    endpoint: Endpoint,
    peer_endpoint: SocketAddr,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
    attempt_id: String,
    connect_window: Duration,
    session_binding: &str,
    state: Arc<RuntimeState>,
    expected_session_id: SessionId,
) -> Result<(Connection, SessionCryptoMaterial, SessionAdmissionLease), ProtocolError> {
    let started = Instant::now();
    let connection = connect_direct(
        endpoint,
        peer_endpoint,
        Arc::clone(&identity),
        expected_peer_public_key,
        peer_id.clone(),
        attempt_id,
        connect_window,
    )
    .await?;
    let remaining = connect_window
        .min(PEER_CONNECT_TIMEOUT)
        .saturating_sub(started.elapsed());
    let expected_peer_id_for_resolver = peer_id.clone();
    let (crypto, admission) = tokio::time::timeout(
        remaining,
        crate::crypto_handshake::initiate_quic(
            &connection,
            identity,
            &peer_id,
            expected_peer_public_key,
            session_binding,
            move |authenticated_peer_id, remote_session_binding| {
                let state = Arc::clone(&state);
                let authenticated_peer_id = authenticated_peer_id.to_string();
                let remote_session_binding = remote_session_binding.to_string();
                async move {
                    if authenticated_peer_id != expected_peer_id_for_resolver {
                        return Err(crate::crypto_handshake::CryptoHandshakeError::Failed);
                    }
                    let admission = state
                        .admit_authenticated_session(
                            &authenticated_peer_id,
                            Some(expected_session_id),
                            &remote_session_binding,
                        )
                        .await
                        .map_err(|_| crate::crypto_handshake::CryptoHandshakeError::Failed)?;
                    Ok((admission.session_id.wire_key(), admission))
                }
            },
        ),
    )
    .await
    .map_err(|_| {
        protocol_error_with_peer(
            NetworkErrorCode::Timeout,
            "application E2EE handshake timed out",
            "connect",
            &peer_id,
        )
    })?
    .map_err(|_| {
        protocol_error_with_peer(
            NetworkErrorCode::AuthenticationFailed,
            "application E2EE handshake failed",
            "connect",
            &peer_id,
        )
    })?;
    Ok((connection, crypto, admission))
}

#[allow(clippy::too_many_arguments)]
async fn connect_direct_candidates_with_crypto(
    endpoint: Endpoint,
    candidates: Vec<Candidate>,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
    attempt_id: String,
    connect_window: Duration,
    session_binding: String,
    state: Arc<RuntimeState>,
    expected_session_id: SessionId,
) -> Result<(Connection, SessionCryptoMaterial, SessionAdmissionLease), ProtocolError> {
    let mut attempts = JoinSet::new();
    for candidate in candidates.into_iter().take(MAX_CANDIDATES_PER_SIGNAL) {
        let endpoint = endpoint.clone();
        let identity = Arc::clone(&identity);
        let peer_id = peer_id.clone();
        let session_binding = session_binding.clone();
        let attempt_id = attempt_id.clone();
        let state = Arc::clone(&state);
        attempts.spawn(async move {
            connect_direct_with_crypto(
                endpoint,
                candidate.endpoint,
                identity,
                expected_peer_public_key,
                peer_id,
                attempt_id,
                connect_window,
                &session_binding,
                state,
                expected_session_id,
            )
            .await
        });
    }
    let mut last_error = None;
    while let Some(result) = attempts.join_next().await {
        match result {
            Ok(Ok(route)) => {
                attempts.abort_all();
                return Ok(route);
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

/// Route selection keeps QUIC as the first direct candidate, then falls back
/// to authenticated TCP and finally a binary WebSocket route. Each generic
/// route is admitted only after the same identity proof used by QUIC.
pub(crate) async fn connect_direct_or_generic(
    attempt: DirectRouteAttempt,
) -> Result<ConnectedRoute, ProtocolError> {
    let DirectRouteAttempt {
        state,
        endpoint,
        candidates,
        identity,
        expected_peer_public_key,
        peer_id,
        session_binding,
        session_id,
        attempt_id,
        connect_window,
    } = attempt;
    let generic_candidates = candidates.clone();
    match connect_direct_candidates_with_crypto(
        endpoint,
        candidates,
        Arc::clone(&identity),
        expected_peer_public_key,
        peer_id.clone(),
        attempt_id,
        connect_window,
        session_binding.clone(),
        Arc::clone(&state),
        session_id,
    )
    .await
    {
        Ok((connection, crypto, admission)) => Ok(ConnectedRoute::Quic {
            connection,
            crypto,
            admission,
        }),
        Err(quic_error) => connect_generic_candidates(
            generic_candidates,
            identity,
            expected_peer_public_key,
            peer_id,
            session_binding,
            state,
            session_id,
        )
        .await
        .map(ConnectedRoute::Generic)
        .map_err(|_| quic_error),
    }
}

async fn connect_generic_candidates(
    candidates: Vec<Candidate>,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
    session_binding: String,
    state: Arc<RuntimeState>,
    expected_session_id: SessionId,
) -> Result<AuthenticatedGenericRoute, ProtocolError> {
    let mut last_error = None;
    for candidate in candidates.iter().take(MAX_CANDIDATES_PER_SIGNAL) {
        match connect_tcp_route(
            candidate.endpoint,
            Arc::clone(&identity),
            expected_peer_public_key,
            peer_id.clone(),
            session_binding.clone(),
            Arc::clone(&state),
            expected_session_id,
        )
        .await
        {
            Ok(route) => return Ok(route),
            Err(error) => last_error = Some(error),
        }
    }
    for candidate in candidates.iter().take(MAX_CANDIDATES_PER_SIGNAL) {
        match connect_websocket_route(
            candidate.endpoint,
            Arc::clone(&identity),
            expected_peer_public_key,
            peer_id.clone(),
            session_binding.clone(),
            Arc::clone(&state),
            expected_session_id,
        )
        .await
        {
            Ok(route) => return Ok(route),
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error.unwrap_or_else(|| {
        protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "no generic direct candidates are available",
            "connect",
            &peer_id,
        )
    }))
}

/// Register both halves of one GenericRoute with the Session supervisor and
/// wait for their deterministic startup barriers. The returned scope remains
/// staged until SessionManager sends its atomic commit signal.
pub(crate) async fn supervise_generic_route(
    state: Arc<RuntimeState>,
    peer_id: &str,
    session_id: SessionId,
    runtime: GenericRouteRuntime,
) -> Result<GenericRouteScope, ProtocolError> {
    let GenericRouteRuntime {
        handle,
        inbound,
        driver,
        ready,
        commit,
        stop,
        stopping,
    } = runtime;
    let session_key = session_id.wire_key();
    let supervisor = Arc::clone(&state.task_supervisor);
    let mut driver_task = supervisor
        .spawn_session_controlled(session_key.clone(), "generic-route-io", driver)
        .ok_or_else(|| {
            protocol_error_with_peer(
                NetworkErrorCode::Cancelled,
                "generic-route-io could not be registered",
                "generic-route_start",
                peer_id,
            )
        })?;
    if timeout(GENERIC_ROUTE_TASK_START_TIMEOUT, ready)
        .await
        .ok()
        .and_then(Result::ok)
        .is_none()
    {
        driver_task.cancel().await;
        return Err(protocol_error_with_peer(
            NetworkErrorCode::Timeout,
            "generic-route-io did not become ready",
            "generic-route_start",
            peer_id,
        ));
    }

    let (receiver, receiver_ready) = generic_route_receiver_task(
        Arc::clone(&state),
        peer_id.to_string(),
        handle.clone(),
        inbound,
        session_id,
        stop.clone(),
        Arc::clone(&stopping),
    );
    let mut receiver_task = match supervisor.spawn_session_controlled(
        session_key,
        "generic-route-receiver",
        receiver,
    ) {
        Some(task) => task,
        None => {
            driver_task.cancel().await;
            return Err(protocol_error_with_peer(
                NetworkErrorCode::Cancelled,
                "generic-route-receiver could not be registered",
                "generic-route_start",
                peer_id,
            ));
        }
    };
    if timeout(GENERIC_ROUTE_TASK_START_TIMEOUT, receiver_ready)
        .await
        .ok()
        .and_then(Result::ok)
        .is_none()
    {
        receiver_task.cancel().await;
        driver_task.cancel().await;
        return Err(protocol_error_with_peer(
            NetworkErrorCode::Timeout,
            "generic-route-receiver did not become ready",
            "generic-route_start",
            peer_id,
        ));
    }

    Ok(GenericRouteScope::new(
        handle,
        driver_task,
        receiver_task,
        stop,
        stopping,
        commit,
    ))
}

async fn connect_tcp_route(
    endpoint: SocketAddr,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
    session_binding: String,
    state: Arc<RuntimeState>,
    expected_session_id: SessionId,
) -> Result<AuthenticatedGenericRoute, ProtocolError> {
    let timeout_peer_id = peer_id.clone();
    let result = tokio::time::timeout(GENERIC_ROUTE_CONNECT_TIMEOUT, async move {
        let mut connection = GenericConnection::connect_tcp(
            "0.0.0.0:0".parse().expect("wildcard address"),
            endpoint,
        )
        .await
        .map_err(|error| {
            protocol_error_with_peer(
                NetworkErrorCode::IoError,
                format!("TCP route connection failed: {error}"),
                "connect",
                &peer_id,
            )
        })?;
        let resolver_state = Arc::clone(&state);
        let resolver_peer_id = peer_id.clone();
        let (crypto, admission) = authenticate_initiator(
            &mut connection,
            identity,
            &peer_id,
            expected_peer_public_key,
            &session_binding,
            move |authenticated_peer_id, remote_session_binding| {
                let resolver_state = Arc::clone(&resolver_state);
                let resolver_peer_id = resolver_peer_id.clone();
                let remote_session_binding = remote_session_binding.to_string();
                let authenticated_peer_id = authenticated_peer_id.to_string();
                async move {
                    if authenticated_peer_id != resolver_peer_id {
                        return Err(crate::crypto_handshake::CryptoHandshakeError::Failed);
                    }
                    let admission = resolver_state
                        .admit_authenticated_session(
                            &resolver_peer_id,
                            Some(expected_session_id),
                            &remote_session_binding,
                        )
                        .await
                        .map_err(|_| crate::crypto_handshake::CryptoHandshakeError::Failed)?;
                    Ok((admission.session_id.wire_key(), admission))
                }
            },
        )
        .await
        .map_err(|error| {
            protocol_error_with_peer(
                NetworkErrorCode::AuthenticationFailed,
                format!("TCP route authentication failed: {error}"),
                "connect",
                &peer_id,
            )
        })?;
        let transport = connection.route().transport();
        let scope = supervise_generic_route(
            Arc::clone(&state),
            &peer_id,
            admission.session_id,
            prepare_generic_route(connection),
        )
        .await?;
        debug_assert_eq!(transport, RouteTransport::Tcp);
        Ok(AuthenticatedGenericRoute {
            scope,
            endpoint,
            crypto,
            admission,
        })
    })
    .await;
    match result {
        Ok(result) => result,
        Err(_) => Err(protocol_error_with_peer(
            NetworkErrorCode::Timeout,
            "TCP route connection timed out",
            "connect",
            &timeout_peer_id,
        )),
    }
}

async fn connect_websocket_route(
    endpoint: SocketAddr,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
    session_binding: String,
    state: Arc<RuntimeState>,
    expected_session_id: SessionId,
) -> Result<AuthenticatedGenericRoute, ProtocolError> {
    let url = format!("ws://{endpoint}/v1/transport");
    let timeout_peer_id = peer_id.clone();
    let result = tokio::time::timeout(GENERIC_ROUTE_CONNECT_TIMEOUT, async move {
        let mut connection = GenericConnection::connect_websocket(&url)
            .await
            .map_err(|error| {
                protocol_error_with_peer(
                    NetworkErrorCode::IoError,
                    format!("WebSocket route connection failed: {error}"),
                    "connect",
                    &peer_id,
                )
            })?
            .with_topology(RouteTopology::Direct);
        let resolver_state = Arc::clone(&state);
        let resolver_peer_id = peer_id.clone();
        let (crypto, admission) = authenticate_initiator(
            &mut connection,
            identity,
            &peer_id,
            expected_peer_public_key,
            &session_binding,
            move |authenticated_peer_id, remote_session_binding| {
                let resolver_state = Arc::clone(&resolver_state);
                let resolver_peer_id = resolver_peer_id.clone();
                let remote_session_binding = remote_session_binding.to_string();
                let authenticated_peer_id = authenticated_peer_id.to_string();
                async move {
                    if authenticated_peer_id != resolver_peer_id {
                        return Err(crate::crypto_handshake::CryptoHandshakeError::Failed);
                    }
                    let admission = resolver_state
                        .admit_authenticated_session(
                            &resolver_peer_id,
                            Some(expected_session_id),
                            &remote_session_binding,
                        )
                        .await
                        .map_err(|_| crate::crypto_handshake::CryptoHandshakeError::Failed)?;
                    Ok((admission.session_id.wire_key(), admission))
                }
            },
        )
        .await
        .map_err(|error| {
            protocol_error_with_peer(
                NetworkErrorCode::AuthenticationFailed,
                format!("WebSocket route authentication failed: {error}"),
                "connect",
                &peer_id,
            )
        })?;
        let scope = supervise_generic_route(
            Arc::clone(&state),
            &peer_id,
            admission.session_id,
            prepare_generic_route(connection),
        )
        .await?;
        Ok(AuthenticatedGenericRoute {
            scope,
            endpoint,
            crypto,
            admission,
        })
    })
    .await;
    match result {
        Ok(result) => result,
        Err(_) => Err(protocol_error_with_peer(
            NetworkErrorCode::Timeout,
            "WebSocket route connection timed out",
            "connect",
            &timeout_peer_id,
        )),
    }
}

/// 生成单调的本地 Discovery generation 种子：用 unix 毫秒，重启/换代只会得到更大的
/// 值。配合服务端「拒绝 generation 回退」（handleDiscoveryUpdate）不会把重启后的设备
/// 误判为回退而卡离线——旧的随机种子跨进程重启有一半概率更小，会让服务端拒绝上传。
fn monotonic_candidate_generation() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(1)
        .max(1)
}

pub(crate) async fn establish_relay_crypto(
    state: &RuntimeState,
    relay: Arc<RelayClient>,
    peer_id: &str,
    session_id: SessionId,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
) -> Result<(SessionCryptoMaterial, SessionAdmissionLease), ProtocolError> {
    let session_token = session_id.wire_key();
    let (mut handshake, hello) =
        crate::crypto_handshake::RelayInitiatorHandshake::start(identity, &session_token).map_err(
            |_| {
                protocol_error_with_peer(
                    NetworkErrorCode::AuthenticationFailed,
                    "Relay application E2EE handshake could not start",
                    "connect",
                    peer_id,
                )
            },
        )?;
    let key = format!("{peer_id}/{session_token}");
    let (response_tx, mut response_rx) = mpsc::channel(3);
    let mut waiters = state.relay_crypto_waiters.write().await;
    if waiters.len() >= MAX_PENDING_RELAY_CRYPTO_HANDSHAKES && !waiters.contains_key(&key) {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::RelayError,
            "Relay application E2EE handshake queue is full",
            "connect",
            peer_id,
        ));
    }
    waiters.insert(key.clone(), response_tx);
    drop(waiters);
    let hello = crate::crypto_handshake::encode_relay_frame(
        crate::crypto_handshake::RELAY_CRYPTO_HELLO,
        &hello,
    )
    .map_err(|_| {
        protocol_error_with_peer(
            NetworkErrorCode::AuthenticationFailed,
            "Relay application E2EE hello is invalid",
            "connect",
            peer_id,
        )
    })?;
    let result = async {
        relay
            .send_crypto_handshake(&session_token, peer_id, &hello)
            .await
            .map_err(|_| {
                protocol_error_with_peer(
                    NetworkErrorCode::RelayError,
                    "Relay application E2EE hello could not be sent",
                    "connect",
                    peer_id,
                )
            })?;
        let response = receive_relay_crypto_step(
            &mut response_rx,
            crate::crypto_handshake::RELAY_CRYPTO_RESPONSE,
            peer_id,
        )
        .await?;
        let final_message = handshake
            .accept_response(&response, peer_id, expected_peer_public_key)
            .map_err(|_| {
                protocol_error_with_peer(
                    NetworkErrorCode::AuthenticationFailed,
                    "Relay application E2EE identity proof failed",
                    "connect",
                    peer_id,
                )
            })?;
        let final_frame = crate::crypto_handshake::encode_relay_frame(
            crate::crypto_handshake::RELAY_CRYPTO_FINAL,
            &final_message,
        )
        .map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::AuthenticationFailed,
                "Relay application E2EE final message is invalid",
                "connect",
                peer_id,
            )
        })?;
        relay
            .send_crypto_handshake(&session_token, peer_id, &final_frame)
            .await
            .map_err(|_| {
                protocol_error_with_peer(
                    NetworkErrorCode::RelayError,
                    "Relay application E2EE final message could not be sent",
                    "connect",
                    peer_id,
                )
            })?;
        let encrypted_seed = receive_relay_crypto_step(
            &mut response_rx,
            crate::crypto_handshake::RELAY_CRYPTO_ROOT_SEED,
            peer_id,
        )
        .await?;
        let confirmation = handshake.accept_root_seed(&encrypted_seed).map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::AuthenticationFailed,
                "Relay application E2EE RootSeed was rejected",
                "connect",
                peer_id,
            )
        })?;
        let remote_session_binding = confirmation.remote_session_binding().to_string();
        let admission = state
            .admit_authenticated_session(peer_id, Some(session_id), &remote_session_binding)
            .await
            .map_err(|_| {
                protocol_error_with_peer(
                    NetworkErrorCode::AuthenticationFailed,
                    "Relay Session continuity check failed",
                    "connect",
                    peer_id,
                )
            })?;
        let (confirmation, encrypted_confirm) = confirmation
            .confirm(admission.session_id.wire_key())
            .map_err(|_| {
                protocol_error_with_peer(
                    NetworkErrorCode::AuthenticationFailed,
                    "Relay application E2EE root confirmation is invalid",
                    "connect",
                    peer_id,
                )
            })?;
        let confirm_frame = crate::crypto_handshake::encode_relay_frame(
            crate::crypto_handshake::RELAY_CRYPTO_ROOT_CONFIRM,
            &encrypted_confirm,
        )
        .map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::AuthenticationFailed,
                "Relay application E2EE root confirmation is invalid",
                "connect",
                peer_id,
            )
        })?;
        relay
            .send_crypto_handshake(&session_token, peer_id, &confirm_frame)
            .await
            .map_err(|_| {
                protocol_error_with_peer(
                    NetworkErrorCode::RelayError,
                    "Relay application E2EE root confirmation could not be sent",
                    "connect",
                    peer_id,
                )
            })?;
        let encrypted_accept = receive_relay_crypto_step(
            &mut response_rx,
            crate::crypto_handshake::RELAY_CRYPTO_ACCEPT,
            peer_id,
        )
        .await?;
        let material = confirmation.accept(&encrypted_accept).map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::AuthenticationFailed,
                "Relay application E2EE acceptance failed",
                "connect",
                peer_id,
            )
        })?;
        Ok((material, admission))
    }
    .await;
    state.relay_crypto_waiters.write().await.remove(&key);
    result
}

async fn receive_relay_crypto_step(
    receiver: &mut mpsc::Receiver<(u8, Vec<u8>)>,
    expected_step: u8,
    peer_id: &str,
) -> Result<Vec<u8>, ProtocolError> {
    match timeout(PEER_CONNECT_TIMEOUT, receiver.recv()).await {
        Ok(Some((step, payload))) if step == expected_step => Ok(payload),
        Ok(Some(_)) => Err(protocol_error_with_peer(
            NetworkErrorCode::AuthenticationFailed,
            "Relay application E2EE handshake step is out of order",
            "connect",
            peer_id,
        )),
        _ => Err(protocol_error_with_peer(
            NetworkErrorCode::Timeout,
            "Relay application E2EE handshake timed out",
            "connect",
            peer_id,
        )),
    }
}

/// 为路径选择和诊断对端点进行分类。
pub(crate) fn candidate_kind_for(endpoint: SocketAddr) -> CandidateKind {
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
        let supervisor = Arc::clone(&state.task_supervisor);
        let _ = supervisor.spawn_runtime("incoming-quic-handshake", async move {
            let mut attempted_session = None;
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
                let binding_state = Arc::clone(&state);
                let crypto =
                    tokio::time::timeout(
                        PEER_CONNECT_TIMEOUT,
                        crate::crypto_handshake::respond_quic(
                            &connection,
                            state.identity.read().await.clone().ok_or_else(|| {
                                std::io::Error::other("runtime identity unavailable")
                            })?,
                            &state.trusted_peer_keys,
                            move |authenticated_peer_id, remote_session_binding| {
                                let binding_state = Arc::clone(&binding_state);
                                let authenticated_peer_id = authenticated_peer_id.to_string();
                                let remote_session_binding = remote_session_binding.to_string();
                                async move {
                                    let admission = binding_state
                                        .admit_authenticated_session(
                                            &authenticated_peer_id,
                                            None,
                                            &remote_session_binding,
                                        )
                                        .await
                                        .map_err(|_| {
                                            crate::crypto_handshake::CryptoHandshakeError::Failed
                                        })?;
                                    Ok((admission.session_id.wire_key(), admission))
                                }
                            },
                        ),
                    )
                    .await
                    .map_err(|_| {
                        std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            "application E2EE handshake timed out",
                        )
                    })??;
                let (authenticated_peer_id, crypto, admission) = crypto;
                if authenticated_peer_id != peer_id {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::PermissionDenied,
                        "application E2EE identity does not match transport peer",
                    )
                    .into());
                }
                let session_id = admission.session_id;
                attempted_session = Some((peer_id.clone(), session_id));
                if session_id.wire_key() != crypto.local_session_binding {
                    return Err(
                        std::io::Error::other("responder Session binding became stale").into(),
                    );
                }
                state
                    .sessions
                    .finalize_authenticated_session(
                        &peer_id,
                        session_id,
                        &crypto.remote_session_binding,
                    )
                    .await
                    .map_err(|_| std::io::Error::other("Session was replaced during handshake"))?;
                install_admitted_crypto(&state, &peer_id, &admission, &crypto).await?;
                let previous_route = state
                    .sessions
                    .attach_connection_for_session(
                        &peer_id,
                        Some(session_id),
                        connection.clone(),
                        RouteType::QuicDirect,
                    )
                    .await
                    .map_err(|_| std::io::Error::other("Session was closed"))?;
                if let Some(previous_route) = previous_route {
                    previous_route.close().await;
                }
                if state.sessions.current_session_id(&peer_id).await != Some(session_id) {
                    return Err(std::io::Error::other("Session was closed").into());
                }
                emit_peer_state(
                    &state.event_tx,
                    &peer_id,
                    PeerConnectionState::Connected,
                    RouteType::QuicDirect,
                    None,
                );
                // transport-network v2：路径指标只发一次快照（§36 无后台路径迁移）。
                emit_route_changed(
                    &state.event_tx,
                    &peer_id,
                    RouteType::QuicDirect,
                    connection.remote_address(),
                    connection.rtt().as_millis().min(u32::MAX as u128) as u32,
                    0.0,
                );
                crate::channel::recover_session(Arc::clone(&state), peer_id.clone()).await;
                // §19：业务状态（Transfer）不属于 Session；每条新连接都尝试恢复暂停传输。
                crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.clone())
                    .await;
                spawn_session_receivers(Arc::clone(&state), peer_id, connection, session_id);
                Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
            }
            .await;
            if let Err(error) = result {
                if let Some((peer_id, session_id)) = attempted_session {
                    state.sessions.mark_failed(&peer_id, session_id).await;
                }
                tracing::warn!("Rejected inbound QUIC connection: {}", error);
            }
        });
    }
}

/// Accepts TCP fallback sockets on the same numeric port as the QUIC UDP
/// endpoint. A socket is not admitted into a Session until the generic
/// Ed25519/Session-binding handshake succeeds.
pub(crate) async fn accept_tcp_connections(listener: TcpListener, state: Arc<RuntimeState>) {
    loop {
        let (stream, peer_address) = match listener.accept().await {
            Ok(connection) => connection,
            Err(error) => {
                tracing::debug!(%error, "TCP fallback accept loop stopped");
                return;
            }
        };
        let state = Arc::clone(&state);
        let supervisor = Arc::clone(&state.task_supervisor);
        let _ = supervisor.spawn_runtime("incoming-tcp-handshake", async move {
            let mut probe = [0u8; 4];
            let looks_like_websocket =
                tokio::time::timeout(GENERIC_ROUTE_CONNECT_TIMEOUT, stream.peek(&mut probe))
                    .await
                    .ok()
                    .and_then(Result::ok)
                    .is_some_and(|length| length == probe.len() && &probe == b"GET ");
            #[cfg(test)]
            if !looks_like_websocket && !state.tcp_fallback_enabled.load(Ordering::Acquire) {
                return;
            }
            let connection = if looks_like_websocket {
                WebSocketTransport::accept(stream).await.map(|socket| {
                    GenericConnection::from_transport(Transport::WebSocket(Box::new(socket)))
                })
            } else {
                Ok(GenericConnection::from_transport(Transport::Tcp(
                    TcpTransport::from_stream(stream),
                )))
            };
            let result = match connection {
                Ok(connection) => {
                    accept_authenticated_generic(state, connection, peer_address).await
                }
                Err(error) => Err(error.into()),
            };
            if let Err(error) = result {
                tracing::debug!(%error, "rejected inbound TCP fallback route");
            }
        });
    }
}

async fn accept_authenticated_generic(
    state: Arc<RuntimeState>,
    mut connection: GenericConnection,
    peer_address: SocketAddr,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let identity = state
        .identity
        .read()
        .await
        .clone()
        .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?;
    let binding_state = Arc::clone(&state);
    let authenticated = tokio::time::timeout(
        GENERIC_ROUTE_CONNECT_TIMEOUT,
        authenticate_responder(
            &mut connection,
            identity,
            &state.trusted_peer_keys,
            move |peer_id, remote_session_binding| {
                let binding_state = Arc::clone(&binding_state);
                let peer_id = peer_id.to_string();
                let remote_session_binding = remote_session_binding.to_string();
                async move {
                    if !binding_state.peers.read().await.contains_key(&peer_id) {
                        return Err(crate::crypto_handshake::CryptoHandshakeError::Failed);
                    }
                    let admission = binding_state
                        .admit_authenticated_session(&peer_id, None, &remote_session_binding)
                        .await
                        .map_err(|_| crate::crypto_handshake::CryptoHandshakeError::Failed)?;
                    Ok((admission.session_id.wire_key(), admission))
                }
            },
        ),
    )
    .await
    .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "TCP auth timed out"))??;
    let crate::generic_auth::AuthenticatedPeer {
        peer_id,
        session_binding,
        crypto,
        admission,
    } = authenticated;
    tracing::debug!(%session_binding, "generic route Session binding authenticated");
    if admission.session_id.wire_key() != crypto.local_session_binding {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Interrupted,
            "generic route Session binding became stale",
        )
        .into());
    }
    let session_id = admission.session_id;
    state
        .sessions
        .finalize_authenticated_session(&peer_id, session_id, &crypto.remote_session_binding)
        .await
        .map_err(|_| std::io::Error::other("Session was replaced during handshake"))?;
    install_admitted_crypto(&state, &peer_id, &admission, &crypto).await?;
    let attempted_peer_id = peer_id.clone();
    let result = async {
        let mut scope = supervise_generic_route(
            Arc::clone(&state),
            &peer_id,
            session_id,
            prepare_generic_route(connection),
        )
        .await
        .map_err(|error| std::io::Error::other(error.message.clone()))?;
        let profile = scope
            .profile()
            .expect("supervised GenericRoute scope has a profile");
        let previous_route = match state
            .sessions
            .attach_generic_route_for_session(&peer_id, Some(session_id), &mut scope)
            .await
        {
            Ok(previous_route) => previous_route,
            Err(_) => {
                scope.close().await;
                return Err(std::io::Error::other("TCP route lost its Session race").into());
            }
        };
        if let Some(previous_route) = previous_route {
            previous_route.close().await;
        }
        emit_peer_state_profile(
            &state.event_tx,
            &peer_id,
            PeerConnectionState::Connected,
            Some(profile),
            None,
        );
        crate::channel::recover_session(Arc::clone(&state), peer_id.clone()).await;
        crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.clone()).await;
        tracing::debug!(%peer_address, session_id = %session_id.wire_key(), "authenticated TCP fallback route attached");
        Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
    }
    .await;
    if result.is_err() {
        state
            .sessions
            .mark_failed(&attempted_peer_id, session_id)
            .await;
    }
    result
}

/// 接受一个已认证对端的双向流。共享的 `accept_bi` 循环按首 4 字节路由：
/// 文件 offer (`SMFT`) 走 `handle_incoming_file_after_offer`，ReliableStream
/// 前导 (`SMSS`) 走 `crate::stream`（§17）。首 4 字节被消耗后，
/// 文件 offer 的其余字段由 `read_file_offer_after_magic` 续读，因此文件数据
/// 路径与原 `read_file_offer` 完全一致。
pub(crate) async fn receive_file_streams(
    peer_id: String,
    connection: Connection,
    state: Arc<RuntimeState>,
    session_id: SessionId,
) {
    loop {
        match connection.accept_bi().await {
            Ok((send, mut receive)) => {
                let state = Arc::clone(&state);
                let peer_id = peer_id.clone();
                let supervisor = Arc::clone(&state.task_supervisor);
                let _ = supervisor.spawn_session(
                    session_id.wire_key(),
                    "bidi-stream-receiver",
                    async move {
                        let mut magic = [0u8; 4];
                        if tokio::time::timeout(
                            GENERIC_ROUTE_CONNECT_TIMEOUT,
                            receive.read_exact(&mut magic),
                        )
                        .await
                        .ok()
                        .and_then(Result::ok)
                        .is_none()
                        {
                            return;
                        }
                        if magic == crate::stream::FILE_OFFER_MAGIC {
                            match crate::transfer::read_file_offer_after_magic(&mut receive).await {
                                Ok(manifest) => {
                                    crate::transfer::handle_incoming_file_after_offer(
                                        peer_id, send, receive, manifest, state,
                                    )
                                    .await;
                                }
                                Err(error) => {
                                    tracing::debug!(
                                        peer_id = %peer_id,
                                        error = %error,
                                        "rejected QUIC file offer"
                                    );
                                }
                            }
                        } else if magic == crate::stream::STREAM_QUIC_PREAMBLE_MAGIC {
                            match crate::stream::read_quic_stream_preamble_after_magic(&mut receive)
                                .await
                            {
                                Ok((stream_id, service)) => {
                                    crate::stream::handle_incoming_quic_stream(
                                        state, peer_id, stream_id, service, send, receive,
                                    )
                                    .await;
                                }
                                Err(error) => {
                                    tracing::debug!(
                                        peer_id = %peer_id,
                                        error = %error,
                                        "rejected QUIC reliable-stream preamble"
                                    );
                                }
                            }
                        }
                    },
                );
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
    session_id: SessionId,
) {
    loop {
        match connection.accept_uni().await {
            Ok(mut receive) => {
                let state = Arc::clone(&state);
                let peer_id = peer_id.clone();
                let supervisor = Arc::clone(&state.task_supervisor);
                let _ = supervisor.spawn_session(
                    session_id.wire_key(),
                    "channel-stream-receiver",
                    async move {
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
                    },
                );
            }
            Err(_) => {
                handle_connection_disconnect(&state, &peer_id, &connection).await;
                return;
            }
        }
    }
}

pub(crate) fn spawn_session_receivers(
    state: Arc<RuntimeState>,
    peer_id: String,
    connection: Connection,
    session_id: SessionId,
) {
    let supervisor = Arc::clone(&state.task_supervisor);
    let _ = supervisor.spawn_session(
        session_id.wire_key(),
        "file-receiver",
        receive_file_streams(
            peer_id.clone(),
            connection.clone(),
            Arc::clone(&state),
            session_id,
        ),
    );
    let _ = supervisor.spawn_session(
        session_id.wire_key(),
        "channel-receiver",
        receive_channel_streams(peer_id, connection, Arc::clone(&state), session_id),
    );
}

struct GenericReceiverStopGuard {
    route_stop: crate::task_supervisor::CancellationToken,
    stopping: Arc<std::sync::atomic::AtomicBool>,
}

impl Drop for GenericReceiverStopGuard {
    fn drop(&mut self) {
        if !self.stopping.load(Ordering::Acquire) {
            self.route_stop.cancel();
        }
    }
}

fn generic_route_receiver_task(
    state: Arc<RuntimeState>,
    peer_id: String,
    handle: GenericRouteHandle,
    mut inbound: mpsc::Receiver<GenericInboundFrame>,
    session_id: SessionId,
    route_stop: crate::task_supervisor::CancellationToken,
    stopping: Arc<std::sync::atomic::AtomicBool>,
) -> (
    impl Future<Output = ()> + Send + 'static,
    oneshot::Receiver<()>,
) {
    let (ready_tx, ready_rx) = oneshot::channel();
    let route_id = handle.id();
    let task = async move {
        let _stop_guard = GenericReceiverStopGuard {
            route_stop: route_stop.clone(),
            stopping: Arc::clone(&stopping),
        };
        if ready_tx.send(()).is_err() {
            return;
        }
        loop {
            tokio::select! {
                _ = route_stop.cancelled() => {
                    if !stopping.load(Ordering::Acquire) {
                        notify_generic_route_loss(&state, &peer_id, route_id, session_id).await;
                    }
                    return;
                }
                frame = inbound.recv() => {
                    let Some(frame) = frame else {
                        route_stop.cancel();
                        if !stopping.load(Ordering::Acquire) {
                            notify_generic_route_loss(&state, &peer_id, route_id, session_id).await;
                        }
                        return;
                    };
                    let result = match frame.kind {
                        GenericFrameKind::DataMessage => crate::channel::handle_data_message(
                            &state,
                            &peer_id,
                            &frame.payload,
                        )
                        .await
                        .map_err(|error| std::io::Error::other(error.to_string())),
                        GenericFrameKind::DeliveryAck => crate::channel::handle_delivery_ack(
                            &state,
                            &peer_id,
                            &frame.payload,
                        )
                        .await
                        .map_err(|error| std::io::Error::other(error.to_string())),
                        GenericFrameKind::StreamBytes
                        | GenericFrameKind::StreamOpen
                        | GenericFrameKind::StreamClose => crate::stream::handle_inbound_stream_frame(
                            &state,
                            &peer_id,
                            frame.kind,
                            &frame.payload,
                        )
                        .await
                        .map_err(|error| std::io::Error::other(error.to_string())),
                    };
                    if let Err(error) = result {
                        // StreamBytes is a data path: a malformed stream frame
                        // fails that stream only, never the route (§17).
                        tracing::debug!(peer_id = %peer_id, error = %error, "rejected generic channel frame");
                    }
                }
            }
        }
    };
    (task, ready_rx)
}

async fn notify_generic_route_loss(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    route_id: u64,
    _session_id: SessionId,
) {
    let destroyed = state
        .sessions
        .destroy_generic_session_if_current(peer_id, route_id)
        .await;
    if let Some((session_id, route)) = destroyed {
        spawn_session_teardown(Arc::clone(state), peer_id.to_string(), session_id, route);
        emit_peer_state(
            &state.event_tx,
            peer_id,
            PeerConnectionState::Disconnected,
            RouteType::Unspecified,
            None,
        );
        // transport-network v2（§18/§35）：transport 丢失即销毁 ConnectionSession，
        // 不自动重连（无 RECONNECTING）。业务下次 `connect()` 会重新 Resolve 并按需
        // 新建连接（新 SessionId + 新 Noise root）。
    }
}

async fn handle_connection_disconnect(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    connection: &Connection,
) {
    let destroyed = state
        .sessions
        .destroy_quic_session_if_current(peer_id, connection)
        .await;
    if let Some((session_id, route)) = destroyed {
        spawn_session_teardown(Arc::clone(state), peer_id.to_string(), session_id, route);
        emit_peer_state(
            &state.event_tx,
            peer_id,
            PeerConnectionState::Disconnected,
            RouteType::Unspecified,
            None,
        );
        // transport-network v2（§18/§35）：transport 丢失即销毁 ConnectionSession，
        // 不自动重连。业务下次 `connect()` 会重新 Resolve 并按需新建连接。
    }
}

/// 在 Session 组外调度一次完整的 session 销毁：关闭 detached route、retire
/// 资源并取消 supervised task group。调用方通常是 Session 组内的 receiver 任务，
/// 不能在此处自等 join，因此拆到 runtime task 执行。
fn spawn_session_teardown(
    state: Arc<RuntimeState>,
    peer_id: String,
    session_id: SessionId,
    route: ActiveRoute,
) {
    let supervisor = Arc::clone(&state.task_supervisor);
    let _ = supervisor.spawn_runtime("session-teardown", async move {
        route.close().await;
        state.cancel_session_tasks(&peer_id, session_id).await;
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::ConnectDecision;
    use network_transport::{TcpTransport, Transport};
    use std::collections::HashMap;
    use std::sync::atomic::AtomicU16;
    use tokio::io::AsyncReadExt;
    use tokio::net::{TcpListener, TcpStream};

    async fn generic_connection_pair() -> (GenericConnection, TcpStream) {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind generic route test listener");
        let address = listener
            .local_addr()
            .expect("generic route listener address");
        let (server_result, client_result) =
            tokio::join!(listener.accept(), TcpStream::connect(address));
        let server = server_result.expect("accept generic route test socket").0;
        let client = client_result.expect("connect generic route test socket");
        (
            GenericConnection::from_transport(Transport::Tcp(TcpTransport::from_stream(client))),
            server,
        )
    }

    async fn new_test_state() -> Arc<RuntimeState> {
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
        Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))))
    }

    async fn started_generic_scope(
        state: &Arc<RuntimeState>,
        peer_id: &str,
        session_id: SessionId,
        connection: GenericConnection,
    ) -> GenericRouteScope {
        supervise_generic_route(
            Arc::clone(state),
            peer_id,
            session_id,
            prepare_generic_route(connection),
        )
        .await
        .expect("generic route tasks should start")
    }

    async fn started_session(state: &RuntimeState, peer_id: &str) -> SessionId {
        match state.sessions.begin_connect(peer_id).await {
            ConnectDecision::Started(session_id) => session_id,
            decision => panic!("unexpected Session decision: {decision:?}"),
        }
    }

    struct CancellationSignal {
        started: Option<oneshot::Sender<()>>,
        cancelled: Option<oneshot::Sender<()>>,
    }

    impl Drop for CancellationSignal {
        fn drop(&mut self) {
            if let Some(sender) = self.cancelled.take() {
                let _ = sender.send(());
            }
        }
    }

    async fn wait_for_active_task_count(
        supervisor: &crate::task_supervisor::RuntimeTaskSupervisor,
        expected: usize,
    ) {
        timeout(Duration::from_secs(1), async {
            loop {
                if supervisor.active_count() == expected {
                    return;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap_or_else(|_| panic!("supervisor did not reach {expected} active tasks"));
    }

    #[tokio::test]
    async fn session_close_stops_and_joins_generic_route_tasks() {
        let state = new_test_state().await;
        let session_id = started_session(&state, "generic-close-peer").await;
        let (connection, mut server) = generic_connection_pair().await;
        let mut scope =
            started_generic_scope(&state, "generic-close-peer", session_id, connection).await;
        assert_eq!(state.task_supervisor.active_count(), 2);
        state
            .sessions
            .attach_generic_route_for_session("generic-close-peer", Some(session_id), &mut scope)
            .await
            .expect("attach GenericRoute");

        let route = state
            .sessions
            .close("generic-close-peer")
            .await
            .expect("Session close should detach GenericRoute owner");
        route.close().await;
        assert_eq!(state.task_supervisor.active_count(), 0);

        let mut buffer = [0u8; 1];
        let read = tokio::time::timeout(Duration::from_secs(1), server.read(&mut buffer))
            .await
            .expect("underlying TCP socket should close")
            .expect("read server-side socket");
        assert_eq!(read, 0);
    }

    #[tokio::test]
    async fn connected_session_rejects_a_second_route_to_enforce_one_to_one() {
        // §18 1:1：Session 已 Connected 且持有 route 时，拒绝再挂第二条 route。
        let state = new_test_state().await;
        let peer_id = "generic-one-to-one-peer";
        let session_id = started_session(&state, peer_id).await;
        let (first_connection, _server) = generic_connection_pair().await;
        let mut first_scope =
            started_generic_scope(&state, peer_id, session_id, first_connection).await;
        state
            .sessions
            .attach_generic_route_for_session(peer_id, Some(session_id), &mut first_scope)
            .await
            .expect("attach first GenericRoute");

        let (second_connection, _second_server) = generic_connection_pair().await;
        let mut second_scope =
            started_generic_scope(&state, peer_id, session_id, second_connection).await;
        assert!(state
            .sessions
            .attach_generic_route_for_session(peer_id, Some(session_id), &mut second_scope)
            .await
            .is_err());
        second_scope.close().await;

        let current_route = state.sessions.close(peer_id).await.expect("close Session");
        current_route.close().await;
        assert_eq!(state.task_supervisor.active_count(), 0);
    }

    #[tokio::test]
    async fn outbound_generic_peer_restart_replaces_session_and_cancels_old_tasks() {
        // §18：peer restart（新 remote binding）会让新连接整体替换旧 Session（新
        // SessionId + 新 root），并且旧 Session 的 task group 在 admission 时立即取消。
        let state = new_test_state().await;
        let peer_id = "generic-outbound-restart-peer";
        let local_peer_id = "generic-outbound-local";
        let old_session_id = started_session(&state, peer_id).await;
        let old_remote_binding = "11".repeat(16);
        let new_remote_binding = "22".repeat(16);
        state
            .sessions
            .admit_authenticated_session(peer_id, Some(old_session_id), &old_remote_binding)
            .await
            .expect("seed the old remote Session binding");

        // 在握手前把哨兵放进旧 Session 组，验证被替换后立即取消。
        let (sentinel_started_tx, sentinel_started_rx) = oneshot::channel();
        let (sentinel_cancelled_tx, sentinel_cancelled_rx) = oneshot::channel();
        let sentinel_task = state.task_supervisor.spawn_session(
            old_session_id.wire_key(),
            "old-session-sentinel",
            async move {
                let mut signal = CancellationSignal {
                    started: Some(sentinel_started_tx),
                    cancelled: Some(sentinel_cancelled_tx),
                };
                if let Some(sender) = signal.started.take() {
                    let _ = sender.send(());
                }
                std::future::pending::<()>().await;
            },
        );
        assert!(sentinel_task.is_some(), "old Session sentinel should start");
        timeout(Duration::from_secs(1), sentinel_started_rx)
            .await
            .expect("old Session sentinel did not start")
            .expect("old Session sentinel start signal was dropped");

        let local_identity = Arc::new(DeviceIdentity::from_private_keys(
            local_peer_id.to_string(),
            [201u8; 32],
            [211u8; 32],
        ));
        let remote_identity = Arc::new(DeviceIdentity::from_private_keys(
            peer_id.to_string(),
            [202u8; 32],
            [212u8; 32],
        ));
        let local_public_key = local_identity.public_identity_key().to_bytes();
        let remote_public_key = remote_identity.public_identity_key().to_bytes();
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind outbound GenericRoute test listener");
        let endpoint = listener
            .local_addr()
            .expect("outbound GenericRoute test endpoint");
        let (release_tx, release_rx) = oneshot::channel();
        let (received_frame_tx, received_frame_rx) = oneshot::channel();
        let expected_old_binding = old_session_id.wire_key();
        let expected_local_peer_id = local_peer_id.to_string();
        let responder_task = tokio::spawn(async move {
            let (stream, _) = listener
                .accept()
                .await
                .expect("accept outbound GenericRoute test connection");
            let mut connection = GenericConnection::from_transport(Transport::Tcp(
                TcpTransport::from_stream(stream),
            ));
            let trusted_peer_keys = tokio::sync::RwLock::new(HashMap::from([(
                expected_local_peer_id.clone(),
                local_public_key,
            )]));
            let authenticated = authenticate_responder(
                &mut connection,
                remote_identity,
                &trusted_peer_keys,
                move |authenticated_peer_id, remote_session_binding| {
                    assert_eq!(authenticated_peer_id, expected_local_peer_id);
                    assert_eq!(remote_session_binding, expected_old_binding);
                    async move { Ok((new_remote_binding, ())) }
                },
            )
            .await
            .expect("complete outbound GenericRoute authentication");
            assert_eq!(authenticated.peer_id, local_peer_id);
            let received_frame = timeout(Duration::from_secs(1), connection.recv())
                .await
                .expect("outbound GenericRoute frame was not received")
                .expect("read outbound GenericRoute frame");
            received_frame_tx
                .send(received_frame)
                .expect("send received GenericRoute frame to test");
            release_rx.await.expect("release responder connection");
        });

        let route = connect_tcp_route(
            endpoint,
            local_identity,
            remote_public_key,
            peer_id.to_string(),
            old_session_id.wire_key(),
            Arc::clone(&state),
            old_session_id,
        )
        .await
        .expect("outbound TCP GenericRoute should authenticate");
        // 握手期间 admission 已经取消了旧 Session 组（含哨兵）。
        timeout(Duration::from_secs(1), sentinel_cancelled_rx)
            .await
            .expect("old Session cancellation did not complete during admission")
            .expect("old Session sentinel signal was dropped");

        let AuthenticatedGenericRoute {
            mut scope,
            admission,
            ..
        } = route;
        let new_session_id = admission.session_id;
        assert_ne!(new_session_id, old_session_id);

        state
            .sessions
            .attach_generic_route_for_session(peer_id, Some(new_session_id), &mut scope)
            .await
            .expect("attach outbound GenericRoute to replacement Session");

        wait_for_active_task_count(&state.task_supervisor, 2).await;
        assert_eq!(
            state.sessions.current_session_id(peer_id).await,
            Some(new_session_id)
        );

        let payload = b"replacement-route-still-alive";
        timeout(
            Duration::from_secs(1),
            state
                .sessions
                .send_channel_frame(peer_id, "", GenericFrameKind::DataMessage, payload),
        )
        .await
        .expect("sending through replacement GenericRoute timed out")
        .expect("replacement GenericRoute should still send frames");
        let received_frame = timeout(Duration::from_secs(1), received_frame_rx)
            .await
            .expect("replacement GenericRoute frame confirmation timed out")
            .expect("replacement GenericRoute frame confirmation was dropped");
        let mut expected_frame = b"SMGF".to_vec();
        expected_frame.extend_from_slice(&network_protocol::NETWORK_PROTOCOL_VERSION.to_be_bytes());
        expected_frame.push(GenericFrameKind::DataMessage as u8);
        expected_frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        expected_frame.extend_from_slice(payload);
        assert_eq!(received_frame, expected_frame);

        let current_route = state
            .sessions
            .close(peer_id)
            .await
            .expect("close replacement GenericRoute");
        current_route.close().await;
        let _ = release_tx.send(());
        responder_task
            .await
            .expect("outbound GenericRoute responder should exit");
        assert_eq!(state.task_supervisor.active_count(), 0);
    }

    #[tokio::test]
    async fn failed_generic_attach_drops_staged_scope_without_orphan_tasks() {
        let state = new_test_state().await;
        let session_id = started_session(&state, "generic-failed-attach-peer").await;
        let (connection, mut server) = generic_connection_pair().await;
        let mut scope =
            started_generic_scope(&state, "generic-failed-attach-peer", session_id, connection)
                .await;
        state.sessions.close("generic-failed-attach-peer").await;
        assert!(state
            .sessions
            .attach_generic_route_for_session(
                "generic-failed-attach-peer",
                Some(session_id),
                &mut scope,
            )
            .await
            .is_err());
        scope.close().await;
        assert_eq!(state.task_supervisor.active_count(), 0);

        let mut buffer = [0u8; 1];
        let read = tokio::time::timeout(Duration::from_secs(2), server.read(&mut buffer))
            .await
            .expect("failed attach should close staged socket")
            .expect("read failed attach socket");
        assert_eq!(read, 0);
    }

    #[test]
    fn runtime_stop_joins_generic_route_tasks() {
        let runtime = crate::runtime::NetworkRuntime::new().expect("create runtime");
        runtime.start().expect("start runtime");
        let state = runtime
            .state
            .lock()
            .expect("runtime state lock")
            .clone()
            .expect("runtime state");
        let (server, scope) = runtime.handle().block_on(async {
            let session_id = started_session(&state, "generic-runtime-stop-peer").await;
            let (connection, server) = generic_connection_pair().await;
            let mut scope =
                started_generic_scope(&state, "generic-runtime-stop-peer", session_id, connection)
                    .await;
            state
                .sessions
                .attach_generic_route_for_session(
                    "generic-runtime-stop-peer",
                    Some(session_id),
                    &mut scope,
                )
                .await
                .expect("attach runtime GenericRoute");
            (server, scope)
        });
        drop(scope);
        runtime.stop().expect("stop runtime");
        assert_eq!(state.task_supervisor.active_count(), 0);
        runtime.handle().block_on(async {
            let mut server = server;
            let mut buffer = [0u8; 1];
            let read = tokio::time::timeout(Duration::from_secs(1), server.read(&mut buffer))
                .await
                .expect("runtime stop should close GenericRoute socket")
                .expect("read runtime-stop socket");
            assert_eq!(read, 0);
        });
    }

    #[test]
    fn candidate_fixture_classification_covers_lan_ipv6_and_reflexive_paths() {
        assert_eq!(
            candidate_kind_for("192.168.1.20:41020".parse().unwrap()),
            CandidateKind::Lan
        );
        assert_eq!(
            candidate_kind_for("[2001:db8::20]:41021".parse().unwrap()),
            CandidateKind::PublicIpv6
        );
        assert_eq!(
            candidate_kind_for("198.51.100.20:41022".parse().unwrap()),
            CandidateKind::ServerReflexive
        );
    }
}
