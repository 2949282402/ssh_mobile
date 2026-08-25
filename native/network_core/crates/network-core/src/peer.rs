//! 对端注册表、路由选择与异步连接任务（transport-network v2）。

use network_identity::DeviceIdentity;
use network_nat::{Candidate, CandidateKind, PathManager, MAX_CANDIDATES_PER_SIGNAL};
use network_protocol::{
    NetworkError as ProtocolError, NetworkErrorCode, PeerConnectionState, RouteType,
    UpsertPeerCommand,
};
use network_quic::{read_channel_frame, ChannelFrameKind, QuicEndpointManager, QuicPeerSession};
use network_relay::RelayDataClient;
use network_transport::{TcpTransport, Transport, WebSocketTransport};
use quinn::{Connection, Endpoint, VarInt};
use std::collections::{HashSet, VecDeque};
use std::future::Future;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::{atomic::Ordering, Arc};
use std::time::{Duration, Instant};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, oneshot, watch};
use tokio::task::JoinSet;
use tokio::time::timeout;

use crate::connect::GenericRouteScope;
use crate::connect::{
    profile_capability_mask, CAPABILITY_UNRELIABLE_DATAGRAM, DEFAULT_CONNECTION_CAPABILITY,
};
#[cfg(test)]
use crate::connect::{CAPABILITY_RELIABLE_MESSAGE, CAPABILITY_RELIABLE_STREAM};
use crate::connection::{
    prepare_generic_route, ConnectionProfile, GenericConnection, GenericFrameKind,
    GenericInboundFrame, GenericRouteHandle, GenericRouteRuntime, RouteTopology, RouteTransport,
};
use crate::crypto_handshake::SessionCryptoMaterial;
use crate::events::{
    emit_peer_state, emit_peer_state_profile, emit_route_changed, protocol_error,
    protocol_error_with_peer,
};
use crate::generic_auth::{authenticate_initiator_with_policy, authenticate_responder_auto_policy};
use crate::runtime::{
    ConnectionAdmissionLease, PeerConfig, RuntimeState, MAX_PENDING_RELAY_CRYPTO_HANDSHAKES,
    PEER_CONNECT_TIMEOUT,
};
use crate::session::{ConnectionAdmissionError, SessionId};

const STUN_SERVERS_ENV: &str = "SSH_MOBILE_STUN_SERVERS";
const STUN_PROBE_TIMEOUT: Duration = Duration::from_millis(750);
const GENERIC_ROUTE_CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const GENERIC_ROUTE_TASK_START_TIMEOUT: Duration = Duration::from_secs(1);
/// Delay between launching successive candidate groups. Every attempt still
/// shares the parent Direct deadline; this only prevents a blackhole from
/// monopolizing the first probe slot while keeping the race bounded.
const CANDIDATE_STAGGER: Duration = Duration::from_millis(150);
/// Direct 阶段中 QUIC race 的领先预算（§15）：先给 QUIC 候选一个子预算，然后用窗口
/// 剩余预算跑 generic（TCP/WebSocket）候选。避免 QUIC 候选被黑洞/超时耗尽整个 Direct
/// 窗口时，仅 TCP/WS 可达的 peer 被饿死而错误回退 Relay。
const QUIC_LEAD_BUDGET: Duration = Duration::from_millis(2500);
/// TCP fallback accept 循环在瞬态错误（EMFILE/ENOBUFS/aborted）后的退避间隔，避免
/// 热点重试（§40）。
const TCP_ACCEPT_RETRY_BACKOFF: Duration = Duration::from_millis(50);
const TCP_ACCEPT_RETRY_BACKOFF_MAX: Duration = Duration::from_millis(500);

pub(crate) struct AuthenticatedGenericRoute {
    pub(crate) scope: GenericRouteScope,
    pub(crate) endpoint: SocketAddr,
    pub(crate) crypto: SessionCryptoMaterial,
    pub(crate) admission: ConnectionAdmissionLease,
}

pub(crate) enum ConnectedRoute {
    Quic {
        connection: Connection,
        crypto: SessionCryptoMaterial,
        admission: ConnectionAdmissionLease,
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
    /// Exact capability demand carried by this attempt.  A supervisor may
    /// merge concurrent business requests, so route admission must validate
    /// this mask instead of relying on the legacy class projection.
    pub(crate) required_capabilities: u8,
    pub(crate) allow_websocket: bool,
    /// Candidate snapshots arriving from the authenticated ConnectivityAnswer
    /// while the bounded Direct race is still running.
    pub(crate) candidate_updates: watch::Receiver<Option<Vec<Candidate>>>,
}

/// Owns outbound TCP/WebSocket candidate races and route startup.
struct OutboundGenericConnector;

/// Owns runtime-scoped QUIC/TCP accept loops and authenticated admission.
pub(crate) struct InboundConnectionAcceptor;

/// Owns session-scoped QUIC/generic receivers and path-loss cleanup.
pub(crate) struct ConnectionReceiverSupervisor;

/// Installs the fresh Noise root for a Session admission（§18 1:1）. The root is
/// always new per connection; there is no ContinueExisting path. Responder
/// handshakes use this after selecting the final local binding before sending
/// the RootSeed.
pub(crate) async fn install_admitted_crypto(
    state: &RuntimeState,
    peer_id: &str,
    admission: &ConnectionAdmissionLease,
    crypto: &SessionCryptoMaterial,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if !crypto.has_application_e2ee() {
        return Ok(());
    }
    if state.connection_sessions.current_session_id(peer_id).await != Some(admission.session_id) {
        state.fail_session(peer_id, admission.session_id).await;
        return Err(std::io::Error::other("application E2EE admission is stale").into());
    }
    if state
        .install_crypto_material(peer_id, &admission.session_id.wire_key(), crypto)
        .is_err()
    {
        state.fail_session(peer_id, admission.session_id).await;
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
    if state.lifecycle.endpoint.read().await.is_some() {
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
    // TCP and UDP intentionally advertise the same numeric port, but UDP port
    // 0 allocation can race with another runtime's TCP listener when tests or
    // multiple local runtimes start concurrently. If the caller requested an
    // ephemeral port, discard the colliding UDP socket and select another
    // paired port; an explicit port remains fail-closed.
    const EPHEMERAL_BIND_ATTEMPTS: usize = 8;
    let bind_attempts = if listen_address.port() == 0 {
        EPHEMERAL_BIND_ATTEMPTS
    } else {
        1
    };
    let mut last_tcp_bind_error = None;
    let (path_manager, socket, bound_address, tcp_listener) = {
        let mut selected = None;
        for _ in 0..bind_attempts {
            let path_manager = Arc::new(PathManager::new());
            let (socket, bound_address) = bind_and_gather_candidates(listen_address, &path_manager)
                .await
                .map_err(|error| protocol_error(NetworkErrorCode::QuicError, error.to_string()))?;
            let tcp_socket = match std::net::TcpListener::bind(bound_address) {
                Ok(socket) => socket,
                Err(error) if listen_address.port() == 0 => {
                    last_tcp_bind_error = Some(error);
                    drop(socket);
                    continue;
                }
                Err(error) => {
                    return Err(protocol_error(
                        NetworkErrorCode::IoError,
                        format!("failed to bind TCP fallback listener: {error}"),
                    ));
                }
            };
            tcp_socket
                .set_nonblocking(true)
                .map_err(|error| protocol_error(NetworkErrorCode::IoError, error.to_string()))?;
            let tcp_listener = TcpListener::from_std(tcp_socket).map_err(|error| {
                protocol_error(
                    NetworkErrorCode::IoError,
                    format!("failed to configure TCP fallback listener: {error}"),
                )
            })?;
            selected = Some((path_manager, socket, bound_address, tcp_listener));
            break;
        }
        selected.ok_or_else(|| {
            protocol_error(
                NetworkErrorCode::IoError,
                format!(
                    "failed to bind paired ephemeral TCP/UDP listeners after {bind_attempts} attempts: {}",
                    last_tcp_bind_error
                        .map(|error| error.to_string())
                        .unwrap_or_else(|| "unknown bind error".into())
                ),
            )
        })?
    };
    path_manager
        .set_generation(monotonic_candidate_generation())
        .await;
    let manager = QuicEndpointManager::from_bound_socket(socket, Arc::clone(&path_manager))
        .map_err(|error| protocol_error(NetworkErrorCode::QuicError, error.to_string()))?;
    let endpoint = manager.endpoint;
    state
        .lifecycle
        .bound_port
        .store(bound_address.port(), Ordering::Release);
    *state.lifecycle.identity.write().await = Some(identity);
    *state.lifecycle.receive_directory.write().await = Some(receive_directory);
    *state.local_path_manager.write().await = Some(path_manager);
    *state.lifecycle.endpoint.write().await = Some(endpoint.clone());
    tracing::info!(%bound_address, "native UDP socket is shared by candidate discovery and QUIC");
    let task_id = state
        .task_supervisor
        .spawn_runtime(
            "quic-accept",
            InboundConnectionAcceptor::accept_connections(endpoint, Arc::clone(&state)),
        )
        .ok_or_else(|| {
            protocol_error(NetworkErrorCode::Cancelled, "network runtime is stopping")
        })?;
    {
        // 作用域限定 MutexGuard 生命周期，避免跨 await 持有非 Send 的 guard。
        let mut accept_task = state.lifecycle.accept_task.lock().map_err(|_| {
            protocol_error(NetworkErrorCode::QuicError, "accept task lock poisoned")
        })?;
        *accept_task = Some(task_id);
    }
    let tcp_task_id = state
        .task_supervisor
        .spawn_runtime(
            "tcp-accept",
            InboundConnectionAcceptor::accept_tcp_connections(tcp_listener, Arc::clone(&state)),
        )
        .ok_or_else(|| {
            protocol_error(NetworkErrorCode::Cancelled, "network runtime is stopping")
        })?;
    {
        let mut tcp_accept_task = state.lifecycle.tcp_accept_task.lock().map_err(|_| {
            protocol_error(NetworkErrorCode::IoError, "TCP accept task lock poisoned")
        })?;
        *tcp_accept_task = Some(tcp_task_id);
    }
    // transport-network v2：运行时配置完成（identity + 本地候选已就绪）后初始化本地
    // Discovery 生命周期（新 runtime_epoch + revision=1）。V2 upload_discovery /
    // peer_presence 已随 Step 11 删除。
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
        .map(|value| parse_stun_servers(&value))
        .unwrap_or_default()
}

fn parse_stun_servers(value: &str) -> Vec<SocketAddr> {
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
}

/// 校验并保存一个对端路由及其可信身份密钥。
#[cfg(test)]
pub(crate) async fn upsert_peer(
    state: &RuntimeState,
    command: UpsertPeerCommand,
) -> Result<(), ProtocolError> {
    upsert_peer_with_policy(state, command, network_protocol::E2eePolicy::Required).await
}

pub(crate) async fn upsert_peer_with_policy(
    state: &RuntimeState,
    command: UpsertPeerCommand,
    e2ee_policy: network_protocol::E2eePolicy,
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
    state
        .peer_supervisors
        .get_or_create_with_configured(&command.peer_id, true)
        .map_err(|error| protocol_error(NetworkErrorCode::InvalidArgument, error.to_string()))?;
    // transport-network v2：upsert 只保存配置 endpoint 与可信密钥；对端候选不再存
    // 全局 path_manager（§12/§29）。每次 connect 前由 ConnectivityAttemptCoordinator 经 Resolve
    // 获取权威 Discovery，本地配置 endpoint 作为 Direct 候选追加。
    state.peers.write().await.insert(
        command.peer_id.clone(),
        PeerConfig {
            endpoint,
            identity_public_key,
            e2e_public_key,
            e2ee_policy,
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
    state
        .peer_supervisors
        .disconnect(&peer_id)
        .map_err(|error| protocol_error(NetworkErrorCode::InvalidArgument, error.to_string()))?;
    let session_id = state.connection_sessions.current_session_id(&peer_id).await;
    let _ = state.close_transport_path(&peer_id).await;
    if let Some(session_id) = session_id {
        let _ = state
            .connection_sessions
            .retire_session(&peer_id, session_id)
            .await;
        state.cancel_session_tasks(&peer_id, session_id).await;
        // Explicit Peer disconnect releases receive-side active handlers and
        // ordered buffers. A transient Connection loss takes a different path
        // (Session destroyed) and must keep them for Delivery recovery（§20）——
        // 因此清理只发生在用户显式断开时，transport 丢失不清理。
        state.delivery.close_peer(&peer_id).await;
    }
    // transport-network v2：断开时注销连接登记（§34）。
    state.ready_session_index.unregister(&peer_id);
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
    expected_session_id: Option<SessionId>,
    required_capabilities: u8,
) -> Result<(Connection, SessionCryptoMaterial, ConnectionAdmissionLease), ProtocolError> {
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
    let e2ee_policy = state.e2ee_policy(&peer_id).await;
    let expected_peer_id_for_resolver = peer_id.clone();
    let admission_state = Arc::clone(&state);
    let (crypto, admission) = tokio::time::timeout(
        remaining,
        crate::crypto_handshake::initiate_quic_with_policy(
            &connection,
            identity,
            &peer_id,
            expected_peer_public_key,
            session_binding,
            e2ee_policy,
            move |authenticated_peer_id, remote_session_binding| {
                let state = Arc::clone(&admission_state);
                let authenticated_peer_id = authenticated_peer_id.to_string();
                let remote_session_binding = remote_session_binding.to_string();
                async move {
                    if authenticated_peer_id != expected_peer_id_for_resolver {
                        return Err(crate::crypto_handshake::CryptoHandshakeError::Failed);
                    }
                    let admission = admit_single_winner(
                        &state,
                        &authenticated_peer_id,
                        expected_session_id,
                        &remote_session_binding,
                        required_capabilities,
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
    let quic_profile =
        ConnectionProfile::for_route(RouteType::QuicDirect).expect("QUIC route profile");
    if !state
        .candidate_supports(
            &peer_id,
            admission.session_id,
            quic_profile,
            required_capabilities,
        )
        .await
    {
        state
            .connection_sessions
            .release_authenticated_session(
                &peer_id,
                admission.session_id,
                &crypto.remote_session_binding,
            )
            .await;
        connection.close(VarInt::from_u32(0), b"candidate lacks requested capability");
        return Err(protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            "QUIC candidate no longer satisfies the requested capability",
            "connect",
            &peer_id,
        ));
    }
    Ok((connection, crypto, admission))
}

/// Single-winner Session admission（§18/§40 Concurrency）。
///
/// `connect_direct_candidates_with_crypto` 并发 race 多个 candidate 时，每个 candidate
/// 都会走到 `admit_authenticated_session`。若 winner 已把 route 挂到 Session（state →
/// Connected），loser 迟到的 admit 会触发 `ReplaceWithNew`：拆掉刚挂载的 winning route，
/// 双方都掉线。本 guard 在 admit 前重查当前 Session 状态——仍处于 in-flight（未挂载、
/// 未被替换）才继续 admit，否则视为 loser 拒绝，绝不触发替换。只服务发起方候选
/// （expected_session_id 已知）；应答方 simultaneous connect 的 Initialize 语义不受影响。
async fn admit_single_winner(
    state: &RuntimeState,
    peer_id: &str,
    expected_session_id: Option<SessionId>,
    remote_session_binding: &str,
    candidate_capabilities: u8,
) -> Result<ConnectionAdmissionLease, ConnectionAdmissionError> {
    loop {
        // Session 已 Connected（winner 已挂载 route）：后来的 candidate 是 loser，拒绝。
        if state.path_is_connected(peer_id).await {
            return Err(ConnectionAdmissionError::StaleSession);
        }
        // 期望的 Session 已被替换/销毁：同样是 loser。
        if let Some(expected) = expected_session_id {
            if state.connection_sessions.current_session_id(peer_id).await != Some(expected) {
                return Err(ConnectionAdmissionError::StaleSession);
            }
        }
        match state
            .admit_authenticated_session_with_capability(
                peer_id,
                expected_session_id,
                remote_session_binding,
                candidate_capabilities,
            )
            .await
        {
            Ok(admission) => return Ok(admission),
            Err(ConnectionAdmissionError::StaleSession)
                if state
                    .path_admission_can_retry(peer_id, expected_session_id)
                    .await =>
            {
                state.wait_for_path_change().await;
            }
            Err(error) => return Err(error),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct CandidateAttemptKey {
    candidate_id: String,
    endpoint: SocketAddr,
    generation: u64,
}

fn candidate_attempt_key(candidate: &Candidate) -> CandidateAttemptKey {
    CandidateAttemptKey {
        candidate_id: candidate.candidate_id.clone(),
        endpoint: candidate.endpoint,
        generation: candidate.generation,
    }
}

/// Reconciles an authoritative candidate snapshot with the not-yet-started queue.
/// An endpoint or generation change creates a new attempt key even when the
/// candidate ID is unchanged; candidates removed from the snapshot are dropped
/// before they can enter the race. Active attempts are intentionally left alone.
fn enqueue_candidates(
    pending: &mut VecDeque<Candidate>,
    started: &mut HashSet<CandidateAttemptKey>,
    candidates: Vec<Candidate>,
) {
    let snapshot = candidates
        .into_iter()
        // Relay is a separate fallback path. It is never a DirectProbe target,
        // even if a stale/legacy Discovery snapshot still carries a relay
        // candidate alongside direct candidates.
        .filter(|candidate| candidate.kind != CandidateKind::Relay)
        .take(MAX_CANDIDATES_PER_SIGNAL)
        .collect::<Vec<_>>();
    let snapshot_keys = snapshot
        .iter()
        .map(candidate_attempt_key)
        .collect::<HashSet<_>>();
    pending.retain(|candidate| snapshot_keys.contains(&candidate_attempt_key(candidate)));
    for candidate in snapshot {
        let key = candidate_attempt_key(&candidate);
        if !started.contains(&key)
            && !pending
                .iter()
                .any(|pending| candidate_attempt_key(pending) == key)
        {
            pending.push_back(candidate);
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn connect_direct_candidates_with_crypto(
    endpoint: Endpoint,
    candidates: Vec<Candidate>,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
    attempt_id: String,
    deadline: Instant,
    session_binding: String,
    state: Arc<RuntimeState>,
    expected_session_id: Option<SessionId>,
    required_capabilities: u8,
    mut candidate_updates: watch::Receiver<Option<Vec<Candidate>>>,
) -> Result<(Connection, SessionCryptoMaterial, ConnectionAdmissionLease), ProtocolError> {
    let mut pending = VecDeque::new();
    let mut started = HashSet::new();
    enqueue_candidates(&mut pending, &mut started, candidates);
    let mut attempts = JoinSet::new();
    let mut next_launch_at = Instant::now();
    let mut updates_closed = false;
    let mut last_error = None;

    loop {
        if !pending.is_empty() && Instant::now() >= next_launch_at {
            let candidate = pending.pop_front().expect("pending candidate");
            started.insert(candidate_attempt_key(&candidate));
            let candidate_window = deadline.saturating_duration_since(Instant::now());
            if candidate_window.is_zero() {
                break;
            }
            let endpoint = endpoint.clone();
            let identity = Arc::clone(&identity);
            let peer_id_for_task = peer_id.clone();
            let session_binding = session_binding.clone();
            let attempt_id = attempt_id.clone();
            let state = Arc::clone(&state);
            attempts.spawn(async move {
                connect_direct_with_crypto(
                    endpoint,
                    candidate.endpoint,
                    identity,
                    expected_peer_public_key,
                    peer_id_for_task,
                    attempt_id,
                    candidate_window,
                    &session_binding,
                    state,
                    expected_session_id,
                    required_capabilities,
                )
                .await
            });
            next_launch_at = Instant::now() + CANDIDATE_STAGGER;
            continue;
        }

        // QUIC is only the lead phase, but keep the coordination receiver alive until
        // its deadline even if current candidates fail: a late ConnectivityAnswer may
        // add the candidate that wins the race. The same receiver is handed to generic
        // fallback after the QUIC lead budget expires.
        if attempts.is_empty()
            && pending.is_empty()
            && (updates_closed || Instant::now() >= deadline)
        {
            break;
        }

        tokio::select! {
            result = attempts.join_next(), if !attempts.is_empty() => {
                match result {
                    Some(Ok(Ok(route))) => {
                        attempts.abort_all();
                        return Ok(route);
                    }
                    Some(Ok(Err(error))) => last_error = Some(error),
                    Some(Err(error)) => {
                        last_error = Some(protocol_error_with_peer(
                            NetworkErrorCode::QuicError,
                            format!("candidate connectivity task failed: {error}"),
                            "connect",
                            &peer_id,
                        ));
                    }
                    None => {}
                }
            }
            changed = candidate_updates.changed(), if !updates_closed => {
                match changed {
                    Ok(()) => {
                        if let Some(update) = candidate_updates.borrow_and_update().clone() {
                            let had_pending = !pending.is_empty();
                            enqueue_candidates(&mut pending, &mut started, update);
                            if !had_pending && !pending.is_empty() {
                                next_launch_at = Instant::now();
                            }
                        }
                    }
                    Err(_) => updates_closed = true,
                }
            }
            _ = tokio::time::sleep_until(tokio::time::Instant::from_std(next_launch_at)), if !pending.is_empty() => {}
            _ = tokio::time::sleep_until(tokio::time::Instant::from_std(deadline)),
                if attempts.is_empty() && pending.is_empty() =>
            {
                break;
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

/// Route selection gives QUIC the first direct budget, then races authenticated
/// TCP and binary WebSocket attempts in staggered candidate groups. Each
/// generic route is admitted only after the same identity proof used by QUIC.
///
/// §15/§37：Direct 窗口被切成两段——QUIC 候选并行竞争 `min(window, QUIC_LEAD_BUDGET)`，
/// 然后用窗口**剩余**预算在统一 deadline 内按候选组交错启动 generic
/// （TCP/WebSocket）尝试。这样 QUIC 被黑洞/超时耗尽后，仅 TCP/WS 可达的 peer
/// 仍能在窗口内走 generic 成功，而不是被饿死回退 Relay。
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
        required_capabilities,
        allow_websocket,
        candidate_updates,
    } = attempt;
    let generic_candidates = candidates.clone();
    let started = Instant::now();
    // QUIC race 领先预算（不改变 DIRECT_CONNECT_WINDOW 的语义：它仍是整个 Direct 阶段
    // 的总窗口）。
    let quic_budget = connect_window.min(QUIC_LEAD_BUDGET);

    // 1) QUIC 候选并行竞争（子预算内）。
    let quic_deadline = Instant::now() + quic_budget;
    let quic_result = tokio::time::timeout(
        quic_budget,
        connect_direct_candidates_with_crypto(
            endpoint,
            candidates,
            Arc::clone(&identity),
            expected_peer_public_key,
            peer_id.clone(),
            attempt_id,
            quic_deadline,
            session_binding.clone(),
            Arc::clone(&state),
            Some(session_id),
            required_capabilities,
            candidate_updates.clone(),
        ),
    )
    .await;
    let quic_fallback_error = match quic_result {
        Ok(Ok((connection, crypto, admission))) => {
            return Ok(ConnectedRoute::Quic {
                connection,
                crypto,
                admission,
            });
        }
        Ok(Err(error)) => error,
        Err(_) => protocol_error_with_peer(
            NetworkErrorCode::Timeout,
            "Direct QUIC window elapsed",
            "connect",
            &peer_id,
        ),
    };

    // 2) QUIC 未胜出：用窗口剩余预算跑 generic（TCP/WS）候选。
    let direct_deadline = started + connect_window;
    let remaining = direct_deadline.saturating_duration_since(Instant::now());
    let generic_result = tokio::time::timeout(
        remaining,
        OutboundGenericConnector::connect_generic_candidates(
            generic_candidates,
            identity,
            expected_peer_public_key,
            peer_id.clone(),
            session_binding,
            state,
            session_id,
            required_capabilities,
            allow_websocket,
            direct_deadline,
            candidate_updates,
        ),
    )
    .await;
    match generic_result {
        Ok(Ok(route)) => Ok(ConnectedRoute::Generic(route)),
        Ok(Err(_)) => Err(quic_fallback_error),
        Err(_) => Err(protocol_error_with_peer(
            NetworkErrorCode::Timeout,
            "Direct connect window elapsed",
            "connect",
            &peer_id,
        )),
    }
}

/// Responder-side authenticated candidate checks started from an inbound
/// ConnectivityOffer. The normal accept loops remain available as the other
/// half of the simultaneous check; this task additionally punches toward the
/// initiator's advertised candidates within the same bounded window.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn connect_responder_direct(
    endpoint: Endpoint,
    candidates: Vec<Candidate>,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
    attempt_id: String,
    session_binding: String,
    state: Arc<RuntimeState>,
    connect_window: Duration,
) -> Result<ConnectedRoute, ProtocolError> {
    let (candidate_update_tx, candidate_updates) = watch::channel::<Option<Vec<Candidate>>>(None);
    drop(candidate_update_tx);
    let deadline = Instant::now() + connect_window;
    let (connection, crypto, admission) = connect_direct_candidates_with_crypto(
        endpoint,
        candidates,
        identity,
        expected_peer_public_key,
        peer_id,
        attempt_id,
        deadline,
        session_binding,
        state,
        None,
        DEFAULT_CONNECTION_CAPABILITY | CAPABILITY_UNRELIABLE_DATAGRAM,
        candidate_updates,
    )
    .await?;
    Ok(ConnectedRoute::Quic {
        connection,
        crypto,
        admission,
    })
}

#[allow(clippy::too_many_arguments)]
impl OutboundGenericConnector {
    async fn connect_generic_candidate(
        endpoint: SocketAddr,
        identity: Arc<DeviceIdentity>,
        expected_peer_public_key: [u8; 32],
        peer_id: String,
        session_binding: String,
        state: Arc<RuntimeState>,
        expected_session_id: SessionId,
        required_capabilities: u8,
        allow_websocket: bool,
        candidate_window: Duration,
    ) -> Result<AuthenticatedGenericRoute, ProtocolError> {
        let error_peer_id = peer_id.clone();
        let operation = async move {
            let mut transports = JoinSet::new();
            transports.spawn(Self::connect_tcp_route(
                endpoint,
                Arc::clone(&identity),
                expected_peer_public_key,
                peer_id.clone(),
                session_binding.clone(),
                Arc::clone(&state),
                expected_session_id,
                required_capabilities,
            ));
            if allow_websocket {
                transports.spawn(Self::connect_websocket_route(
                    endpoint,
                    identity,
                    expected_peer_public_key,
                    peer_id.clone(),
                    session_binding,
                    Arc::clone(&state),
                    expected_session_id,
                    required_capabilities,
                ));
            }

            let mut last_error = None;
            while let Some(result) = transports.join_next().await {
                match result {
                    Ok(Ok(route)) => {
                        let session_id = route.admission.session_id;
                        let remote_binding = route.crypto.remote_session_binding.clone();
                        let compatible = match route.scope.profile() {
                            Some(profile) => {
                                state
                                    .candidate_supports(
                                        &peer_id,
                                        session_id,
                                        profile,
                                        required_capabilities,
                                    )
                                    .await
                            }
                            None => false,
                        };
                        if !compatible {
                            route.scope.close().await;
                            state
                                .connection_sessions
                                .release_authenticated_session(
                                    &peer_id,
                                    session_id,
                                    &remote_binding,
                                )
                                .await;
                            last_error = Some(protocol_error_with_peer(
                                NetworkErrorCode::NoRoute,
                                "generic candidate no longer satisfies the requested capability",
                                "connect",
                                &peer_id,
                            ));
                            continue;
                        }
                        transports.abort_all();
                        return Ok(route);
                    }
                    Ok(Err(error)) => last_error = Some(error),
                    Err(error) => {
                        last_error = Some(protocol_error_with_peer(
                            NetworkErrorCode::IoError,
                            format!("generic transport task failed: {error}"),
                            "connect",
                            &peer_id,
                        ));
                    }
                }
            }
            Err(last_error.unwrap_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::NoRoute,
                    "generic candidate transport race produced no route",
                    "connect",
                    &peer_id,
                )
            }))
        };
        tokio::time::timeout(candidate_window, operation)
            .await
            .unwrap_or_else(|_| {
                Err(protocol_error_with_peer(
                    NetworkErrorCode::Timeout,
                    "generic candidate deadline elapsed",
                    "connect",
                    &error_peer_id,
                ))
            })
    }

    #[allow(clippy::too_many_arguments)]
    async fn connect_generic_candidates(
        candidates: Vec<Candidate>,
        identity: Arc<DeviceIdentity>,
        expected_peer_public_key: [u8; 32],
        peer_id: String,
        session_binding: String,
        state: Arc<RuntimeState>,
        expected_session_id: SessionId,
        required_capabilities: u8,
        allow_websocket: bool,
        deadline: Instant,
        mut candidate_updates: watch::Receiver<Option<Vec<Candidate>>>,
    ) -> Result<AuthenticatedGenericRoute, ProtocolError> {
        let mut pending = VecDeque::new();
        let mut started = HashSet::new();
        enqueue_candidates(&mut pending, &mut started, candidates);
        let mut attempts = JoinSet::new();
        let mut next_launch_at = Instant::now();
        let mut updates_closed = false;
        let mut last_error = None;

        loop {
            if !pending.is_empty() && Instant::now() >= next_launch_at {
                let candidate = pending.pop_front().expect("pending candidate");
                started.insert(candidate_attempt_key(&candidate));
                let candidate_window = deadline.saturating_duration_since(Instant::now());
                if candidate_window.is_zero() {
                    break;
                }
                let candidate_endpoint = candidate.endpoint;
                let candidate_identity = Arc::clone(&identity);
                let peer_id_for_task = peer_id.clone();
                let session_binding_for_task = session_binding.clone();
                let state_for_task = Arc::clone(&state);
                attempts.spawn(Self::connect_generic_candidate(
                    candidate_endpoint,
                    candidate_identity,
                    expected_peer_public_key,
                    peer_id_for_task,
                    session_binding_for_task,
                    state_for_task,
                    expected_session_id,
                    required_capabilities,
                    allow_websocket,
                    candidate_window,
                ));
                next_launch_at = Instant::now() + CANDIDATE_STAGGER;
                continue;
            }

            if attempts.is_empty() && pending.is_empty() && updates_closed {
                break;
            }

            tokio::select! {
                result = attempts.join_next(), if !attempts.is_empty() => {
                    match result {
                        Some(Ok(Ok(route))) => {
                            attempts.abort_all();
                            return Ok(route);
                        }
                        Some(Ok(Err(error))) => last_error = Some(error),
                        Some(Err(error)) => {
                            last_error = Some(protocol_error_with_peer(
                                NetworkErrorCode::IoError,
                                format!("generic candidate task failed: {error}"),
                                "connect",
                                &peer_id,
                            ));
                        }
                        None => {}
                    }
                }
                changed = candidate_updates.changed(), if !updates_closed => {
                    match changed {
                        Ok(()) => {
                            if let Some(update) = candidate_updates.borrow_and_update().clone() {
                                let had_pending = !pending.is_empty();
                                enqueue_candidates(&mut pending, &mut started, update);
                                if !had_pending && !pending.is_empty() {
                                    next_launch_at = Instant::now();
                                }
                            }
                        }
                        Err(_) => updates_closed = true,
                    }
                }
                _ = tokio::time::sleep_until(tokio::time::Instant::from_std(next_launch_at)), if !pending.is_empty() => {}
                _ = tokio::time::sleep_until(tokio::time::Instant::from_std(deadline)),
                    if attempts.is_empty() && pending.is_empty() =>
                {
                    break;
                }
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
    /// staged until ConnectionSessionStore sends its atomic commit signal.
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

        let (receiver, receiver_ready) = ConnectionReceiverSupervisor::generic_route_receiver_task(
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

    #[allow(clippy::too_many_arguments)]
    async fn connect_tcp_route(
        endpoint: SocketAddr,
        identity: Arc<DeviceIdentity>,
        expected_peer_public_key: [u8; 32],
        peer_id: String,
        session_binding: String,
        state: Arc<RuntimeState>,
        expected_session_id: SessionId,
        required_capabilities: u8,
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
            let e2ee_policy = state.e2ee_policy(&peer_id).await;
            let resolver_state = Arc::clone(&state);
            let resolver_peer_id = peer_id.clone();
            let (crypto, admission) = authenticate_initiator_with_policy(
                &mut connection,
                identity,
                &peer_id,
                expected_peer_public_key,
                &session_binding,
                e2ee_policy,
                move |authenticated_peer_id, remote_session_binding| {
                    let resolver_state = Arc::clone(&resolver_state);
                    let resolver_peer_id = resolver_peer_id.clone();
                    let remote_session_binding = remote_session_binding.to_string();
                    let authenticated_peer_id = authenticated_peer_id.to_string();
                    async move {
                        if authenticated_peer_id != resolver_peer_id {
                            return Err(crate::crypto_handshake::CryptoHandshakeError::Failed);
                        }
                        let admission = admit_single_winner(
                            &resolver_state,
                            &resolver_peer_id,
                            Some(expected_session_id),
                            &remote_session_binding,
                            required_capabilities,
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
            let scope = match Self::supervise_generic_route(
                Arc::clone(&state),
                &peer_id,
                admission.session_id,
                prepare_generic_route(connection),
            )
            .await
            {
                Ok(scope) => scope,
                Err(error) => {
                    state
                        .connection_sessions
                        .release_authenticated_session(
                            &peer_id,
                            admission.session_id,
                            &crypto.remote_session_binding,
                        )
                        .await;
                    return Err(error);
                }
            };
            let profile = scope.profile().expect("supervised TCP route profile");
            if !state
                .candidate_supports(
                    &peer_id,
                    admission.session_id,
                    profile,
                    required_capabilities,
                )
                .await
            {
                scope.close().await;
                state
                    .connection_sessions
                    .release_authenticated_session(
                        &peer_id,
                        admission.session_id,
                        &crypto.remote_session_binding,
                    )
                    .await;
                return Err(protocol_error_with_peer(
                    NetworkErrorCode::NoRoute,
                    "TCP candidate no longer satisfies the requested capability",
                    "connect",
                    &peer_id,
                ));
            }
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

    #[allow(clippy::too_many_arguments)]
    async fn connect_websocket_route(
        endpoint: SocketAddr,
        identity: Arc<DeviceIdentity>,
        expected_peer_public_key: [u8; 32],
        peer_id: String,
        session_binding: String,
        state: Arc<RuntimeState>,
        expected_session_id: SessionId,
        required_capabilities: u8,
    ) -> Result<AuthenticatedGenericRoute, ProtocolError> {
        let url = format!("ws://{endpoint}/V2/transport");
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
            let e2ee_policy = state.e2ee_policy(&peer_id).await;
            let resolver_state = Arc::clone(&state);
            let resolver_peer_id = peer_id.clone();
            let (crypto, admission) = authenticate_initiator_with_policy(
                &mut connection,
                identity,
                &peer_id,
                expected_peer_public_key,
                &session_binding,
                e2ee_policy,
                move |authenticated_peer_id, remote_session_binding| {
                    let resolver_state = Arc::clone(&resolver_state);
                    let resolver_peer_id = resolver_peer_id.clone();
                    let remote_session_binding = remote_session_binding.to_string();
                    let authenticated_peer_id = authenticated_peer_id.to_string();
                    async move {
                        if authenticated_peer_id != resolver_peer_id {
                            return Err(crate::crypto_handshake::CryptoHandshakeError::Failed);
                        }
                        let admission = admit_single_winner(
                            &resolver_state,
                            &resolver_peer_id,
                            Some(expected_session_id),
                            &remote_session_binding,
                            required_capabilities,
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
            let scope = match Self::supervise_generic_route(
                Arc::clone(&state),
                &peer_id,
                admission.session_id,
                prepare_generic_route(connection),
            )
            .await
            {
                Ok(scope) => scope,
                Err(error) => {
                    state
                        .connection_sessions
                        .release_authenticated_session(
                            &peer_id,
                            admission.session_id,
                            &crypto.remote_session_binding,
                        )
                        .await;
                    return Err(error);
                }
            };
            let profile = scope.profile().expect("supervised WebSocket route profile");
            if !state
                .candidate_supports(
                    &peer_id,
                    admission.session_id,
                    profile,
                    required_capabilities,
                )
                .await
            {
                scope.close().await;
                state
                    .connection_sessions
                    .release_authenticated_session(
                        &peer_id,
                        admission.session_id,
                        &crypto.remote_session_binding,
                    )
                    .await;
                return Err(protocol_error_with_peer(
                    NetworkErrorCode::NoRoute,
                    "WebSocket candidate no longer satisfies the requested capability",
                    "connect",
                    &peer_id,
                ));
            }
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
    data: Arc<RelayDataClient>,
    peer_id: &str,
    session_id: SessionId,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
) -> Result<(SessionCryptoMaterial, ConnectionAdmissionLease), ProtocolError> {
    let e2ee_policy = state.e2ee_policy(peer_id).await;
    if e2ee_policy != crate::crypto_handshake::path_handshake::E2eePolicy::Required {
        state.fail_session(peer_id, session_id).await;
        return Err(protocol_error_with_peer(
            NetworkErrorCode::AuthenticationFailed,
            "Relay paths require application E2EE",
            "connect",
            peer_id,
        ));
    }
    let session_token = session_id.wire_key();
    let (mut handshake, hello) =
        crate::crypto_handshake::RelayInitiatorHandshake::start_with_policy(
            identity,
            &session_token,
            e2ee_policy,
        )
        .map_err(|_| {
            protocol_error_with_peer(
                NetworkErrorCode::AuthenticationFailed,
                "Relay application E2EE handshake could not start",
                "connect",
                peer_id,
            )
        })?;
    let key = format!("{peer_id}/{session_token}");
    let (response_tx, mut response_rx) = mpsc::channel(3);
    let mut waiters = state.relay.crypto_waiters.write().await;
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
    let result = async {
        crate::relay::send_relay_crypto(
            &data,
            &session_token,
            crate::crypto_handshake::RELAY_CRYPTO_HELLO,
            &hello,
        )
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
        crate::relay::send_relay_crypto(
            &data,
            &session_token,
            crate::crypto_handshake::RELAY_CRYPTO_FINAL,
            &final_message,
        )
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
            .admit_authenticated_session_with_capability(
                peer_id,
                Some(session_id),
                &remote_session_binding,
                DEFAULT_CONNECTION_CAPABILITY,
            )
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
        crate::relay::send_relay_crypto(
            &data,
            &session_token,
            crate::crypto_handshake::RELAY_CRYPTO_ROOT_CONFIRM,
            &encrypted_confirm,
        )
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
        if material.local_session_binding != admission.session_id.wire_key() {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::AuthenticationFailed,
                "Relay application E2EE local Session binding is invalid",
                "connect",
                peer_id,
            ));
        }
        // RelayDataClient::connect_reservation() has already consumed the
        // reservation's PairReady lifecycle frame. PathHandshakeV2 metadata
        // and proof were authenticated inside this Noise exchange; there is
        // no independent wire handshake or extra business gate here.
        Ok((material, admission))
    }
    .await;
    state.relay.crypto_waiters.write().await.remove(&key);
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

impl InboundConnectionAcceptor {
    async fn admit_authenticated_inbound(
        state: &RuntimeState,
        peer_id: &str,
        capabilities: u8,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if !state.peers.read().await.contains_key(peer_id) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "authenticated inbound peer is not configured",
            )
            .into());
        }
        // A V2 registration may explicitly revoke the Direct route while
        // leaving the trust record intact for a later re-authorization.  Do
        // this check at inbound admission as well as outbound selection so a
        // peer cannot bypass route policy by dialing the native listener.
        if state
            .peer_route_authorizations
            .read()
            .await
            .get(peer_id)
            .is_some_and(|authorization| !authorization.direct)
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "direct route is not authorized for authenticated inbound peer",
            )
            .into());
        }
        let supervisor = state
            .peer_supervisors
            .get_or_create(peer_id)
            .map_err(|error| std::io::Error::other(error.to_string()))?;
        supervisor
            .admit_inbound_with_capabilities(true, capabilities)
            .map_err(|error| std::io::Error::other(error.to_string()))?;
        Ok(())
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
                        .lifecycle
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
                    if state
                        .peer_route_authorizations
                        .read()
                        .await
                        .get(&peer_id)
                        .is_some_and(|authorization| !authorization.direct)
                    {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::PermissionDenied,
                            "Direct route is not authorized for inbound peer",
                        )
                        .into());
                    }
                    let connection = session.connection.clone();
                    let e2ee_policy = state.e2ee_policy(&peer_id).await;
                    let binding_state = Arc::clone(&state);
                    let crypto = tokio::time::timeout(
                        PEER_CONNECT_TIMEOUT,
                        crate::crypto_handshake::respond_quic_with_policy(
                            &connection,
                            state
                                .lifecycle
                                .identity
                                .read()
                                .await
                                .clone()
                                .ok_or_else(|| {
                                    std::io::Error::other("runtime identity unavailable")
                                })?,
                            &state.trusted_peer_keys,
                            e2ee_policy,
                            move |authenticated_peer_id, remote_session_binding| {
                                let binding_state = Arc::clone(&binding_state);
                                let authenticated_peer_id = authenticated_peer_id.to_string();
                                let remote_session_binding = remote_session_binding.to_string();
                                async move {
                                    let admission = binding_state
                                        .admit_authenticated_session_with_capability(
                                            &authenticated_peer_id,
                                            None,
                                            &remote_session_binding,
                                            DEFAULT_CONNECTION_CAPABILITY
                                                | CAPABILITY_UNRELIABLE_DATAGRAM,
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
                    if session_id.wire_key() != crypto.local_session_binding {
                        return Err(std::io::Error::other(
                            "responder Session binding became stale",
                        )
                        .into());
                    }
                    let quic_profile = ConnectionProfile::for_route(RouteType::QuicDirect)
                        .expect("QUIC route profile");
                    if !state
                        .candidate_supports_required(&peer_id, session_id, quic_profile)
                        .await
                    {
                        state
                            .connection_sessions
                            .release_authenticated_session(
                                &peer_id,
                                session_id,
                                &crypto.remote_session_binding,
                            )
                            .await;
                        return Err(std::io::Error::other(
                            "inbound QUIC route lacks the requested capability",
                        )
                        .into());
                    }
                    attempted_session = Some((peer_id.clone(), session_id));
                    state
                        .connection_sessions
                        .finalize_authenticated_session(
                            &peer_id,
                            session_id,
                            &crypto.remote_session_binding,
                        )
                        .await
                        .map_err(|_| {
                            std::io::Error::other("Session was replaced during handshake")
                        })?;
                    install_admitted_crypto(&state, &peer_id, &admission, &crypto).await?;
                    let _previous_route = state
                        .attach_connection_for_session(
                            &peer_id,
                            Some(session_id),
                            connection.clone(),
                            RouteType::QuicDirect,
                        )
                        .await
                        .map_err(|_| std::io::Error::other("Session was closed"))?;
                    if state.connection_sessions.current_session_id(&peer_id).await
                        != Some(session_id)
                    {
                        return Err(std::io::Error::other("Session was closed").into());
                    }
                    Self::admit_authenticated_inbound(
                        &state,
                        &peer_id,
                        profile_capability_mask(quic_profile),
                    )
                    .await?;
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
                    ConnectionReceiverSupervisor::spawn_session_receivers(
                        Arc::clone(&state),
                        peer_id,
                        connection,
                        session_id,
                    );
                    Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
                }
                .await;
                if let Err(error) = result {
                    if let Some((peer_id, session_id)) = attempted_session {
                        state.fail_session(&peer_id, session_id).await;
                    }
                    tracing::warn!("Rejected inbound QUIC connection: {}", error);
                }
            });
        }
    }
}

/// Accepts TCP fallback sockets on the same numeric port as the QUIC UDP
/// endpoint. A socket is not admitted into a Session until the generic
/// Ed25519/Session-binding handshake succeeds.
///
/// §40：瞬态 accept 错误（EMFILE / ENOBUFS / aborted / reset 等）只记录并退避后继续，
/// 绝不终止 inbound TCP/WS 回退；只有致命错误（listener 已关闭）或任务被取消才退出。
impl InboundConnectionAcceptor {
    pub(crate) async fn accept_tcp_connections(listener: TcpListener, state: Arc<RuntimeState>) {
        Self::accept_tcp_loop(listener, state, Box::new(ListenerAccept)).await;
    }
}

/// §40 TCP accept 步骤的 future 类型（提取别名，避免 clippy type_complexity）。
type AcceptFuture<'a> =
    Pin<Box<dyn Future<Output = std::io::Result<(tokio::net::TcpStream, SocketAddr)>> + Send + 'a>>;

/// TCP fallback accept 步骤抽象（§40 可注入，便于测试注入瞬态错误）。
trait TcpAcceptStep: Send {
    fn accept<'a>(&'a mut self, listener: &'a TcpListener) -> AcceptFuture<'a>;
}

/// 生产 accept 步骤：直接委托给 tokio 的 `TcpListener::accept`。
struct ListenerAccept;

impl TcpAcceptStep for ListenerAccept {
    fn accept<'a>(
        &'a mut self,
        listener: &'a TcpListener,
    ) -> Pin<
        Box<dyn Future<Output = std::io::Result<(tokio::net::TcpStream, SocketAddr)>> + Send + 'a>,
    > {
        Box::pin(listener.accept())
    }
}

/// TCP fallback accept 核心循环。`accept` 步骤可注入，便于测试注入瞬态错误。
impl InboundConnectionAcceptor {
    async fn accept_tcp_loop(
        listener: TcpListener,
        state: Arc<RuntimeState>,
        mut accept: Box<dyn TcpAcceptStep>,
    ) {
        let mut backoff = TCP_ACCEPT_RETRY_BACKOFF;
        loop {
            let (stream, peer_address) = match accept.accept(&listener).await {
                Ok(connection) => connection,
                Err(error) => {
                    if Self::accept_error_is_fatal(&error) {
                        tracing::debug!(%error, "TCP fallback accept loop stopped");
                        return;
                    }
                    tracing::debug!(
                        %error,
                        "transient TCP fallback accept error; retrying after backoff"
                    );
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(TCP_ACCEPT_RETRY_BACKOFF_MAX);
                    continue;
                }
            };
            // 一次成功 accept 说明瞬态资源压力已缓解：复位退避。
            backoff = TCP_ACCEPT_RETRY_BACKOFF;
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
                if !looks_like_websocket
                    && !state.lifecycle.tcp_fallback_enabled.load(Ordering::Acquire)
                {
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
                        Self::accept_authenticated_generic(state, connection, peer_address).await
                    }
                    Err(error) => Err(error.into()),
                };
                if let Err(error) = result {
                    tracing::debug!(%error, "rejected inbound TCP fallback route");
                }
            });
        }
    }

    /// accept 错误是否致命：仅 listener 已关闭（fd 失效）视为致命；其余（EMFILE / ENOBUFS /
    /// aborted / reset / interrupted 等）都是瞬态错误，应退避重试。
    fn accept_error_is_fatal(error: &std::io::Error) -> bool {
        matches!(
            error.kind(),
            std::io::ErrorKind::InvalidInput | std::io::ErrorKind::Unsupported
        )
    }

    async fn accept_authenticated_generic(
        state: Arc<RuntimeState>,
        mut connection: GenericConnection,
        peer_address: SocketAddr,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let identity = state
            .lifecycle
            .identity
            .read()
            .await
            .clone()
            .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?;
        let candidate_capabilities = profile_capability_mask(connection.profile());
        let binding_state = Arc::clone(&state);
        let authenticated = tokio::time::timeout(
            GENERIC_ROUTE_CONNECT_TIMEOUT,
            authenticate_responder_auto_policy(
                &mut connection,
                identity,
                &state.trusted_peer_keys,
                move |peer_id, remote_session_binding| {
                    let binding_state = Arc::clone(&binding_state);
                    let peer_id = peer_id.to_string();
                    let remote_session_binding = remote_session_binding.to_string();
                    async move {
                        if !binding_state.peers.read().await.contains_key(&peer_id)
                            || binding_state
                                .peer_route_authorizations
                                .read()
                                .await
                                .get(&peer_id)
                                .is_some_and(|authorization| !authorization.direct)
                        {
                            return Err(crate::crypto_handshake::CryptoHandshakeError::Failed);
                        }
                        let admission = binding_state
                            .admit_authenticated_session_with_capability(
                                &peer_id,
                                None,
                                &remote_session_binding,
                                candidate_capabilities,
                            )
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
        if state.e2ee_policy(&peer_id).await != crypto.e2ee_policy {
            state
                .connection_sessions
                .release_authenticated_session(
                    &peer_id,
                    admission.session_id,
                    &crypto.remote_session_binding,
                )
                .await;
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "generic route E2EE policy does not match peer configuration",
            )
            .into());
        }
        tracing::debug!(%session_binding, "generic route Session binding authenticated");
        if admission.session_id.wire_key() != crypto.local_session_binding {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "generic route Session binding became stale",
            )
            .into());
        }
        let session_id = admission.session_id;
        let profile = connection.profile();
        if !state
            .candidate_supports_required(&peer_id, session_id, profile)
            .await
        {
            state
                .connection_sessions
                .release_authenticated_session(&peer_id, session_id, &crypto.remote_session_binding)
                .await;
            return Err(std::io::Error::other(
                "generic route no longer satisfies the requested capability",
            )
            .into());
        }
        state
            .connection_sessions
            .finalize_authenticated_session(&peer_id, session_id, &crypto.remote_session_binding)
            .await
            .map_err(|_| std::io::Error::other("Session was replaced during handshake"))?;
        install_admitted_crypto(&state, &peer_id, &admission, &crypto).await?;
        let attempted_peer_id = peer_id.clone();
        let result = async {
        let mut scope = OutboundGenericConnector::supervise_generic_route(
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
        let _previous_route = match state
            .attach_generic_route_for_session(&peer_id, Some(session_id), &mut scope)
            .await
        {
            Ok(previous_route) => previous_route,
            Err(_) => {
                scope.close().await;
                return Err(std::io::Error::other("TCP route lost its Session race").into());
            }
        };
        Self::admit_authenticated_inbound(&state, &peer_id, profile_capability_mask(profile))
            .await?;
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
            state.fail_session(&attempted_peer_id, session_id).await;
        }
        result
    }
}

/// 接受一个已认证对端的双向流。共享的 `accept_bi` 循环按首 4 字节路由：
/// 文件 offer (`SMFT`) 走 `handle_incoming_file_after_offer`，ReliableStream
/// 前导 (`SMSS`) 走 `crate::stream`（§17）。首 4 字节被消耗后，
/// 文件 offer 的其余字段由 `read_file_offer_after_magic` 续读，因此文件数据
/// 路径与原 `read_file_offer` 完全一致。
impl ConnectionReceiverSupervisor {
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
                    let inbound_connection = connection.clone();
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
                                    let path_lease = match state
                                        .acquire_path_lease_for_connection(
                                            &peer_id,
                                            &inbound_connection,
                                            crate::connect::CAPABILITY_RELIABLE_STREAM,
                                        )
                                        .await
                                    {
                                        Ok(lease) => lease,
                                        Err(error) => {
                                            tracing::debug!(
                                                peer_id = %peer_id,
                                                error = %error,
                                                "rejected QUIC file offer without its carrier path"
                                            );
                                            return;
                                        }
                                    };
                                    crate::transfer::handle_incoming_file_after_offer(
                                        peer_id, send, receive, manifest, state, path_lease,
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
                                        state,
                                        peer_id,
                                        stream_id,
                                        service,
                                        inbound_connection,
                                        send,
                                        receive,
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
                    Self::handle_connection_disconnect(&state, &peer_id, &connection).await;
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
                    Self::handle_connection_disconnect(&state, &peer_id, &connection).await;
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
            Self::receive_file_streams(
                peer_id.clone(),
                connection.clone(),
                Arc::clone(&state),
                session_id,
            ),
        );
        let _ = supervisor.spawn_session(
            session_id.wire_key(),
            "channel-receiver",
            Self::receive_channel_streams(peer_id, connection, Arc::clone(&state), session_id),
        );
    }
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

impl ConnectionReceiverSupervisor {
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
                            Self::notify_generic_route_loss(&state, &peer_id, route_id, session_id).await;
                        }
                        return;
                    }
                    frame = inbound.recv() => {
                        let Some(frame) = frame else {
                            route_stop.cancel();
                            if !stopping.load(Ordering::Acquire) {
                                Self::notify_generic_route_loss(&state, &peer_id, route_id, session_id).await;
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
                                crate::stream::InboundPath::Generic(route_id),
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
        session_id: SessionId,
    ) {
        if state
            .close_direct_path(peer_id, Some(route_id))
            .await
            .is_none()
        {
            return;
        }
        Self::finalize_path_loss(state, peer_id, session_id).await;
    }

    /// §18/§35：reservation 数据面断开即销毁 Relay ConnectionSession。仅当当前
    /// Session 的 route 仍由 `data` 承载时才拆除，并发布类型化断开状态。
    pub(crate) async fn teardown_relay_route(
        state: &Arc<RuntimeState>,
        peer_id: &str,
        data: &Arc<RelayDataClient>,
    ) {
        if !state.path_is_current_relay_data(peer_id, data).await {
            return;
        }
        let Some(session_id) = state.connection_sessions.current_session_id(peer_id).await else {
            return;
        };
        if state.close_relay_path(peer_id, Some(data)).await.is_none() {
            return;
        }
        Self::finalize_path_loss(state, peer_id, session_id).await;
    }

    async fn handle_connection_disconnect(
        state: &Arc<RuntimeState>,
        peer_id: &str,
        connection: &Connection,
    ) {
        let Some(session_id) = state.connection_sessions.current_session_id(peer_id).await else {
            return;
        };
        if state
            .close_direct_path_for_connection(peer_id, connection)
            .await
            .is_none()
        {
            return;
        }
        Self::finalize_path_loss(state, peer_id, session_id).await;
    }

    async fn finalize_path_loss(state: &Arc<RuntimeState>, peer_id: &str, session_id: SessionId) {
        if state.connection_sessions.current_session_id(peer_id).await != Some(session_id)
            || state.path_is_connected(peer_id).await
        {
            // Direct/Relay are independent physical slots. Losing one does not
            // invalidate the Session while the other remains usable.
            return;
        }
        if !state
            .connection_sessions
            .retire_session(peer_id, session_id)
            .await
        {
            return;
        }
        // This function is commonly called by a session-scoped receiver task.
        // Joining that same task group inline would await the current task and
        // deadlock before the public Disconnected event can be emitted.
        let cleanup_state = Arc::clone(state);
        let cleanup_peer_id = peer_id.to_string();
        let _ = state
            .task_supervisor
            .spawn_runtime("path-loss-cleanup", async move {
                cleanup_state
                    .cancel_session_tasks(&cleanup_peer_id, session_id)
                    .await;
            });
        if let Ok(supervisor) = state.peer_supervisors.get_or_create(peer_id) {
            supervisor.path_lost();
        }
        emit_peer_state(
            &state.event_tx,
            peer_id,
            PeerConnectionState::Disconnected,
            RouteType::Unspecified,
            None,
        );
        // transport-network v2（§18/§35）：最后一条 transport 丢失即销毁
        // ConnectionSession，不自动重连（无 RECONNECTING）。业务下次 `connect()`
        // 会重新 Resolve，并按需新建连接（新 SessionId + 新 Noise root）。
    }
}

#[cfg(test)]
#[path = "tests/peer.rs"]
mod tests;
