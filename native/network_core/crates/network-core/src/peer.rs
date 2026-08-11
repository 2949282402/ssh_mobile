//! v1 对端注册表、路由选择与异步连接任务。

use network_identity::DeviceIdentity;
use network_nat::{Candidate, CandidateKind, PathManager};
use network_protocol::{
    NetworkError as ProtocolError, NetworkErrorCode, PeerConnectionState, RouteType,
    UpsertPeerCommand,
};
use network_quic::{QuicEndpointManager, QuicPeerSession};
use quinn::{Connection, Endpoint};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::oneshot;

use crate::events::{emit_peer_state, protocol_error, protocol_error_with_peer};
use crate::runtime::{PeerConfig, RuntimeState, PEER_CONNECT_TIMEOUT};
use crate::session::ConnectDecision;

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

/// 执行直连 QUIC 认证，必要时使用原生 Relay 路径。
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
    match state.sessions.begin_connect(&peer_id).await {
        ConnectDecision::AlreadyConnected(_) | ConnectDecision::InProgress(_) => return Ok(()),
        ConnectDecision::Started(_) => {}
    }
    let selected_endpoint = match state.path_managers.read().await.get(&peer_id).cloned() {
        Some(manager) => manager
            .select_best_path()
            .await
            .map(|candidate| candidate.endpoint),
        None => peer.endpoint,
    };
    if let Some(peer_endpoint) = selected_endpoint {
        let direct_result = async {
            let connecting = endpoint
                .connect(peer_endpoint, "ssh-mobile")
                .map_err(|_error| {
                    protocol_error_with_peer(
                        NetworkErrorCode::QuicError,
                        "failed to create QUIC connection",
                        "connect",
                        &peer_id,
                    )
                })?;
            let connection = tokio::time::timeout(PEER_CONNECT_TIMEOUT, connecting)
                .await
                .map_err(|_| {
                    protocol_error_with_peer(
                        NetworkErrorCode::Timeout,
                        "QUIC connection timed out",
                        "connect",
                        &peer_id,
                    )
                })?
                .map_err(|_| {
                    protocol_error_with_peer(
                        NetworkErrorCode::QuicError,
                        "QUIC connection failed",
                        "connect",
                        &peer_id,
                    )
                })?;
            let session = QuicPeerSession::new(connection.clone(), peer_id.clone());
            tokio::time::timeout(
                PEER_CONNECT_TIMEOUT,
                session.perform_handshake(&identity, peer.identity_public_key),
            )
            .await
            .map_err(|_| {
                protocol_error_with_peer(
                    NetworkErrorCode::Timeout,
                    "peer authentication timed out",
                    "connect",
                    &peer_id,
                )
            })?
            .map_err(|_| {
                protocol_error_with_peer(
                    NetworkErrorCode::AuthenticationFailed,
                    "peer authentication failed",
                    "connect",
                    &peer_id,
                )
            })?;
            Ok::<Connection, ProtocolError>(connection)
        }
        .await;
        if let Ok(connection) = direct_result {
            state
                .sessions
                .attach_connection(&peer_id, connection.clone(), RouteType::QuicDirect)
                .await;
            emit_peer_state(
                &state.event_tx,
                &peer_id,
                PeerConnectionState::Connected,
                RouteType::QuicDirect,
                None,
            );
            tokio::spawn(receive_file_streams(peer_id, connection, state));
            return Ok(());
        } else {
            let relay_available = match state.relay.read().await.clone() {
                Some(relay) => relay.is_usable().await,
                None => false,
            };
            if !relay_available {
                state.sessions.mark_failed(&peer_id).await;
                return direct_result.map(|_| ());
            }
        }
    }
    let relay = match state.relay.read().await.clone() {
        Some(relay) => relay,
        None => {
            state.sessions.mark_failed(&peer_id).await;
            return Err(protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                "peer has no usable direct or Relay route",
                "connect",
                &peer_id,
            ));
        }
    };
    if !relay.is_usable().await {
        state.sessions.mark_failed(&peer_id).await;
        return Err(protocol_error_with_peer(
            NetworkErrorCode::RelayError,
            "Relay socket is not connected",
            "connect",
            &peer_id,
        ));
    }
    let (lookup_tx, lookup_rx) = oneshot::channel();
    state
        .relay_lookups
        .write()
        .await
        .insert(peer_id.clone(), lookup_tx);
    if relay.lookup_peer(&peer_id).await.is_err() {
        state.relay_lookups.write().await.remove(&peer_id);
        state.sessions.mark_failed(&peer_id).await;
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
        state.sessions.mark_failed(&peer_id).await;
        return Err(protocol_error_with_peer(
            NetworkErrorCode::PeerOffline,
            "Relay peer is offline or did not answer lookup",
            "connect",
            &peer_id,
        ));
    }
    state
        .sessions
        .mark_route_connected(&peer_id, RouteType::Relay)
        .await;
    emit_peer_state(
        &state.event_tx,
        &peer_id,
        PeerConnectionState::Connected,
        RouteType::Relay,
        None,
    );
    Ok(())
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
            let result =
                async {
                    let connection = incoming.await?;
                    let identity =
                        state.identity.read().await.clone().ok_or_else(|| {
                            std::io::Error::other("runtime identity is unavailable")
                        })?;
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
                    state
                        .sessions
                        .attach_connection(&peer_id, connection.clone(), RouteType::QuicDirect)
                        .await;
                    emit_peer_state(
                        &state.event_tx,
                        &peer_id,
                        PeerConnectionState::Connected,
                        RouteType::QuicDirect,
                        None,
                    );
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
                let became_disconnected = state
                    .sessions
                    .mark_disconnected_if_current(&peer_id, &connection)
                    .await;
                if became_disconnected {
                    emit_peer_state(
                        &state.event_tx,
                        &peer_id,
                        PeerConnectionState::Disconnected,
                        RouteType::Unspecified,
                        None,
                    );
                }
                return;
            }
        }
    }
}
