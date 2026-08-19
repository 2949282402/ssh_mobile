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
    profile_capability_mask, CAPABILITY_RELIABLE_MESSAGE, CAPABILITY_UNRELIABLE_DATAGRAM,
    DEFAULT_CONNECTION_CAPABILITY,
};
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
    pub(crate) allow_websocket: bool,
    /// Candidate snapshots arriving from the authenticated ConnectivityAnswer
    /// while the bounded Direct race is still running.
    pub(crate) candidate_updates: watch::Receiver<Option<Vec<Candidate>>>,
}

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
                        DEFAULT_CONNECTION_CAPABILITY | CAPABILITY_UNRELIABLE_DATAGRAM,
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
        .candidate_supports_required(&peer_id, admission.session_id, quic_profile)
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
        connect_generic_candidates(
            generic_candidates,
            identity,
            expected_peer_public_key,
            peer_id.clone(),
            session_binding,
            state,
            session_id,
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
async fn connect_generic_candidate(
    endpoint: SocketAddr,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
    session_binding: String,
    state: Arc<RuntimeState>,
    expected_session_id: SessionId,
    allow_websocket: bool,
    candidate_window: Duration,
) -> Result<AuthenticatedGenericRoute, ProtocolError> {
    let error_peer_id = peer_id.clone();
    let operation = async move {
        let mut transports = JoinSet::new();
        transports.spawn(connect_tcp_route(
            endpoint,
            Arc::clone(&identity),
            expected_peer_public_key,
            peer_id.clone(),
            session_binding.clone(),
            Arc::clone(&state),
            expected_session_id,
        ));
        if allow_websocket {
            transports.spawn(connect_websocket_route(
                endpoint,
                identity,
                expected_peer_public_key,
                peer_id.clone(),
                session_binding,
                Arc::clone(&state),
                expected_session_id,
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
                                .candidate_supports_required(&peer_id, session_id, profile)
                                .await
                        }
                        None => false,
                    };
                    if !compatible {
                        route.scope.close().await;
                        state
                            .connection_sessions
                            .release_authenticated_session(&peer_id, session_id, &remote_binding)
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
            attempts.spawn(connect_generic_candidate(
                candidate_endpoint,
                candidate_identity,
                expected_peer_public_key,
                peer_id_for_task,
                session_binding_for_task,
                state_for_task,
                expected_session_id,
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
                        DEFAULT_CONNECTION_CAPABILITY,
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
        let scope = match supervise_generic_route(
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
            .candidate_supports_required(&peer_id, admission.session_id, profile)
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

async fn connect_websocket_route(
    endpoint: SocketAddr,
    identity: Arc<DeviceIdentity>,
    expected_peer_public_key: [u8; 32],
    peer_id: String,
    session_binding: String,
    state: Arc<RuntimeState>,
    expected_session_id: SessionId,
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
                        CAPABILITY_RELIABLE_MESSAGE,
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
        let scope = match supervise_generic_route(
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
            .candidate_supports_required(&peer_id, admission.session_id, profile)
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
                let e2ee_policy = state.e2ee_policy(&peer_id).await;
                let binding_state = Arc::clone(&state);
                let crypto =
                    tokio::time::timeout(
                        PEER_CONNECT_TIMEOUT,
                        crate::crypto_handshake::respond_quic_with_policy(
                            &connection,
                            state.identity.read().await.clone().ok_or_else(|| {
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
                    return Err(
                        std::io::Error::other("responder Session binding became stale").into(),
                    );
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
                    .map_err(|_| std::io::Error::other("Session was replaced during handshake"))?;
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
                if state.connection_sessions.current_session_id(&peer_id).await != Some(session_id)
                {
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
                    state.fail_session(&peer_id, session_id).await;
                }
                tracing::warn!("Rejected inbound QUIC connection: {}", error);
            }
        });
    }
}

/// Accepts TCP fallback sockets on the same numeric port as the QUIC UDP
/// endpoint. A socket is not admitted into a Session until the generic
/// Ed25519/Session-binding handshake succeeds.
///
/// §40：瞬态 accept 错误（EMFILE / ENOBUFS / aborted / reset 等）只记录并退避后继续，
/// 绝不终止 inbound TCP/WS 回退；只有致命错误（listener 已关闭）或任务被取消才退出。
pub(crate) async fn accept_tcp_connections(listener: TcpListener, state: Arc<RuntimeState>) {
    accept_tcp_loop(listener, state, Box::new(ListenerAccept)).await;
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
                if accept_error_is_fatal(&error) {
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
                    if !binding_state.peers.read().await.contains_key(&peer_id) {
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
    session_id: SessionId,
) {
    if state
        .close_direct_path(peer_id, Some(route_id))
        .await
        .is_none()
    {
        return;
    }
    finalize_path_loss(state, peer_id, session_id).await;
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
    finalize_path_loss(state, peer_id, session_id).await;
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
    finalize_path_loss(state, peer_id, session_id).await;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::generic_auth::authenticate_responder;
    use crate::runtime::ConnectDecision;
    use network_transport::{TcpTransport, Transport, WebSocketTransport};
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
        match state
            .begin_connect(peer_id, crate::connect::DEFAULT_CONNECTION_CAPABILITY)
            .await
        {
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
            .attach_generic_route_for_session("generic-close-peer", Some(session_id), &mut scope)
            .await
            .expect("attach GenericRoute");

        let route = state
            .close_transport_path("generic-close-peer")
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
            .attach_generic_route_for_session(peer_id, Some(session_id), &mut first_scope)
            .await
            .expect("attach first GenericRoute");

        let (second_connection, _second_server) = generic_connection_pair().await;
        let mut second_scope =
            started_generic_scope(&state, peer_id, session_id, second_connection).await;
        assert!(state
            .attach_generic_route_for_session(peer_id, Some(session_id), &mut second_scope)
            .await
            .is_err());
        second_scope.close().await;

        let closed_route = state
            .close_transport_path(peer_id)
            .await
            .expect("close Session");
        closed_route.close().await;
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
            .connection_sessions
            .admit_authenticated_session(peer_id, Some(old_session_id), &old_remote_binding)
            .await
            .expect("seed the old remote Session binding");
        state
            .connection_sessions
            .finalize_authenticated_session(peer_id, old_session_id, &old_remote_binding)
            .await
            .expect("finalize the old remote Session binding");

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
            .attach_generic_route_for_session(peer_id, Some(new_session_id), &mut scope)
            .await
            .expect("attach outbound GenericRoute to replacement Session");

        wait_for_active_task_count(&state.task_supervisor, 2).await;
        assert_eq!(
            state.connection_sessions.current_session_id(peer_id).await,
            Some(new_session_id)
        );

        let payload = b"replacement-route-still-alive";
        timeout(
            Duration::from_secs(1),
            state.path_send_channel_frame(peer_id, "", GenericFrameKind::DataMessage, payload),
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

        let closed_route = state
            .close_transport_path(peer_id)
            .await
            .expect("close replacement GenericRoute");
        closed_route.close().await;
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
        state
            .close_transport_path("generic-failed-attach-peer")
            .await;
        let _ = state
            .connection_sessions
            .retire_session("generic-failed-attach-peer", session_id)
            .await;
        assert!(state
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

    #[tokio::test]
    async fn losing_candidate_admit_never_replaces_attached_winner_session() {
        // §18/§40：race 两个 candidate 时，winner 已 attach route（Session Connected）后，
        // loser 迟到的 admit 不得触发 ReplaceWithNew——否则拆掉刚挂载的 winning route，
        // 双方都掉线。
        let state = new_test_state().await;
        let peer_id = "candidate-race-peer";
        let session_id = started_session(&state, peer_id).await;
        let binding = "11".repeat(16);

        // winner：第一次 admit 成功，保持 in-flight Session（Initialize）。
        let winner = admit_single_winner(
            &state,
            peer_id,
            Some(session_id),
            &binding,
            DEFAULT_CONNECTION_CAPABILITY,
        )
        .await
        .expect("winner admission should succeed");
        assert_eq!(winner.session_id, session_id);

        // winner 挂载一条 generic route（Session → Connected）。
        let (connection, _server) = generic_connection_pair().await;
        let mut scope = started_generic_scope(&state, peer_id, session_id, connection).await;
        state
            .attach_generic_route_for_session(peer_id, Some(session_id), &mut scope)
            .await
            .expect("attach winner generic route");
        assert!(state.path_is_connected(peer_id).await);

        // loser：同 (peer, expected_session_id) 的迟到 admit 必须被拒绝，绝不替换。
        assert!(
            admit_single_winner(
                &state,
                peer_id,
                Some(session_id),
                &binding,
                DEFAULT_CONNECTION_CAPABILITY
            )
            .await
            .is_err(),
            "losing candidate must not trigger a Session replacement"
        );

        // winner 的 Session 与 route 仍然存活（无 disconnect）。
        assert_eq!(
            state.connection_sessions.current_session_id(peer_id).await,
            Some(session_id)
        );
        assert!(state.path_is_connected(peer_id).await);

        let closed_route = state
            .close_transport_path(peer_id)
            .await
            .expect("close Session");
        closed_route.close().await;
        assert_eq!(state.task_supervisor.active_count(), 0);
    }

    #[tokio::test]
    async fn tcp_fallback_accept_loop_survives_transient_accept_errors() {
        // §40：瞬态 accept 错误（EMFILE/aborted/reset 等）只退避重试，不得终止 inbound
        // TCP/WS 回退；后续真实连接仍被接受。
        let state = new_test_state().await;
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind accept listener");
        let address = listener.local_addr().expect("accept listener address");
        let loop_task = tokio::spawn(accept_tcp_loop(
            listener,
            Arc::clone(&state),
            Box::new(InjectOnceTransientAcceptError { injected: true }),
        ));
        // 等循环处理注入的错误 + 退避。
        tokio::time::sleep(Duration::from_millis(150)).await;

        // 建立一条真实连接：循环必须继续 accept 并派生 handshake 任务。
        let _client = TcpStream::connect(address)
            .await
            .expect("connect after transient accept error");
        timeout(Duration::from_secs(2), async {
            loop {
                if state.task_supervisor.active_count() >= 1 {
                    return;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("accept loop did not process the connection after the transient error");
        loop_task.abort();
    }

    #[tokio::test]
    async fn tcp_fallback_accept_loop_exits_on_fatal_listener_error() {
        // §40：只有致命错误（listener 已关闭 / fd 失效）才终止 accept 循环。
        let state = new_test_state().await;
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind accept listener");
        let outcome = tokio::time::timeout(
            Duration::from_secs(1),
            accept_tcp_loop(listener, Arc::clone(&state), Box::new(FatalAcceptError)),
        )
        .await;
        assert!(
            outcome.is_ok(),
            "fatal accept errors must terminate the TCP fallback accept loop"
        );
    }

    /// 注入一次瞬态 accept 错误，之后委托真实 `TcpListener::accept` 的测试 accept 步骤。
    struct InjectOnceTransientAcceptError {
        injected: bool,
    }

    impl TcpAcceptStep for InjectOnceTransientAcceptError {
        fn accept<'a>(
            &'a mut self,
            listener: &'a TcpListener,
        ) -> Pin<
            Box<
                dyn Future<Output = std::io::Result<(tokio::net::TcpStream, SocketAddr)>>
                    + Send
                    + 'a,
            >,
        > {
            if self.injected {
                self.injected = false;
                Box::pin(async {
                    Err(std::io::Error::new(
                        std::io::ErrorKind::ConnectionAborted,
                        "injected transient accept error",
                    ))
                })
            } else {
                Box::pin(listener.accept())
            }
        }
    }

    /// 始终返回致命 accept 错误的测试 accept 步骤（listener 已关闭）。
    struct FatalAcceptError;

    impl TcpAcceptStep for FatalAcceptError {
        fn accept<'a>(
            &'a mut self,
            _listener: &'a TcpListener,
        ) -> Pin<
            Box<
                dyn Future<Output = std::io::Result<(tokio::net::TcpStream, SocketAddr)>>
                    + Send
                    + 'a,
            >,
        > {
            Box::pin(async {
                Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "listener closed",
                ))
            })
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn generic_candidate_races_tcp_and_websocket_concurrently() {
        let state = new_test_state().await;
        let peer_id = "generic-race-peer";
        let local_peer_id = "generic-race-local";
        let local_identity = Arc::new(DeviceIdentity::from_private_keys(
            local_peer_id.to_string(),
            [81u8; 32],
            [91u8; 32],
        ));
        let remote_identity = Arc::new(DeviceIdentity::from_private_keys(
            peer_id.to_string(),
            [82u8; 32],
            [92u8; 32],
        ));
        let remote_public_key = remote_identity.public_identity_key().to_bytes();
        let session_id = match state
            .begin_connect(peer_id, crate::connect::CAPABILITY_RELIABLE_MESSAGE)
            .await
        {
            ConnectDecision::Started(session_id) => session_id,
            decision => panic!("unexpected Session decision: {decision:?}"),
        };
        let (endpoint, release_tx, responder_task) =
            spawn_mixed_generic_responder(peer_id, local_peer_id).await;
        let route = tokio::time::timeout(
            Duration::from_secs(3),
            connect_generic_candidate(
                endpoint,
                local_identity,
                remote_public_key,
                peer_id.to_string(),
                session_id.wire_key(),
                Arc::clone(&state),
                session_id,
                true,
                Duration::from_secs(1),
            ),
        )
        .await
        .expect("TCP/WS candidate race should finish within the candidate window")
        .expect("WebSocket should win while TCP is blackholed");

        let AuthenticatedGenericRoute { scope, .. } = route;
        assert_eq!(
            scope
                .profile()
                .expect("staged generic route profile")
                .transport(),
            RouteTransport::WebSocket,
            "WebSocket must race TCP instead of waiting for TCP to fail"
        );
        scope.close().await;
        state.cancel_session_tasks(peer_id, session_id).await;
        let _ = release_tx.send(());
        responder_task
            .await
            .expect("mixed generic responder should exit");
        state.task_supervisor.cancel_root();
        state.task_supervisor.shutdown().await;
    }

    #[test]
    fn candidate_snapshot_requeues_changed_endpoint_and_drops_deleted_pending() {
        let mut old = Candidate::new(
            "192.0.2.10:41000".parse().expect("old endpoint"),
            CandidateKind::Lan,
            "same-interface".into(),
        )
        .with_generation(1);
        old.candidate_id = "same-candidate".into();
        let mut deleted = Candidate::new(
            "192.0.2.11:41001".parse().expect("deleted endpoint"),
            CandidateKind::Lan,
            "deleted-interface".into(),
        );
        deleted.candidate_id = "deleted-candidate".into();

        let mut pending = VecDeque::new();
        let mut started = HashSet::new();
        enqueue_candidates(&mut pending, &mut started, vec![old, deleted]);
        let launched = pending.pop_front().expect("old candidate should be queued");
        started.insert(candidate_attempt_key(&launched));

        let mut updated = Candidate::new(
            "198.51.100.10:42000".parse().expect("updated endpoint"),
            CandidateKind::Lan,
            "same-interface".into(),
        )
        .with_generation(2);
        updated.candidate_id = "same-candidate".into();
        enqueue_candidates(&mut pending, &mut started, vec![updated.clone()]);

        assert_eq!(pending.len(), 1, "the updated candidate should be requeued");
        let queued = pending
            .front()
            .expect("updated candidate should remain pending");
        assert_eq!(queued.candidate_id, updated.candidate_id);
        assert_eq!(queued.endpoint, updated.endpoint);
        assert_eq!(queued.generation, updated.generation);
        assert!(!started.contains(&candidate_attempt_key(&updated)));

        enqueue_candidates(&mut pending, &mut started, vec![updated]);
        assert_eq!(
            pending.len(),
            1,
            "the same snapshot must not duplicate a pending candidate"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn late_quic_candidate_arriving_before_direct_deadline_can_win() {
        let client_state = new_test_state().await;
        let server_state = new_test_state().await;
        let local_peer_id = "late-candidate-local";
        let peer_id = "late-candidate-peer";

        let local_identity = Arc::new(DeviceIdentity::from_private_keys(
            local_peer_id.to_string(),
            [61u8; 32],
            [71u8; 32],
        ));
        let remote_identity = Arc::new(DeviceIdentity::from_private_keys(
            peer_id.to_string(),
            [62u8; 32],
            [72u8; 32],
        ));
        let remote_public_key = remote_identity.public_identity_key().to_bytes();
        *client_state.identity.write().await = Some(Arc::clone(&local_identity));
        *server_state.identity.write().await = Some(remote_identity);
        server_state.trusted_peer_keys.write().await.insert(
            local_peer_id.to_string(),
            local_identity.public_identity_key().to_bytes(),
        );

        let server_endpoint = QuicEndpointManager::new(
            "127.0.0.1:0".parse().expect("server bind address"),
            Arc::new(PathManager::new()),
        )
        .expect("create server QUIC endpoint")
        .endpoint;
        let server_address = server_endpoint
            .local_addr()
            .expect("server endpoint address");
        server_state
            .task_supervisor
            .spawn_runtime(
                "late-candidate-quic-accept",
                accept_connections(server_endpoint.clone(), Arc::clone(&server_state)),
            )
            .expect("start server QUIC accept loop");

        let client_endpoint = QuicEndpointManager::new(
            "127.0.0.1:0".parse().expect("client bind address"),
            Arc::new(PathManager::new()),
        )
        .expect("create client QUIC endpoint")
        .endpoint;
        let session_id = started_session(&client_state, peer_id).await;

        // C1 never responds. The Direct phase must keep its coordination receiver alive
        // long enough for the authenticated ConnectivityAnswer to add C2.
        let blackhole = std::net::UdpSocket::bind("127.0.0.1:0").expect("bind UDP blackhole");
        let blackhole_address = blackhole.local_addr().expect("blackhole address");
        let first_candidate = Candidate::new(
            blackhole_address,
            CandidateKind::Lan,
            "late-candidate-c1".into(),
        );
        let reachable_candidate = Candidate::new(
            server_address,
            CandidateKind::Lan,
            "late-candidate-c2".into(),
        );
        let (candidate_update_tx, candidate_updates) = watch::channel(None);
        let update_task = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            candidate_update_tx
                .send(Some(vec![reachable_candidate]))
                .expect("late candidate update receiver should remain alive");
        });

        let attempt = DirectRouteAttempt {
            state: Arc::clone(&client_state),
            endpoint: client_endpoint.clone(),
            candidates: vec![first_candidate],
            identity: local_identity,
            expected_peer_public_key: remote_public_key,
            peer_id: peer_id.to_string(),
            session_binding: session_id.wire_key(),
            session_id,
            attempt_id: "late-quic-candidate-test".into(),
            connect_window: Duration::from_secs(2),
            allow_websocket: true,
            candidate_updates,
        };
        let route =
            tokio::time::timeout(Duration::from_secs(4), connect_direct_or_generic(attempt))
                .await
                .expect("late QUIC candidate should finish within Direct window")
                .expect("late reachable QUIC candidate should win Direct race");
        update_task
            .await
            .expect("candidate update task should finish");

        let ConnectedRoute::Quic { connection, .. } = route else {
            panic!("expected the late candidate to produce a QUIC route");
        };
        connection.close(quinn::VarInt::from_u32(0), b"test complete");

        client_state.cancel_session_tasks(peer_id, session_id).await;
        if let Some(server_session_id) = server_state
            .connection_sessions
            .current_session_id(local_peer_id)
            .await
        {
            server_state
                .cancel_session_tasks(local_peer_id, server_session_id)
                .await;
        }
        client_endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
        server_endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
        client_state.task_supervisor.cancel_root();
        server_state.task_supervisor.cancel_root();
        client_state.task_supervisor.shutdown().await;
        server_state.task_supervisor.shutdown().await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn generic_direct_route_gets_budget_when_quic_candidates_are_blackholed() {
        // §15/§37：QUIC 候选被黑洞（UDP socket 收包但不响应）时不得耗尽整个 Direct 窗口——
        // generic（TCP/WebSocket）候选应拿到自己的时间片；仅 TCP 可达的 peer 在窗口内走
        // generic 成功，而不是直接超时回退 Relay。
        let state = new_test_state().await;
        let peer_id = "generic-budget-peer";
        let local_peer_id = "generic-budget-local";

        // QUIC 黑洞：绑定 UDP socket 但从不读取/响应 → QUIC candidate 挂到子预算超时。
        let blackhole = std::net::UdpSocket::bind("127.0.0.1:0").expect("bind UDP blackhole");
        let blackhole_address = blackhole.local_addr().expect("blackhole address");

        // 可用的 generic（TCP）路由。
        let (responder_address, release_tx, responder_task) =
            spawn_tcp_generic_responder(peer_id, local_peer_id).await;

        // 发起方 QUIC endpoint（仅用于发起 candidate 连接）。
        let endpoint_manager = network_quic::QuicEndpointManager::new(
            "127.0.0.1:0".parse().expect("wildcard address"),
            Arc::new(PathManager::new()),
        )
        .expect("create QUIC endpoint");
        let endpoint = endpoint_manager.endpoint;
        let endpoint_for_cleanup = endpoint.clone();

        let local_identity = Arc::new(DeviceIdentity::from_private_keys(
            local_peer_id.to_string(),
            [41u8; 32],
            [51u8; 32],
        ));
        let remote_identity = Arc::new(DeviceIdentity::from_private_keys(
            peer_id.to_string(),
            [42u8; 32],
            [52u8; 32],
        ));
        let remote_public_key = remote_identity.public_identity_key().to_bytes();
        let session_id = started_session(&state, peer_id).await;

        let candidates = vec![
            Candidate::new(
                blackhole_address,
                CandidateKind::Lan,
                "test-blackhole".into(),
            ),
            Candidate::new(responder_address, CandidateKind::Lan, "test-tcp".into()),
        ];
        let (candidate_update_tx, candidate_updates) = watch::channel(None);
        drop(candidate_update_tx);

        let attempt = DirectRouteAttempt {
            state: Arc::clone(&state),
            endpoint,
            candidates,
            identity: local_identity,
            expected_peer_public_key: remote_public_key,
            peer_id: peer_id.to_string(),
            session_binding: session_id.wire_key(),
            session_id,
            attempt_id: "generic-budget-test".into(),
            connect_window: crate::connect::DIRECT_CONNECT_WINDOW,
            // This fixture intentionally exposes only TCP; transport racing has
            // a separate regression test below.
            allow_websocket: false,
            candidate_updates,
        };

        // QUIC 被黑洞耗掉自己的子预算后，generic 用窗口剩余预算走 TCP 成功。
        let route = tokio::time::timeout(
            Duration::from_secs(5),
            connect_direct_or_generic(attempt),
        )
        .await
        .expect("direct phase must finish within the window")
        .expect("peer reachable only via TCP must succeed via the generic path within the window");

        let ConnectedRoute::Generic(generic) = route else {
            panic!("expected a generic route for a TCP-only reachable peer");
        };
        generic.scope.close().await;

        let _ = release_tx.send(());
        responder_task.await.expect("generic responder should exit");
        endpoint_for_cleanup.close(quinn::VarInt::from_u32(0), b"test complete");
    }

    /// 在同一个 endpoint 上把 TCP 连接保持为黑洞，并为 WebSocket 连接完成认证。
    /// 这样可以验证同一个 candidate 内两种 generic transport 会并发 race。
    async fn spawn_mixed_generic_responder(
        peer_id: &str,
        local_peer_id: &str,
    ) -> (SocketAddr, oneshot::Sender<()>, tokio::task::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind mixed generic responder");
        let address = listener.local_addr().expect("mixed responder address");
        let peer_id = peer_id.to_string();
        let local_peer_id = local_peer_id.to_string();
        let remote_identity = Arc::new(DeviceIdentity::from_private_keys(
            peer_id, [82u8; 32], [92u8; 32],
        ));
        let local_public_key =
            DeviceIdentity::from_private_keys(local_peer_id.clone(), [81u8; 32], [91u8; 32])
                .public_identity_key()
                .to_bytes();
        let (release_tx, release_rx) = oneshot::channel();
        let responder_task = tokio::spawn(async move {
            let trusted_peer_keys =
                tokio::sync::RwLock::new(HashMap::from([(local_peer_id, local_public_key)]));
            let mut release_rx = release_rx;
            let mut raw_connections = Vec::new();
            let mut websocket_authenticated = false;
            loop {
                tokio::select! {
                    _ = &mut release_rx => break,
                    accepted = listener.accept() => {
                        let (stream, _) = accepted.expect("accept mixed generic connection");
                        let mut probe = [0u8; 4];
                        let looks_like_websocket = tokio::time::timeout(
                            Duration::from_secs(1),
                            stream.peek(&mut probe),
                        )
                        .await
                        .ok()
                        .and_then(Result::ok)
                        .is_some_and(|length| length == probe.len() && &probe == b"GET ");
                        if looks_like_websocket {
                            let socket = WebSocketTransport::accept(stream)
                                .await
                                .expect("accept WebSocket transport");
                            let mut connection = GenericConnection::from_transport(
                                Transport::WebSocket(Box::new(socket)),
                            );
                            authenticate_responder(
                                &mut connection,
                                Arc::clone(&remote_identity),
                                &trusted_peer_keys,
                                |_authenticated_peer_id, _remote_session_binding| async move {
                                    Ok(("33".repeat(16), ()))
                                },
                            )
                            .await
                            .expect("authenticate WebSocket responder");
                            websocket_authenticated = true;
                        } else {
                            // TCP has connected but the responder never sends the generic
                            // handshake, so the TCP race remains a blackhole.
                            raw_connections.push(stream);
                        }
                    }
                }
            }
            assert!(
                websocket_authenticated,
                "the mixed responder should observe a WebSocket attempt"
            );
            drop(raw_connections);
        });
        (address, release_tx, responder_task)
    }

    /// 启动一个接受单条 TCP 连接并完成 generic responder 握手的测试对端。
    async fn spawn_tcp_generic_responder(
        peer_id: &str,
        local_peer_id: &str,
    ) -> (SocketAddr, oneshot::Sender<()>, tokio::task::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind generic responder");
        let address = listener.local_addr().expect("responder address");
        let peer_id = peer_id.to_string();
        let local_peer_id = local_peer_id.to_string();
        let remote_identity = Arc::new(DeviceIdentity::from_private_keys(
            peer_id, [42u8; 32], [52u8; 32],
        ));
        let local_public_key =
            DeviceIdentity::from_private_keys(local_peer_id.clone(), [41u8; 32], [51u8; 32])
                .public_identity_key()
                .to_bytes();
        let (release_tx, release_rx) = oneshot::channel();
        let responder_task = tokio::spawn(async move {
            let (stream, _) = listener
                .accept()
                .await
                .expect("accept generic responder connection");
            let mut connection = GenericConnection::from_transport(Transport::Tcp(
                TcpTransport::from_stream(stream),
            ));
            let trusted_peer_keys =
                tokio::sync::RwLock::new(HashMap::from([(local_peer_id, local_public_key)]));
            let _ = authenticate_responder(
                &mut connection,
                remote_identity,
                &trusted_peer_keys,
                move |_authenticated_peer_id, _remote_session_binding| async move {
                    Ok(("33".repeat(16), ()))
                },
            )
            .await;
            // 保持连接存活直到测试释放。
            let _ = release_rx.await;
        });
        (address, release_tx, responder_task)
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

    #[test]
    fn direct_candidate_queue_never_starts_a_relay_candidate() {
        let relay = Candidate::new(
            "203.0.113.20:41023".parse().unwrap(),
            CandidateKind::Relay,
            "relay".into(),
        );
        let lan = Candidate::new(
            "192.168.1.20:41024".parse().unwrap(),
            CandidateKind::Lan,
            "wifi".into(),
        );
        let mut pending = std::collections::VecDeque::new();
        let mut started = std::collections::HashSet::new();
        enqueue_candidates(&mut pending, &mut started, vec![relay, lan.clone()]);
        assert_eq!(pending.len(), 1);
        assert_eq!(
            pending.front().map(|candidate| candidate.kind),
            Some(lan.kind)
        );
    }
}
