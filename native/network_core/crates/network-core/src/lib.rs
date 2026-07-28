//! Core network runtime and lifecycle management.

use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit, Nonce,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use network_identity::DeviceIdentity;
use network_nat::{Candidate, CandidateKind, PathManager};
use network_protocol::{
    network_command, network_event, CommandResultEvent, ConfigureRelayCommand,
    ConfigureRuntimeCommand, IncomingTransferOfferEvent, NetworkCommand,
    NetworkError as ProtocolError, NetworkErrorCode, NetworkEvent, PeerStateChangedEvent,
    RespondIncomingTransferCommand, SendFileCommand, TransferCompletedEvent, TransferProgressEvent,
    UpsertPeerCommand, NETWORK_PROTOCOL_VERSION,
};
use network_quic::{
    read_file_completion, read_file_decision, read_file_offer, write_file_completion,
    write_file_decision, write_file_offer, QuicEndpointManager, QuicPeerSession,
};
use network_relay::{RelayClient, RelayEvent};
use network_transfer::{
    build_file_manifest, stream_receive_file_cancellable, stream_send_file_cancellable,
    TransferManager,
};
use quinn::{Connection, Endpoint, RecvStream, SendStream};
use rand::RngCore;
use serde_json::json;
use std::collections::{hash_map::Entry, HashMap};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::runtime::Runtime;
use tokio::sync::{
    mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender},
    oneshot, Mutex as AsyncMutex, RwLock,
};
use tracing::{info, warn};
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret};

const PEER_CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const INCOMING_APPROVAL_TIMEOUT: Duration = Duration::from_secs(30);
const TRANSFER_COMPLETION_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_PENDING_INCOMING_TRANSFERS: usize = 64;

#[derive(Debug, thiserror::Error)]
pub enum NetworkError {
    #[error("Failed to initialize async runtime: {0}")]
    RuntimeInitFailed(String),
    #[error("Invalid runtime handle")]
    InvalidHandle,
    #[error("Command queue error: {0}")]
    CommandQueueFailed(String),
}

#[derive(Clone)]
struct PeerConfig {
    endpoint: Option<SocketAddr>,
    identity_public_key: [u8; 32],
    e2e_public_key: [u8; 32],
}

struct RuntimeState {
    endpoint: RwLock<Option<Endpoint>>,
    identity: RwLock<Option<Arc<DeviceIdentity>>>,
    receive_directory: RwLock<Option<PathBuf>>,
    peers: RwLock<HashMap<String, PeerConfig>>,
    path_managers: RwLock<HashMap<String, Arc<PathManager>>>,
    trusted_peer_keys: RwLock<HashMap<String, [u8; 32]>>,
    connections: RwLock<HashMap<String, Connection>>,
    relay: RwLock<Option<Arc<RelayClient>>>,
    relay_acceptances: RwLock<HashMap<String, oneshot::Sender<bool>>>,
    relay_completions: RwLock<HashMap<String, oneshot::Sender<bool>>>,
    relay_lookups: RwLock<HashMap<String, oneshot::Sender<bool>>>,
    relay_sessions: RwLock<HashMap<String, String>>,
    relay_pending_incoming: RwLock<HashMap<String, PendingRelayIncoming>>,
    relay_active_incoming: AsyncMutex<HashMap<String, ActiveRelayIncoming>>,
    incoming_decisions: RwLock<HashMap<String, oneshot::Sender<bool>>>,
    transfers: TransferManager,
    event_tx: UnboundedSender<NetworkEvent>,
}

impl RuntimeState {
    fn new(event_tx: UnboundedSender<NetworkEvent>) -> Self {
        Self {
            endpoint: RwLock::new(None),
            identity: RwLock::new(None),
            receive_directory: RwLock::new(None),
            peers: RwLock::new(HashMap::new()),
            path_managers: RwLock::new(HashMap::new()),
            trusted_peer_keys: RwLock::new(HashMap::new()),
            connections: RwLock::new(HashMap::new()),
            relay: RwLock::new(None),
            relay_acceptances: RwLock::new(HashMap::new()),
            relay_completions: RwLock::new(HashMap::new()),
            relay_lookups: RwLock::new(HashMap::new()),
            relay_sessions: RwLock::new(HashMap::new()),
            relay_pending_incoming: RwLock::new(HashMap::new()),
            relay_active_incoming: AsyncMutex::new(HashMap::new()),
            incoming_decisions: RwLock::new(HashMap::new()),
            transfers: TransferManager::new(),
            event_tx,
        }
    }
}

struct PendingRelayIncoming {
    sender_id: String,
    file_name: String,
    total_bytes: u64,
    content_key: [u8; 32],
    nonce_prefix: [u8; 4],
}

struct ActiveRelayIncoming {
    offer: PendingRelayIncoming,
    file: tokio::fs::File,
    temporary_path: PathBuf,
    final_path: PathBuf,
    next_sequence: u64,
    received_bytes: u64,
}

/// Manages the Tokio async runtime lifecycle and command/event channels.
pub struct NetworkRuntime {
    runtime: Arc<Runtime>,
    command_tx: UnboundedSender<NetworkCommand>,
    event_rx: Arc<Mutex<UnboundedReceiver<NetworkEvent>>>,
    event_tx: UnboundedSender<NetworkEvent>,
}

impl NetworkRuntime {
    /// Creates a new `NetworkRuntime` instance with channels and a real command
    /// dispatcher. Network use begins after `ConfigureRuntimeCommand`.
    pub fn new() -> Result<Self, NetworkError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("ssh-net-worker")
            .build()
            .map_err(|e| NetworkError::RuntimeInitFailed(e.to_string()))?;

        let (command_tx, command_rx) = unbounded_channel::<NetworkCommand>();
        let (event_tx, event_rx) = unbounded_channel::<NetworkEvent>();
        let state = Arc::new(RuntimeState::new(event_tx.clone()));
        runtime.spawn(run_command_worker(command_rx, state));

        info!("NetworkRuntime initialized successfully");
        Ok(Self {
            runtime: Arc::new(runtime),
            command_tx,
            event_rx: Arc::new(Mutex::new(event_rx)),
            event_tx,
        })
    }

    pub fn handle(&self) -> &tokio::runtime::Handle {
        self.runtime.handle()
    }

    pub fn send_command(&self, command: NetworkCommand) -> Result<(), NetworkError> {
        self.command_tx
            .send(command)
            .map_err(|e| NetworkError::CommandQueueFailed(e.to_string()))
    }

    pub fn poll_event(&self, timeout_ms: u32) -> Option<NetworkEvent> {
        let mut receiver = self.event_rx.lock().ok()?;
        if timeout_ms == 0 {
            receiver.try_recv().ok()
        } else {
            let handle = self.runtime.handle();
            let _guard = handle.enter();
            handle
                .block_on(tokio::time::timeout(
                    Duration::from_millis(timeout_ms as u64),
                    receiver.recv(),
                ))
                .ok()?
        }
    }

    pub fn emit_event(&self, event: NetworkEvent) {
        let _ = self.event_tx.send(event);
    }
}

async fn run_command_worker(
    mut commands: UnboundedReceiver<NetworkCommand>,
    state: Arc<RuntimeState>,
) {
    info!("Network runtime worker started");
    while let Some(command) = commands.recv().await {
        let command_id = command.command_id.clone();
        let result = dispatch_command(command, Arc::clone(&state)).await;
        emit_command_result(&state.event_tx, command_id, result);
    }
    info!("Network runtime worker shut down");
}

async fn dispatch_command(
    command: NetworkCommand,
    state: Arc<RuntimeState>,
) -> Result<(), ProtocolError> {
    if command.protocol_version != NETWORK_PROTOCOL_VERSION {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            format!(
                "unsupported network protocol version {}",
                command.protocol_version
            ),
        ));
    }
    if command.command_id.is_empty() || command.command_id.len() > 128 {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "command_id must contain 1-128 characters",
        ));
    }
    match command.payload {
        Some(network_command::Payload::ConfigureRuntime(config)) => {
            configure_runtime(state, config).await
        }
        Some(network_command::Payload::UpsertPeer(peer)) => upsert_peer(&state, peer).await,
        Some(network_command::Payload::ConnectPeer(connect)) => {
            connect_peer(state, connect.peer_id).await
        }
        Some(network_command::Payload::SendFile(send)) => start_file_send(state, send).await,
        Some(network_command::Payload::CancelTransfer(cancel)) => {
            if state.transfers.cancel_transfer(&cancel.transfer_id).await {
                if let Some(session_id) = state
                    .relay_sessions
                    .write()
                    .await
                    .remove(&cancel.transfer_id)
                {
                    if let Some(relay) = state.relay.read().await.as_ref() {
                        let _ = relay.send_session_control("cancel", &session_id).await;
                    }
                }
                Ok(())
            } else {
                Err(protocol_error(
                    NetworkErrorCode::InvalidArgument,
                    "transfer is not active",
                ))
            }
        }
        Some(network_command::Payload::RespondIncomingTransfer(response)) => {
            respond_to_incoming(&state, response).await
        }
        Some(network_command::Payload::ConfigureRelay(config)) => {
            configure_relay_for_state(state, config).await
        }
        None => Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "network command payload is required",
        )),
    }
}

async fn configure_runtime(
    state: Arc<RuntimeState>,
    command: ConfigureRuntimeCommand,
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
    let receive_directory = PathBuf::from(command.receive_directory);
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

async fn configure_relay_for_state(
    state: Arc<RuntimeState>,
    command: ConfigureRelayCommand,
) -> Result<(), ProtocolError> {
    let device_id = state
        .identity
        .read()
        .await
        .as_ref()
        .map(|identity| identity.device_id.clone())
        .ok_or_else(|| {
            protocol_error(
                NetworkErrorCode::InvalidArgument,
                "runtime must be configured before Relay",
            )
        })?;
    let signing_seed: [u8; 32] = command.relay_signing_seed.try_into().map_err(|_| {
        protocol_error(
            NetworkErrorCode::InvalidArgument,
            "Relay signing seed must contain 32 bytes",
        )
    })?;
    let mut relay = RelayClient::new(
        command.relay_url,
        device_id,
        command.relay_credential,
        signing_seed,
    )
    .map_err(|error| protocol_error(NetworkErrorCode::RelayError, error.to_string()))?;
    relay
        .connect()
        .await
        .map_err(|error| protocol_error(NetworkErrorCode::RelayError, error.to_string()))?;
    let events = relay
        .take_events()
        .map_err(|error| protocol_error(NetworkErrorCode::RelayError, error.to_string()))?;
    *state.relay.write().await = Some(Arc::new(relay));
    tokio::spawn(handle_relay_events(events, state));
    Ok(())
}

async fn handle_relay_events(
    mut events: tokio::sync::mpsc::Receiver<RelayEvent>,
    state: Arc<RuntimeState>,
) {
    while let Some(event) = events.recv().await {
        match event {
            RelayEvent::Lookup { peer_id, online } => {
                if let Some(sender) = state.relay_lookups.write().await.remove(&peer_id) {
                    let _ = sender.send(online);
                }
            }
            RelayEvent::Control {
                kind,
                session_id,
                peer_id,
                payload,
            } if kind == "offer" => {
                if let (Some(sender_id), Some(payload)) = (peer_id, payload) {
                    if let Err(error) =
                        receive_relay_offer(&state, session_id.clone(), sender_id, payload).await
                    {
                        if let Some(relay) = state.relay.read().await.as_ref() {
                            let _ = relay.send_session_control("cancel", &session_id).await;
                        }
                        warn!("Rejected inbound Relay offer: {}", error);
                    }
                }
            }
            RelayEvent::Control {
                kind,
                session_id,
                peer_id,
                ..
            } if kind == "complete" => {
                if let Err(error) =
                    complete_relay_incoming(&state, &session_id, peer_id.as_deref()).await
                {
                    if let Some(relay) = state.relay.read().await.as_ref() {
                        let _ = relay.send_session_control("cancel", &session_id).await;
                    }
                    warn!("Failed inbound Relay completion: {}", error);
                }
            }
            RelayEvent::Control {
                kind, session_id, ..
            } if kind == "accept" => {
                if let Some(sender) = state.relay_acceptances.write().await.remove(&session_id) {
                    let _ = sender.send(true);
                }
            }
            RelayEvent::Control {
                kind, session_id, ..
            } if kind == "complete_ack" => {
                if let Some(sender) = state.relay_completions.write().await.remove(&session_id) {
                    let _ = sender.send(true);
                }
            }
            RelayEvent::Control {
                kind, session_id, ..
            } if kind == "cancel" => {
                if let Some(sender) = state.relay_acceptances.write().await.remove(&session_id) {
                    let _ = sender.send(false);
                }
                if let Some(sender) = state.relay_completions.write().await.remove(&session_id) {
                    let _ = sender.send(false);
                }
                cancel_relay_incoming(&state, &session_id).await;
            }
            RelayEvent::Binary {
                session_id,
                sequence,
                payload,
                ..
            } => {
                if let Err(error) =
                    receive_relay_chunk(&state, &session_id, sequence, &payload).await
                {
                    cancel_relay_incoming(&state, &session_id).await;
                    if let Some(relay) = state.relay.read().await.as_ref() {
                        let _ = relay.send_session_control("cancel", &session_id).await;
                    }
                    warn!("Rejected inbound Relay chunk: {}", error);
                }
            }
            RelayEvent::Control { .. } => {}
        }
    }
}

async fn receive_relay_offer(
    state: &Arc<RuntimeState>,
    session_id: String,
    sender_id: String,
    encoded_payload: String,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if session_id.len() != 32
        || !session_id.bytes().all(|value| value.is_ascii_hexdigit())
        || !state.peers.read().await.contains_key(&sender_id)
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Relay sender is not a registered peer",
        )
        .into());
    }
    let envelope = URL_SAFE_NO_PAD.decode(encoded_payload)?;
    if envelope.len() < 32 + 12 + 16 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay offer envelope is truncated",
        )
        .into());
    }
    let ephemeral_key: [u8; 32] = envelope[..32].try_into()?;
    let nonce = &envelope[32..44];
    let identity = state
        .identity
        .read()
        .await
        .clone()
        .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?;
    let shared = identity
        .e2e_key
        .diffie_hellman(&X25519PublicKey::from(ephemeral_key));
    let cipher = Aes256Gcm::new_from_slice(shared.as_bytes())
        .map_err(|_| std::io::Error::other("invalid E2E shared secret"))?;
    let clear = cipher
        .decrypt(Nonce::from_slice(nonce), &envelope[44..])
        .map_err(|_| std::io::Error::other("Relay offer authentication failed"))?;
    let value: serde_json::Value = serde_json::from_slice(&clear)?;
    let file_name = value
        .get("file_name")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| std::io::Error::other("Relay file name is missing"))?;
    let total_bytes = value
        .get("file_size")
        .and_then(serde_json::Value::as_u64)
        .ok_or_else(|| std::io::Error::other("Relay file size is invalid"))?;
    let offer_sender = value.get("sender_id").and_then(serde_json::Value::as_str);
    let receiver = value.get("receiver_id").and_then(serde_json::Value::as_str);
    if value.get("v").and_then(serde_json::Value::as_u64) != Some(1)
        || value.get("session_id").and_then(serde_json::Value::as_str) != Some(session_id.as_str())
        || offer_sender != Some(sender_id.as_str())
        || receiver != Some(identity.device_id.as_str())
        || !is_safe_file_name(file_name)
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay offer identity or metadata is invalid",
        )
        .into());
    }
    let content_key: [u8; 32] = URL_SAFE_NO_PAD
        .decode(
            value
                .get("content_key")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| std::io::Error::other("content key is missing"))?,
        )?
        .try_into()
        .map_err(|_| std::io::Error::other("content key has an invalid length"))?;
    let nonce_prefix: [u8; 4] = URL_SAFE_NO_PAD
        .decode(
            value
                .get("nonce_prefix")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| std::io::Error::other("nonce prefix is missing"))?,
        )?
        .try_into()
        .map_err(|_| std::io::Error::other("nonce prefix has an invalid length"))?;
    let pending = PendingRelayIncoming {
        sender_id: sender_id.clone(),
        file_name: file_name.to_string(),
        total_bytes,
        content_key,
        nonce_prefix,
    };
    if state
        .relay_active_incoming
        .lock()
        .await
        .contains_key(&session_id)
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            "duplicate Relay session",
        )
        .into());
    }
    {
        let mut pending_transfers = state.relay_pending_incoming.write().await;
        if pending_transfers.len() >= MAX_PENDING_INCOMING_TRANSFERS {
            return Err(std::io::Error::other("too many pending Relay offers").into());
        }
        match pending_transfers.entry(session_id.clone()) {
            Entry::Vacant(entry) => {
                entry.insert(pending);
            }
            Entry::Occupied(_) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "duplicate Relay session",
                )
                .into());
            }
        }
    }
    let manifest = network_transfer::FileManifest {
        transfer_id: session_id,
        file_name: file_name.to_string(),
        file_size: total_bytes,
        modified_at: 0,
        content_hash: "0".repeat(64),
        protocol_version: network_transfer::NETWORK_TRANSFER_PROTOCOL_VERSION,
    };
    emit_incoming_offer(&state.event_tx, &sender_id, &manifest);
    let expiry_state = Arc::clone(state);
    let expiry_session_id = manifest.transfer_id;
    tokio::spawn(async move {
        tokio::time::sleep(INCOMING_APPROVAL_TIMEOUT).await;
        if expiry_state
            .relay_pending_incoming
            .write()
            .await
            .remove(&expiry_session_id)
            .is_some()
        {
            if let Some(relay) = expiry_state.relay.read().await.as_ref() {
                let _ = relay
                    .send_session_control("cancel", &expiry_session_id)
                    .await;
            }
        }
    });
    Ok(())
}

async fn respond_to_relay_incoming(
    state: &RuntimeState,
    transfer_id: &str,
    accepted: bool,
) -> Result<(), ProtocolError> {
    let result = async {
        let pending = state
            .relay_pending_incoming
            .write()
            .await
            .remove(transfer_id)
            .ok_or_else(|| {
                protocol_error(
                    NetworkErrorCode::InvalidArgument,
                    "incoming transfer is not awaiting approval",
                )
            })?;
        let relay =
            state.relay.read().await.clone().ok_or_else(|| {
                protocol_error(NetworkErrorCode::RelayError, "Relay is unavailable")
            })?;
        if !accepted {
            relay
                .send_session_control("cancel", transfer_id)
                .await
                .map_err(|error| protocol_error(NetworkErrorCode::RelayError, error.to_string()))?;
            return Ok(());
        }
        let receive_directory = state
            .receive_directory
            .read()
            .await
            .clone()
            .ok_or_else(|| {
                protocol_error(
                    NetworkErrorCode::InvalidArgument,
                    "receive directory is unavailable",
                )
            })?;
        tokio::fs::create_dir_all(&receive_directory)
            .await
            .map_err(|error| protocol_error(NetworkErrorCode::IoError, error.to_string()))?;
        let final_path = receive_directory.join(&pending.file_name);
        if tokio::fs::symlink_metadata(&final_path).await.is_ok() {
            return Err(protocol_error(
                NetworkErrorCode::IoError,
                "destination file already exists",
            ));
        }
        let temporary_path = receive_directory.join(format!("{transfer_id}.relay.part"));
        let file = tokio::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary_path)
            .await
            .map_err(|error| protocol_error(NetworkErrorCode::IoError, error.to_string()))?;
        state.relay_active_incoming.lock().await.insert(
            transfer_id.to_string(),
            ActiveRelayIncoming {
                offer: pending,
                file,
                temporary_path,
                final_path,
                next_sequence: 0,
                received_bytes: 0,
            },
        );
        relay
            .send_session_control("accept", transfer_id)
            .await
            .map_err(|error| protocol_error(NetworkErrorCode::RelayError, error.to_string()))
    }
    .await;
    if result.is_err() {
        cancel_relay_incoming(state, transfer_id).await;
        if let Some(relay) = state.relay.read().await.as_ref() {
            let _ = relay.send_session_control("cancel", transfer_id).await;
        }
    }
    result
}

async fn receive_relay_chunk(
    state: &RuntimeState,
    session_id: &str,
    sequence: u64,
    ciphertext: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut active_transfers = state.relay_active_incoming.lock().await;
    let active = active_transfers
        .get_mut(session_id)
        .ok_or_else(|| std::io::Error::other("Relay session is not accepted"))?;
    if sequence != active.next_sequence || ciphertext.len() < 16 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay chunk is replayed or reordered",
        )
        .into());
    }
    let cipher = Aes256Gcm::new_from_slice(&active.offer.content_key)
        .map_err(|_| std::io::Error::other("invalid Relay content key"))?;
    let session_bytes: [u8; 16] = hex::decode(session_id)?.try_into().map_err(|_| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid Relay session ID")
    })?;
    let mut nonce = [0u8; 12];
    nonce[..4].copy_from_slice(&active.offer.nonce_prefix);
    nonce[4..].copy_from_slice(&sequence.to_be_bytes());
    let mut aad = [0u8; 24];
    aad[..16].copy_from_slice(&session_bytes);
    aad[16..].copy_from_slice(&sequence.to_be_bytes());
    let clear = cipher
        .decrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: ciphertext,
                aad: &aad,
            },
        )
        .map_err(|_| std::io::Error::other("Relay chunk authentication failed"))?;
    if clear.is_empty() || active.received_bytes + clear.len() as u64 > active.offer.total_bytes {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay chunk exceeds declared file size",
        )
        .into());
    }
    active.file.write_all(&clear).await?;
    active.received_bytes += clear.len() as u64;
    active.next_sequence += 1;
    emit_transfer_progress(
        &state.event_tx,
        session_id,
        active.received_bytes,
        active.offer.total_bytes,
    );
    Ok(())
}

async fn complete_relay_incoming(
    state: &RuntimeState,
    session_id: &str,
    sender_id: Option<&str>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut active = state
        .relay_active_incoming
        .lock()
        .await
        .remove(session_id)
        .ok_or_else(|| std::io::Error::other("Relay session is not accepted"))?;
    if sender_id != Some(active.offer.sender_id.as_str())
        || active.received_bytes != active.offer.total_bytes
    {
        drop(active.file);
        tokio::fs::remove_file(&active.temporary_path).await.ok();
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Relay completion arrived before all bytes",
        )
        .into());
    }
    if let Err(error) = active.file.flush().await {
        drop(active.file);
        tokio::fs::remove_file(&active.temporary_path).await.ok();
        return Err(error.into());
    }
    drop(active.file);
    if let Err(error) = tokio::fs::rename(&active.temporary_path, &active.final_path).await {
        tokio::fs::remove_file(&active.temporary_path).await.ok();
        return Err(error.into());
    }
    let relay = state
        .relay
        .read()
        .await
        .clone()
        .ok_or_else(|| std::io::Error::other("Relay is unavailable"))?;
    relay
        .send_session_control("complete_ack", session_id)
        .await?;
    emit_transfer_completed(
        &state.event_tx,
        session_id,
        &active.final_path.to_string_lossy(),
    );
    Ok(())
}

async fn cancel_relay_incoming(state: &RuntimeState, session_id: &str) {
    state
        .relay_pending_incoming
        .write()
        .await
        .remove(session_id);
    if let Some(active) = state.relay_active_incoming.lock().await.remove(session_id) {
        drop(active.file);
        tokio::fs::remove_file(active.temporary_path).await.ok();
    }
}

fn is_safe_file_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 255
        && !value.contains(['/', '\\', '\0'])
        && std::path::Path::new(value).components().count() == 1
        && !matches!(
            std::path::Path::new(value).components().next(),
            Some(std::path::Component::ParentDir | std::path::Component::CurDir)
        )
}

async fn upsert_peer(
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

async fn connect_peer(state: Arc<RuntimeState>, peer_id: String) -> Result<(), ProtocolError> {
    if state.connections.read().await.contains_key(&peer_id) {
        return Ok(());
    }
    let endpoint = state.endpoint.read().await.clone().ok_or_else(|| {
        protocol_error(
            NetworkErrorCode::InvalidArgument,
            "runtime is not configured",
        )
    })?;
    let identity = state.identity.read().await.clone().ok_or_else(|| {
        protocol_error(
            NetworkErrorCode::InvalidArgument,
            "runtime is not configured",
        )
    })?;
    let peer = state
        .peers
        .read()
        .await
        .get(&peer_id)
        .cloned()
        .ok_or_else(|| protocol_error(NetworkErrorCode::NoRoute, "peer has no configured route"))?;
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
                .map_err(|error| protocol_error(NetworkErrorCode::QuicError, error.to_string()))?;
            let connection = tokio::time::timeout(PEER_CONNECT_TIMEOUT, connecting)
                .await
                .map_err(|_| {
                    protocol_error(NetworkErrorCode::Timeout, "QUIC connection timed out")
                })?
                .map_err(|error| protocol_error(NetworkErrorCode::QuicError, error.to_string()))?;
            let session = QuicPeerSession::new(connection.clone(), peer_id.clone());
            tokio::time::timeout(
                PEER_CONNECT_TIMEOUT,
                session.perform_handshake(&identity, peer.identity_public_key),
            )
            .await
            .map_err(|_| {
                protocol_error(NetworkErrorCode::Timeout, "peer authentication timed out")
            })?
            .map_err(|error| {
                protocol_error(NetworkErrorCode::AuthenticationFailed, error.to_string())
            })?;
            Ok::<Connection, ProtocolError>(connection)
        }
        .await;
        if let Ok(connection) = direct_result {
            state
                .connections
                .write()
                .await
                .insert(peer_id.clone(), connection.clone());
            emit_peer_state(&state.event_tx, &peer_id, "connected", "quic");
            tokio::spawn(receive_file_streams(peer_id, connection, state));
            return Ok(());
        } else if state.relay.read().await.is_none() {
            return direct_result.map(|_| ());
        }
    }
    let relay = state.relay.read().await.clone().ok_or_else(|| {
        protocol_error(
            NetworkErrorCode::NoRoute,
            "peer has no usable direct or Relay route",
        )
    })?;
    let (lookup_tx, lookup_rx) = oneshot::channel();
    state
        .relay_lookups
        .write()
        .await
        .insert(peer_id.clone(), lookup_tx);
    if let Err(error) = relay.lookup_peer(&peer_id).await {
        state.relay_lookups.write().await.remove(&peer_id);
        return Err(protocol_error(
            NetworkErrorCode::RelayError,
            error.to_string(),
        ));
    }
    let online = tokio::time::timeout(PEER_CONNECT_TIMEOUT, lookup_rx)
        .await
        .ok()
        .and_then(Result::ok)
        .unwrap_or(false);
    state.relay_lookups.write().await.remove(&peer_id);
    if !online {
        return Err(protocol_error(
            NetworkErrorCode::PeerOffline,
            "Relay peer is offline or did not answer lookup",
        ));
    }
    emit_peer_state(&state.event_tx, &peer_id, "connected", "relay");
    Ok(())
}

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

async fn start_file_send(
    state: Arc<RuntimeState>,
    command: SendFileCommand,
) -> Result<(), ProtocolError> {
    if command.transfer_id.is_empty() || command.peer_id.is_empty() || command.file_path.is_empty()
    {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "transfer_id, peer_id, and file_path are required",
        ));
    }
    let path = PathBuf::from(&command.file_path);
    let metadata = tokio::fs::metadata(&path)
        .await
        .map_err(|error| protocol_error(NetworkErrorCode::IoError, error.to_string()))?;
    if !metadata.is_file() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "source is not a regular file",
        ));
    }
    let connection = state
        .connections
        .read()
        .await
        .get(&command.peer_id)
        .cloned();
    let peer = state
        .peers
        .read()
        .await
        .get(&command.peer_id)
        .cloned()
        .ok_or_else(|| protocol_error(NetworkErrorCode::NoRoute, "peer is not registered"))?;
    if connection.is_none() && state.relay.read().await.is_none() {
        return Err(protocol_error(
            NetworkErrorCode::NoRoute,
            "peer has no active direct or Relay route",
        ));
    }

    let placeholder = network_transfer::FileManifest {
        transfer_id: command.transfer_id.clone(),
        file_name: path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_string(),
        file_size: metadata.len(),
        modified_at: 0,
        content_hash: "0".repeat(64),
        protocol_version: network_transfer::NETWORK_TRANSFER_PROTOCOL_VERSION,
    };
    placeholder
        .validate()
        .map_err(|message| protocol_error(NetworkErrorCode::InvalidArgument, message))?;
    if !state.transfers.register_transfer(placeholder).await {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "transfer_id is already active",
        ));
    }
    if let Some(connection) = connection {
        tokio::spawn(send_file(connection, path, command.transfer_id, state));
    } else {
        tokio::spawn(send_file_over_relay(
            peer,
            command.peer_id,
            path,
            command.transfer_id,
            state,
        ));
    }
    Ok(())
}

async fn send_file(
    connection: Connection,
    path: PathBuf,
    transfer_id: String,
    state: Arc<RuntimeState>,
) {
    let result = async {
        let manifest = build_file_manifest(transfer_id.clone(), &path).await?;
        let (mut send, mut receive) = connection.open_bi().await?;
        write_file_offer(&mut send, &manifest).await?;
        let offset = read_file_decision(&mut receive).await?.ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "receiver rejected file",
            )
        })?;
        if offset > manifest.file_size {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid resume offset")
                    .into(),
            );
        }
        let (progress_tx, progress_rx) = unbounded_channel();
        tokio::spawn(forward_progress(
            transfer_id.clone(),
            progress_rx,
            state.event_tx.clone(),
        ));
        let cancellation = state.transfers.cancellation_token(&transfer_id).await;
        stream_send_file_cancellable(
            &path,
            offset,
            &mut send,
            Some(progress_tx),
            cancellation.as_ref(),
        )
        .await?;
        send.finish()?;
        tokio::time::timeout(
            TRANSFER_COMPLETION_TIMEOUT,
            read_file_completion(&mut receive),
        )
        .await
        .map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::TimedOut, "file completion timed out")
        })??;
        emit_transfer_completed(&state.event_tx, &transfer_id, "");
        Ok(())
    }
    .await;
    state.transfers.remove_transfer(&transfer_id).await;
    if let Err(error) = result {
        emit_transfer_error(
            &state.event_tx,
            &transfer_id,
            NetworkErrorCode::QuicError,
            error.to_string(),
        );
    }
}

async fn send_file_over_relay(
    peer: PeerConfig,
    peer_id: String,
    path: PathBuf,
    transfer_id: String,
    state: Arc<RuntimeState>,
) {
    let result = async {
        let relay = state
            .relay
            .read()
            .await
            .clone()
            .ok_or_else(|| std::io::Error::other("Relay is unavailable"))?;
        let manifest = build_file_manifest(transfer_id.clone(), &path).await?;
        let mut session_bytes = [0u8; 16];
        rand::rngs::OsRng.fill_bytes(&mut session_bytes);
        let session_id = hex::encode(session_bytes);
        let mut content_key = [0u8; 32];
        let mut nonce_prefix = [0u8; 4];
        rand::rngs::OsRng.fill_bytes(&mut content_key);
        rand::rngs::OsRng.fill_bytes(&mut nonce_prefix);
        let offer = serde_json::to_vec(&json!({
            "v": 1,
            "session_id": session_id,
            "sender_id": state
                .identity
                .read()
                .await
                .as_ref()
                .map(|identity| identity.device_id.as_str())
                .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?,
            "receiver_id": peer_id,
            "file_name": manifest.file_name,
            "file_size": manifest.file_size,
            "content_key": URL_SAFE_NO_PAD.encode(content_key),
            "nonce_prefix": URL_SAFE_NO_PAD.encode(nonce_prefix),
        }))?;
        let encrypted_offer = encrypt_relay_offer(&offer, peer.e2e_public_key)?;
        let (acceptance_tx, acceptance_rx) = oneshot::channel();
        state
            .relay_acceptances
            .write()
            .await
            .insert(session_id.clone(), acceptance_tx);
        state
            .relay_sessions
            .write()
            .await
            .insert(transfer_id.clone(), session_id.clone());
        relay
            .send_offer(
                &session_id,
                &peer_id,
                &URL_SAFE_NO_PAD.encode(encrypted_offer),
            )
            .await?;
        let accepted = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, acceptance_rx)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or(false);
        state.relay_acceptances.write().await.remove(&session_id);
        if !accepted {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "Relay receiver rejected file",
                )
                .into(),
            );
        }

        let cipher = Aes256Gcm::new_from_slice(&content_key)
            .map_err(|_| std::io::Error::other("invalid Relay content key"))?;
        let mut file = tokio::fs::File::open(&path).await?;
        let mut buffer = vec![0u8; network_transfer::DEFAULT_TRANSFER_BUFFER];
        let mut sequence = 0u64;
        let mut transferred = 0u64;
        let cancellation = state.transfers.cancellation_token(&transfer_id).await;
        loop {
            if cancellation
                .as_ref()
                .is_some_and(network_transfer::TransferCancellation::is_cancelled)
            {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::Interrupted,
                    "Relay transfer cancelled",
                )
                .into());
            }
            let read = file.read(&mut buffer).await?;
            if read == 0 {
                break;
            }
            let ciphertext = encrypt_relay_chunk(
                &cipher,
                &session_bytes,
                &nonce_prefix,
                sequence,
                &buffer[..read],
            )?;
            relay
                .forward_opaque_payload(&session_id, sequence, &ciphertext)
                .await?;
            sequence += 1;
            transferred += read as u64;
            emit_transfer_progress(
                &state.event_tx,
                &transfer_id,
                transferred,
                manifest.file_size,
            );
        }
        if transferred != manifest.file_size {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "Relay source size changed during transfer",
            )
            .into());
        }
        let (completion_tx, completion_rx) = oneshot::channel();
        state
            .relay_completions
            .write()
            .await
            .insert(session_id.clone(), completion_tx);
        relay.send_session_control("complete", &session_id).await?;
        let completed = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, completion_rx)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or(false);
        state.relay_completions.write().await.remove(&session_id);
        if !completed {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Relay completion acknowledgement timed out",
            )
            .into());
        }
        emit_transfer_completed(&state.event_tx, &transfer_id, "");
        Ok(())
    }
    .await;
    if let Some(session_id) = state.relay_sessions.write().await.remove(&transfer_id) {
        if result.is_err() {
            if let Some(relay) = state.relay.read().await.as_ref() {
                let _ = relay.send_session_control("cancel", &session_id).await;
            }
        }
    }
    state.transfers.remove_transfer(&transfer_id).await;
    if let Err(error) = result {
        emit_transfer_error(
            &state.event_tx,
            &transfer_id,
            NetworkErrorCode::RelayError,
            error.to_string(),
        );
    }
}

fn encrypt_relay_offer(
    plaintext: &[u8],
    peer_public_key: [u8; 32],
) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    let ephemeral = StaticSecret::random_from_rng(rand::rngs::OsRng);
    let ephemeral_public = X25519PublicKey::from(&ephemeral);
    let shared = ephemeral.diffie_hellman(&X25519PublicKey::from(peer_public_key));
    let cipher = Aes256Gcm::new_from_slice(shared.as_bytes())
        .map_err(|_| std::io::Error::other("invalid E2E shared secret"))?;
    let mut nonce = [0u8; 12];
    rand::rngs::OsRng.fill_bytes(&mut nonce);
    let encrypted = cipher
        .encrypt(Nonce::from_slice(&nonce), plaintext)
        .map_err(|_| std::io::Error::other("Relay offer encryption failed"))?;
    let mut envelope = Vec::with_capacity(44 + encrypted.len());
    envelope.extend_from_slice(ephemeral_public.as_bytes());
    envelope.extend_from_slice(&nonce);
    envelope.extend_from_slice(&encrypted);
    Ok(envelope)
}

fn encrypt_relay_chunk(
    cipher: &Aes256Gcm,
    session_id: &[u8; 16],
    nonce_prefix: &[u8; 4],
    sequence: u64,
    plaintext: &[u8],
) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    let mut nonce = [0u8; 12];
    nonce[..4].copy_from_slice(nonce_prefix);
    nonce[4..].copy_from_slice(&sequence.to_be_bytes());
    let mut aad = [0u8; 24];
    aad[..16].copy_from_slice(session_id);
    aad[16..].copy_from_slice(&sequence.to_be_bytes());
    cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| std::io::Error::other("Relay chunk encryption failed").into())
}

async fn accept_connections(endpoint: Endpoint, state: Arc<RuntimeState>) {
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
                        .connections
                        .write()
                        .await
                        .insert(peer_id.clone(), connection.clone());
                    emit_peer_state(&state.event_tx, &peer_id, "connected", "quic");
                    receive_file_streams(peer_id, connection, Arc::clone(&state)).await;
                    Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
                }
                .await;
            if let Err(error) = result {
                warn!("Rejected inbound QUIC connection: {}", error);
            }
        });
    }
}

async fn receive_file_streams(peer_id: String, connection: Connection, state: Arc<RuntimeState>) {
    loop {
        match connection.accept_bi().await {
            Ok((send, receive)) => {
                let state = Arc::clone(&state);
                let peer_id = peer_id.clone();
                tokio::spawn(async move {
                    handle_incoming_file(peer_id, send, receive, state).await;
                });
            }
            Err(_) => {
                state.connections.write().await.remove(&peer_id);
                emit_peer_state(&state.event_tx, &peer_id, "disconnected", "");
                return;
            }
        }
    }
}

async fn handle_incoming_file(
    peer_id: String,
    mut send: SendStream,
    mut receive: RecvStream,
    state: Arc<RuntimeState>,
) {
    let mut active_transfer_id = None;
    let result = async {
        let manifest = read_file_offer(&mut receive).await?;
        active_transfer_id = Some(manifest.transfer_id.clone());
        let (decision_tx, decision_rx) = oneshot::channel();
        {
            let mut decisions = state.incoming_decisions.write().await;
            if decisions.len() >= MAX_PENDING_INCOMING_TRANSFERS {
                return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                    std::io::Error::other("too many pending incoming transfers").into(),
                );
            }
            match decisions.entry(manifest.transfer_id.clone()) {
                Entry::Vacant(entry) => {
                    entry.insert(decision_tx);
                }
                Entry::Occupied(_) => {
                    return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                        std::io::Error::new(
                            std::io::ErrorKind::AlreadyExists,
                            "duplicate transfer ID",
                        )
                        .into(),
                    );
                }
            }
        }
        emit_incoming_offer(&state.event_tx, &peer_id, &manifest);
        let accepted = tokio::time::timeout(INCOMING_APPROVAL_TIMEOUT, decision_rx)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or(false);
        state
            .incoming_decisions
            .write()
            .await
            .remove(&manifest.transfer_id);
        write_file_decision(&mut send, accepted, 0).await?;
        if !accepted {
            send.finish()?;
            return Ok(());
        }

        let receive_directory = state
            .receive_directory
            .read()
            .await
            .clone()
            .ok_or_else(|| std::io::Error::other("receive directory is unavailable"))?;
        if !state.transfers.register_transfer(manifest.clone()).await {
            return Err::<(), Box<dyn std::error::Error + Send + Sync>>(
                std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "transfer ID is already active",
                )
                .into(),
            );
        }
        let cancellation = state
            .transfers
            .cancellation_token(&manifest.transfer_id)
            .await;
        let (progress_tx, progress_rx) = unbounded_channel();
        tokio::spawn(forward_progress(
            manifest.transfer_id.clone(),
            progress_rx,
            state.event_tx.clone(),
        ));
        let local_path = stream_receive_file_cancellable(
            &manifest,
            &receive_directory,
            0,
            &mut receive,
            Some(progress_tx),
            cancellation.as_ref(),
        )
        .await?;
        state.transfers.remove_transfer(&manifest.transfer_id).await;
        write_file_completion(&mut send).await?;
        send.finish()?;
        emit_transfer_completed(&state.event_tx, &manifest.transfer_id, &local_path);
        Ok(())
    }
    .await;
    if let Some(transfer_id) = active_transfer_id.as_deref() {
        state.transfers.remove_transfer(transfer_id).await;
        state.incoming_decisions.write().await.remove(transfer_id);
        if result.is_err() {
            let receive_directory = state.receive_directory.read().await.clone();
            if let Some(receive_directory) = receive_directory {
                tokio::fs::remove_file(receive_directory.join(format!("{transfer_id}.part")))
                    .await
                    .ok();
            }
        }
    }
    if let Err(error) = result {
        emit_transfer_error(
            &state.event_tx,
            active_transfer_id.as_deref().unwrap_or("incoming"),
            NetworkErrorCode::QuicError,
            error.to_string(),
        );
    }
}

async fn respond_to_incoming(
    state: &RuntimeState,
    response: RespondIncomingTransferCommand,
) -> Result<(), ProtocolError> {
    if let Some(sender) = state
        .incoming_decisions
        .write()
        .await
        .remove(&response.transfer_id)
    {
        return sender.send(response.accept).map_err(|_| {
            protocol_error(
                NetworkErrorCode::Cancelled,
                "incoming transfer approval expired",
            )
        });
    }
    respond_to_relay_incoming(state, &response.transfer_id, response.accept).await
}

async fn forward_progress(
    transfer_id: String,
    mut progress: UnboundedReceiver<(u64, u64)>,
    event_tx: UnboundedSender<NetworkEvent>,
) {
    while let Some((bytes_transferred, total_bytes)) = progress.recv().await {
        emit_transfer_progress(&event_tx, &transfer_id, bytes_transferred, total_bytes);
    }
}

fn emit_transfer_progress(
    event_tx: &UnboundedSender<NetworkEvent>,
    transfer_id: &str,
    bytes_transferred: u64,
    total_bytes: u64,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{transfer_id}/progress/{bytes_transferred}"),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::TransferProgress(
            TransferProgressEvent {
                transfer_id: transfer_id.to_string(),
                bytes_transferred,
                total_bytes,
            },
        )),
    });
}

fn emit_command_result(
    event_tx: &UnboundedSender<NetworkEvent>,
    command_id: String,
    result: Result<(), ProtocolError>,
) {
    let (accepted, error) = match result {
        Ok(()) => (true, None),
        Err(error) => (false, Some(error)),
    };
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{command_id}/result"),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::CommandResult(CommandResultEvent {
            command_id,
            accepted,
            error,
        })),
    });
}

fn emit_peer_state(
    event_tx: &UnboundedSender<NetworkEvent>,
    peer_id: &str,
    state: &str,
    active_route: &str,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{peer_id}/state/{}", unix_timestamp_ms()),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::PeerState(PeerStateChangedEvent {
            peer_id: peer_id.to_string(),
            state: state.to_string(),
            active_route: active_route.to_string(),
        })),
    });
}

fn emit_incoming_offer(
    event_tx: &UnboundedSender<NetworkEvent>,
    peer_id: &str,
    manifest: &network_transfer::FileManifest,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{}/offer", manifest.transfer_id),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::IncomingTransferOffer(
            IncomingTransferOfferEvent {
                transfer_id: manifest.transfer_id.clone(),
                peer_id: peer_id.to_string(),
                file_name: manifest.file_name.clone(),
                file_size: manifest.file_size,
            },
        )),
    });
}

fn emit_transfer_completed(
    event_tx: &UnboundedSender<NetworkEvent>,
    transfer_id: &str,
    local_path: &str,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{transfer_id}/completed"),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::TransferCompleted(
            TransferCompletedEvent {
                transfer_id: transfer_id.to_string(),
                local_path: local_path.to_string(),
            },
        )),
    });
}

fn emit_transfer_error(
    event_tx: &UnboundedSender<NetworkEvent>,
    transfer_id: &str,
    code: NetworkErrorCode,
    message: String,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("{transfer_id}/error"),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::Error(protocol_error(code, message))),
    });
}

fn protocol_error(code: NetworkErrorCode, message: impl Into<String>) -> ProtocolError {
    ProtocolError {
        code: code as i32,
        message: message.into(),
    }
}

fn unix_timestamp_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use network_protocol::{ConnectPeerCommand, RespondIncomingTransferCommand};
    use std::fs;
    use std::time::Instant;

    #[test]
    fn missing_payload_is_invalid_instead_of_a_fake_no_route() {
        let runtime = NetworkRuntime::new().expect("runtime");
        runtime
            .send_command(NetworkCommand {
                command_id: "command-1".into(),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: None,
            })
            .expect("send command");

        let event = runtime.poll_event(1000).expect("command result");
        assert!(matches!(
            event.payload,
            Some(network_event::Payload::CommandResult(CommandResultEvent {
                accepted: false,
                error: Some(ProtocolError { code, .. }),
                ..
            })) if code == NetworkErrorCode::InvalidArgument as i32
        ));
    }

    #[test]
    fn two_runtimes_authenticate_and_transfer_a_verified_file() {
        let runtime_a = NetworkRuntime::new().expect("runtime A");
        let runtime_b = NetworkRuntime::new().expect("runtime B");
        let address_a = available_loopback_address();
        let address_b = available_loopback_address();
        let identity_seed_a = [11u8; 32];
        let identity_seed_b = [22u8; 32];
        let public_key_a =
            DeviceIdentity::from_private_keys("device-a".into(), identity_seed_a, [31u8; 32])
                .public_identity_key()
                .to_bytes();
        let public_key_b =
            DeviceIdentity::from_private_keys("device-b".into(), identity_seed_b, [32u8; 32])
                .public_identity_key()
                .to_bytes();
        let test_root =
            std::env::temp_dir().join(format!("ssh-mobile-network-core-{}", rand::random::<u64>()));
        let source_dir = test_root.join("source");
        let receive_a = test_root.join("receive-a");
        let receive_b = test_root.join("receive-b");
        fs::create_dir_all(&source_dir).expect("source directory");
        let source_path = source_dir.join("payload.txt");
        fs::write(&source_path, b"verified native QUIC payload").expect("source file");

        send_and_expect_accepted(
            &runtime_a,
            NetworkCommand {
                command_id: "configure-a".into(),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: Some(network_command::Payload::ConfigureRuntime(
                    ConfigureRuntimeCommand {
                        device_id: "device-a".into(),
                        identity_private_key: identity_seed_a.to_vec(),
                        e2e_private_key: vec![31u8; 32],
                        listen_address: address_a.to_string(),
                        receive_directory: receive_a.to_string_lossy().to_string(),
                    },
                )),
            },
        );
        send_and_expect_accepted(
            &runtime_b,
            NetworkCommand {
                command_id: "configure-b".into(),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: Some(network_command::Payload::ConfigureRuntime(
                    ConfigureRuntimeCommand {
                        device_id: "device-b".into(),
                        identity_private_key: identity_seed_b.to_vec(),
                        e2e_private_key: vec![32u8; 32],
                        listen_address: address_b.to_string(),
                        receive_directory: receive_b.to_string_lossy().to_string(),
                    },
                )),
            },
        );
        send_and_expect_accepted(
            &runtime_a,
            upsert_command("peer-b", "device-b", address_b, public_key_b),
        );
        send_and_expect_accepted(
            &runtime_b,
            upsert_command("peer-a", "device-a", address_a, public_key_a),
        );
        send_and_expect_accepted(
            &runtime_a,
            NetworkCommand {
                command_id: "connect-b".into(),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                    peer_id: "device-b".into(),
                    intent: 0,
                })),
            },
        );

        const TRANSFER_ID: &str = "transfer-native-1";
        send_and_expect_accepted(
            &runtime_a,
            NetworkCommand {
                command_id: "send-file".into(),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: Some(network_command::Payload::SendFile(SendFileCommand {
                    transfer_id: TRANSFER_ID.into(),
                    peer_id: "device-b".into(),
                    file_path: source_path.to_string_lossy().to_string(),
                })),
            },
        );
        let offer = poll_until(&runtime_b, Duration::from_secs(10), |event| {
            matches!(
                &event.payload,
                Some(network_event::Payload::IncomingTransferOffer(offer))
                    if offer.transfer_id == TRANSFER_ID
            )
        });
        assert!(offer.is_some(), "receiver never emitted a file offer");
        send_and_expect_accepted(
            &runtime_b,
            NetworkCommand {
                command_id: "accept-file".into(),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: Some(network_command::Payload::RespondIncomingTransfer(
                    RespondIncomingTransferCommand {
                        transfer_id: TRANSFER_ID.into(),
                        accept: true,
                    },
                )),
            },
        );
        let completed = poll_until(&runtime_b, Duration::from_secs(10), |event| {
            matches!(
                &event.payload,
                Some(network_event::Payload::TransferCompleted(completed))
                    if completed.transfer_id == TRANSFER_ID
            )
        });
        assert!(completed.is_some(), "receiver never completed the transfer");
        assert_eq!(
            fs::read(receive_b.join("payload.txt")).expect("received file"),
            b"verified native QUIC payload"
        );
        fs::remove_dir_all(test_root).ok();
    }

    fn upsert_command(
        command_id: &str,
        peer_id: &str,
        endpoint: SocketAddr,
        public_key: [u8; 32],
    ) -> NetworkCommand {
        NetworkCommand {
            command_id: command_id.into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::UpsertPeer(UpsertPeerCommand {
                peer_id: peer_id.into(),
                endpoint_address: endpoint.to_string(),
                identity_public_key: public_key.to_vec(),
                e2e_public_key: vec![0u8; 32],
            })),
        }
    }

    fn send_and_expect_accepted(runtime: &NetworkRuntime, command: NetworkCommand) {
        let command_id = command.command_id.clone();
        runtime.send_command(command).expect("queue command");
        let result = poll_until(runtime, Duration::from_secs(10), |event| {
            matches!(
                &event.payload,
                Some(network_event::Payload::CommandResult(result))
                    if result.command_id == command_id
            )
        })
        .expect("command result");
        assert!(
            matches!(
                result.payload,
                Some(network_event::Payload::CommandResult(CommandResultEvent {
                    accepted: true,
                    ..
                }))
            ),
            "command {command_id} was rejected"
        );
    }

    fn poll_until(
        runtime: &NetworkRuntime,
        timeout: Duration,
        predicate: impl Fn(&NetworkEvent) -> bool,
    ) -> Option<NetworkEvent> {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if let Some(event) = runtime.poll_event(100) {
                if predicate(&event) {
                    return Some(event);
                }
            }
        }
        None
    }

    fn available_loopback_address() -> SocketAddr {
        std::net::UdpSocket::bind("127.0.0.1:0")
            .expect("bind temporary socket")
            .local_addr()
            .expect("temporary socket address")
    }
}
