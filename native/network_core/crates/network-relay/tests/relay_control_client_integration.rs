//! Concrete local `/v2/control` integration coverage for `RelayControlClient`.
//!
//! This test deliberately keeps the server in the test target instead of using a
//! `DiscoveryControlPlane` stub.  It exercises the actual WebSocket handshake,
//! authenticated request headers, Ready/presence ordering, request/response
//! correlation, and the resolve-gated connectivity offer/answer flow without a
//! relay process, persistent credentials, or external services.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use ed25519_dalek::{Signature, SigningKey, Verifier, VerifyingKey};
use futures_util::{SinkExt, StreamExt};
use network_relay::v2::proto::relay_frame;
use network_relay::v2::{
    CandidateBundle, ControlEvent, DiscoveryAck, DiscoverySnapshot, ErrorCode, HeartbeatAck,
    PeerPresenceHint, PresenceHintSnapshot, Ready, RelayControlClient, RelayError, RelayFrame,
    ResolvePeerResponse, ResolveStatus, RuntimeEpoch, TransportCapability, RELAY_V2_VERSION,
};
use rand::RngCore;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, oneshot, Mutex};
use tokio::task::JoinHandle;
use tokio_tungstenite::{
    accept_hdr_async,
    tungstenite::{
        handshake::server::{ErrorResponse, Request, Response},
        http::StatusCode,
        Message,
    },
    WebSocketStream,
};

const TEST_SERVER_TIME_MS: i64 = 1_723_840_800_123;
const TEST_PUBLISHED_AT_MS: i64 = 1_723_840_800_456;
const TEST_HEARTBEAT_INTERVAL_S: u32 = 20;
const TEST_PRESENCE_TTL_S: u32 = 60;

#[derive(Clone)]
struct TestIdentity {
    device_id: String,
    /// This is an ephemeral in-memory bearer value, not a repository secret.
    credential: String,
    signing_seed: [u8; 32],
    verifying_key: VerifyingKey,
}

impl TestIdentity {
    fn ephemeral(device_id: &str) -> Self {
        let mut signing_seed = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut signing_seed);
        let signing_key = SigningKey::from_bytes(&signing_seed);
        Self {
            device_id: device_id.to_string(),
            credential: format!("local-test-{device_id}"),
            signing_seed,
            verifying_key: signing_key.verifying_key(),
        }
    }
}

struct ControlPeer {
    snapshot: Option<DiscoverySnapshot>,
    outbound: mpsc::Sender<Message>,
    coordination_target: Option<String>,
}

struct AttemptRoute {
    initiator: String,
    target: String,
}

#[derive(Default)]
struct ControlState {
    peers: HashMap<String, ControlPeer>,
    attempts: HashMap<String, AttemptRoute>,
    resolve_count: usize,
    offer_count: usize,
    sequence: Vec<String>,
}

/// A tiny but concrete control-plane server. It owns WebSocket connections and
/// routes only the v2 control messages needed by this integration scenario.
struct LocalControlServer {
    address: SocketAddr,
    state: Arc<Mutex<ControlState>>,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<JoinHandle<()>>,
}

impl LocalControlServer {
    async fn start(identities: Vec<TestIdentity>) -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind local v2 control listener");
        let address = listener.local_addr().expect("local v2 control address");
        let state = Arc::new(Mutex::new(ControlState::default()));
        let (shutdown, shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(run_control_server(
            listener,
            identities,
            state.clone(),
            shutdown_rx,
        ));
        Self {
            address,
            state,
            shutdown: Some(shutdown),
            task: Some(task),
        }
    }

    fn base_url(&self) -> String {
        format!("ws://{}", self.address)
    }

    async fn shutdown(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            let _ = task.await;
        }
    }
}

impl Drop for LocalControlServer {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

#[allow(clippy::result_large_err)]
async fn run_control_server(
    listener: TcpListener,
    identities: Vec<TestIdentity>,
    state: Arc<Mutex<ControlState>>,
    mut shutdown: oneshot::Receiver<()>,
) {
    let identities = Arc::new(identities);
    let mut connections = Vec::new();

    loop {
        let (stream, _) = tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok(value) => value,
                Err(_) => break,
            },
            _ = &mut shutdown => break,
        };

        let accepted_device = Arc::new(StdMutex::new(None::<String>));
        let accepted_device_for_callback = Arc::clone(&accepted_device);
        let identities_for_callback = Arc::clone(&identities);
        let socket = match accept_hdr_async(stream, move |request: &Request, response: Response| {
            let Some(device_id) = authenticate_request(request, &identities_for_callback) else {
                return Err(unauthorized_response());
            };
            *accepted_device_for_callback
                .lock()
                .expect("accepted device lock") = Some(device_id);
            Ok(response)
        })
        .await
        {
            Ok(socket) => socket,
            Err(_) => continue,
        };
        let Some(device_id) = accepted_device.lock().expect("accepted device lock").take() else {
            continue;
        };
        let state_for_connection = Arc::clone(&state);
        connections.push(tokio::spawn(run_control_connection(
            state_for_connection,
            device_id,
            socket,
        )));
    }

    for connection in connections {
        connection.abort();
        let _ = connection.await;
    }
}

fn authenticate_request(request: &Request, identities: &[TestIdentity]) -> Option<String> {
    if request.uri().path() != "/v2/control" {
        return None;
    }
    let authorization = request.headers().get("Authorization")?.to_str().ok()?;
    let credential = authorization.strip_prefix("Bearer ")?;
    let identity = identities
        .iter()
        .find(|identity| identity.credential == credential)?;
    let nonce = request.headers().get("X-Relay-Nonce")?.to_str().ok()?;
    let nonce_bytes = URL_SAFE_NO_PAD.decode(nonce).ok()?;
    if nonce_bytes.len() != 32 {
        return None;
    }
    let signature = request
        .headers()
        .get("X-Relay-Signature")
        .and_then(|header| header.to_str().ok())
        .and_then(|encoded| URL_SAFE_NO_PAD.decode(encoded).ok())
        .and_then(|bytes| Signature::from_slice(&bytes).ok())?;
    let transcript = format!("GET\n/v2/control\n{nonce}");
    identity
        .verifying_key
        .verify(transcript.as_bytes(), &signature)
        .ok()?;
    Some(identity.device_id.clone())
}

fn unauthorized_response() -> ErrorResponse {
    Response::builder()
        .status(StatusCode::UNAUTHORIZED)
        .body(Some("local control authentication failed".to_string()))
        .expect("build local unauthorized response")
}

async fn run_control_connection(
    state: Arc<Mutex<ControlState>>,
    device_id: String,
    socket: WebSocketStream<TcpStream>,
) {
    let (mut writer, mut reader) = socket.split();
    let (outbound, mut outbound_rx) = mpsc::channel(32);
    let initial_presence = {
        let mut state = state.lock().await;
        state.peers.insert(
            device_id.clone(),
            ControlPeer {
                snapshot: None,
                outbound: outbound.clone(),
                coordination_target: None,
            },
        );
        presence_snapshot(&state, &device_id)
    };

    if send_frame(
        &mut writer,
        RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::Ready(Ready {
                protocol_version: RELAY_V2_VERSION,
                device_id: device_id.clone(),
                server_time_ms: TEST_SERVER_TIME_MS,
                heartbeat_interval_s: TEST_HEARTBEAT_INTERVAL_S,
                presence_ttl_s: TEST_PRESENCE_TTL_S,
            })),
        },
    )
    .await
    .is_err()
    {
        remove_peer(&state, &device_id).await;
        return;
    }
    if send_frame(
        &mut writer,
        RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::PresenceHintSnapshot(initial_presence)),
        },
    )
    .await
    .is_err()
    {
        remove_peer(&state, &device_id).await;
        return;
    }

    loop {
        tokio::select! {
            message = reader.next() => {
                let Some(Ok(message)) = message else { break; };
                let Message::Binary(frame) = message else {
                    if matches!(message, Message::Close(_)) { break; }
                    continue;
                };
                let Ok(frame) = network_relay::v2::proto::decode_control_frame(&frame) else {
                    break;
                };
                let outbound_frames = dispatch_client_frame(&state, &device_id, frame).await;
                for (target, frame) in outbound_frames {
                    if target.send(Message::Binary(
                        network_relay::v2::proto::encode_control_frame(&frame)
                            .expect("encode local control response")
                            .into(),
                    )).await.is_err() {
                        break;
                    }
                }
            }
            message = outbound_rx.recv() => {
                let Some(message) = message else { break; };
                if writer.send(message).await.is_err() { break; }
            }
        }
    }
    remove_peer(&state, &device_id).await;
}

async fn send_frame(
    writer: &mut futures_util::stream::SplitSink<WebSocketStream<TcpStream>, Message>,
    frame: RelayFrame,
) -> Result<(), RelayError> {
    writer
        .send(Message::Binary(
            network_relay::v2::proto::encode_control_frame(&frame)
                .map_err(|error| RelayError::Protocol(error.to_string()))?
                .into(),
        ))
        .await
        .map_err(|error| RelayError::Socket(error.to_string()))
}

fn presence_snapshot(state: &ControlState, recipient: &str) -> PresenceHintSnapshot {
    let mut peers: Vec<PeerPresenceHint> = state
        .peers
        .iter()
        .filter(|(device_id, _)| device_id.as_str() != recipient)
        .filter_map(|(device_id, peer)| {
            let snapshot = peer.snapshot.as_ref()?;
            Some(PeerPresenceHint {
                device_id: device_id.clone(),
                online: true,
                runtime_epoch: snapshot.runtime_epoch.clone(),
                revision: snapshot.revision,
            })
        })
        .collect();
    peers.sort_by(|left, right| left.device_id.cmp(&right.device_id));
    PresenceHintSnapshot {
        peers,
        published_at_ms: TEST_PUBLISHED_AT_MS,
    }
}

async fn dispatch_client_frame(
    state: &Arc<Mutex<ControlState>>,
    sender_id: &str,
    frame: RelayFrame,
) -> Vec<(mpsc::Sender<Message>, RelayFrame)> {
    let mut state = state.lock().await;
    let Some(sender) = state.peers.get(sender_id) else {
        return Vec::new();
    };
    let sender_outbound = sender.outbound.clone();
    let Some(kind) = frame.kind else {
        return Vec::new();
    };
    match kind {
        relay_frame::Kind::Heartbeat(heartbeat) => vec![(
            sender_outbound,
            RelayFrame {
                version: RELAY_V2_VERSION,
                kind: Some(relay_frame::Kind::HeartbeatAck(HeartbeatAck {
                    request_id: heartbeat.request_id,
                    server_time_ms: TEST_SERVER_TIME_MS,
                })),
            },
        )],
        relay_frame::Kind::DiscoveryPublish(publish) => {
            let Some(snapshot) = publish.snapshot else {
                return vec![protocol_error(
                    sender_outbound,
                    publish.request_id,
                    "discovery publish requires a snapshot",
                )];
            };
            let Some(sender) = state.peers.get_mut(sender_id) else {
                return Vec::new();
            };
            sender.snapshot = Some(snapshot.clone());
            vec![(
                sender.outbound.clone(),
                RelayFrame {
                    version: RELAY_V2_VERSION,
                    kind: Some(relay_frame::Kind::DiscoveryAck(DiscoveryAck {
                        request_id: publish.request_id,
                        runtime_epoch: snapshot.runtime_epoch,
                        revision: snapshot.revision,
                    })),
                },
            )]
        }
        relay_frame::Kind::ResolvePeerRequest(request) => {
            state.resolve_count += 1;
            state
                .sequence
                .push(format!("resolve:{}", request.target_device_id));
            let Some(target) = state.peers.get(&request.target_device_id) else {
                return vec![resolve_response(
                    sender_outbound,
                    ResolvePeerResponse {
                        request_id: request.request_id,
                        status: ResolveStatus::Unknown as i32,
                        discovery: None,
                        retry_after_ms: 5_000,
                    },
                )];
            };
            let Some(snapshot) = target.snapshot.clone() else {
                return vec![resolve_response(
                    sender_outbound,
                    ResolvePeerResponse {
                        request_id: request.request_id,
                        status: ResolveStatus::NotReady as i32,
                        discovery: None,
                        retry_after_ms: 2_000,
                    },
                )];
            };
            if let Some(sender) = state.peers.get_mut(sender_id) {
                sender.coordination_target = Some(request.target_device_id);
            }
            vec![resolve_response(
                sender_outbound,
                ResolvePeerResponse {
                    request_id: request.request_id,
                    status: ResolveStatus::Ready as i32,
                    discovery: Some(snapshot),
                    retry_after_ms: 0,
                },
            )]
        }
        relay_frame::Kind::ConnectivityOffer(offer) => {
            state.offer_count += 1;
            state.sequence.push("offer".to_string());
            let Some(target_id) = state
                .peers
                .get_mut(sender_id)
                .and_then(|sender| sender.coordination_target.take())
            else {
                return vec![protocol_error_with_attempt(
                    sender_outbound,
                    offer.request_id,
                    offer.attempt_id,
                    "connectivity offer requires a preceding resolve",
                )];
            };
            let Some(target_outbound) = state
                .peers
                .get(&target_id)
                .map(|target| target.outbound.clone())
            else {
                return vec![protocol_error_with_attempt(
                    sender_outbound,
                    offer.request_id,
                    offer.attempt_id,
                    "connectivity target is offline",
                )];
            };
            let Some(initiator_snapshot) = state
                .peers
                .get(sender_id)
                .and_then(|sender| sender.snapshot.clone())
            else {
                return vec![protocol_error_with_attempt(
                    sender_outbound,
                    offer.request_id,
                    offer.attempt_id,
                    "connectivity initiator is not ready",
                )];
            };
            state.attempts.insert(
                offer.attempt_id.clone(),
                AttemptRoute {
                    initiator: sender_id.to_string(),
                    target: target_id,
                },
            );
            let mut forwarded = offer;
            forwarded.initiator_device_id = sender_id.to_string();
            forwarded.initiator_runtime_epoch = initiator_snapshot.runtime_epoch.clone();
            forwarded.initiator_revision = initiator_snapshot.revision;
            forwarded.initiator_snapshot = Some(initiator_snapshot);
            vec![(
                target_outbound,
                RelayFrame {
                    version: RELAY_V2_VERSION,
                    kind: Some(relay_frame::Kind::ConnectivityOffer(forwarded)),
                },
            )]
        }
        relay_frame::Kind::ConnectivityAnswer(answer) => {
            let Some(route) = state.attempts.remove(&answer.attempt_id) else {
                return Vec::new();
            };
            if route.target != sender_id {
                return Vec::new();
            }
            let Some(initiator) = state.peers.get(&route.initiator) else {
                return Vec::new();
            };
            let mut forwarded = answer;
            forwarded.responder_device_id = sender_id.to_string();
            vec![(
                initiator.outbound.clone(),
                RelayFrame {
                    version: RELAY_V2_VERSION,
                    kind: Some(relay_frame::Kind::ConnectivityAnswer(forwarded)),
                },
            )]
        }
        _ => Vec::new(),
    }
}

fn protocol_error(
    target: mpsc::Sender<Message>,
    request_id: u64,
    message: &str,
) -> (mpsc::Sender<Message>, RelayFrame) {
    (
        target,
        RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::ProtocolError(
                network_relay::v2::ProtocolError {
                    request_id,
                    attempt_id: String::new(),
                    code: ErrorCode::Protocol as i32,
                    message: message.to_string(),
                },
            )),
        },
    )
}

fn protocol_error_with_attempt(
    target: mpsc::Sender<Message>,
    request_id: u64,
    attempt_id: String,
    message: &str,
) -> (mpsc::Sender<Message>, RelayFrame) {
    (
        target,
        RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::ProtocolError(
                network_relay::v2::ProtocolError {
                    request_id,
                    attempt_id,
                    code: ErrorCode::Protocol as i32,
                    message: message.to_string(),
                },
            )),
        },
    )
}

fn resolve_response(
    target: mpsc::Sender<Message>,
    response: ResolvePeerResponse,
) -> (mpsc::Sender<Message>, RelayFrame) {
    (
        target,
        RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::ResolvePeerResponse(response)),
        },
    )
}

async fn remove_peer(state: &Arc<Mutex<ControlState>>, device_id: &str) {
    state.lock().await.peers.remove(device_id);
}

fn discovery_snapshot(epoch_high: u64, epoch_low: u64, revision: u32) -> DiscoverySnapshot {
    DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch {
            high: epoch_high,
            low: epoch_low,
        }),
        revision,
        transport_capabilities: vec![TransportCapability::Webrtc as i32],
        candidate_bundle: Some(CandidateBundle {
            candidates: vec![b"local-candidate".to_vec()],
        }),
        published_at_ms: TEST_PUBLISHED_AT_MS,
    }
}

async fn next_event(events: &mut mpsc::Receiver<ControlEvent>) -> ControlEvent {
    tokio::time::timeout(Duration::from_secs(2), events.recv())
        .await
        .expect("control event timeout")
        .expect("control event stream closed")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn relay_control_client_exercises_concrete_local_control_server() {
    let identity_a = TestIdentity::ephemeral("device-a");
    let identity_b = TestIdentity::ephemeral("device-b");
    let server = LocalControlServer::start(vec![identity_a.clone(), identity_b.clone()]).await;
    let base_url = server.base_url();

    let mut client_a = RelayControlClient::new(
        base_url.clone(),
        identity_a.device_id.clone(),
        identity_a.credential.clone(),
        identity_a.signing_seed,
    )
    .expect("construct device-a control client");
    let ready_a = client_a.connect().await.expect("device-a control connect");
    assert_eq!(ready_a.device_id, identity_a.device_id);
    assert_eq!(ready_a.server_time_ms, TEST_SERVER_TIME_MS);
    assert_eq!(client_a.ready_presence_ttl(), Some(Duration::from_secs(60)));
    let mut events_a = client_a.take_events().expect("device-a event stream");
    assert!(matches!(
        next_event(&mut events_a).await,
        ControlEvent::PresenceHintSnapshot(PresenceHintSnapshot { peers, .. }) if peers.is_empty()
    ));

    let snapshot_a = discovery_snapshot(0xA, 0x01, 1);
    let discovery_ack_a = client_a
        .publish_discovery(snapshot_a.clone())
        .await
        .expect("publish device-a discovery");
    assert_eq!(discovery_ack_a.revision, snapshot_a.revision);
    assert_eq!(discovery_ack_a.runtime_epoch, snapshot_a.runtime_epoch);
    let heartbeat_ack = client_a.heartbeat().await.expect("device-a heartbeat");
    assert!(matches!(heartbeat_ack, HeartbeatAck { request_id, .. } if request_id > 0));

    let mut client_b = RelayControlClient::new(
        base_url,
        identity_b.device_id.clone(),
        identity_b.credential.clone(),
        identity_b.signing_seed,
    )
    .expect("construct device-b control client");
    let ready_b = client_b.connect().await.expect("device-b control connect");
    assert_eq!(ready_b.device_id, identity_b.device_id);
    let mut events_b = client_b.take_events().expect("device-b event stream");
    let initial_b = next_event(&mut events_b).await;
    let ControlEvent::PresenceHintSnapshot(initial_b) = initial_b else {
        panic!("device-b must receive an initial presence snapshot");
    };
    assert_eq!(
        initial_b.peers,
        vec![PeerPresenceHint {
            device_id: identity_a.device_id.clone(),
            online: true,
            runtime_epoch: snapshot_a.runtime_epoch.clone(),
            revision: snapshot_a.revision,
        }]
    );

    let snapshot_b = discovery_snapshot(0xB, 0x02, 3);
    let discovery_ack_b = client_b
        .publish_discovery(snapshot_b.clone())
        .await
        .expect("publish device-b discovery");
    assert_eq!(discovery_ack_b.revision, snapshot_b.revision);
    assert_eq!(discovery_ack_b.runtime_epoch, snapshot_b.runtime_epoch);

    let attempt_id = "local-attempt-0001".to_string();
    let initiator = client_a.begin_connectivity_attempt(
        attempt_id.clone(),
        identity_b.device_id.clone(),
        "spoofed-initiator".to_string(),
        snapshot_a.runtime_epoch.clone().expect("device-a epoch"),
        snapshot_a.revision,
        Some(snapshot_a.clone()),
    );
    let responder = async {
        let ControlEvent::ConnectivityOffer(offer) = next_event(&mut events_b).await else {
            panic!("unexpected device-b event while waiting for offer");
        };
        assert_eq!(offer.attempt_id, attempt_id);
        assert_eq!(offer.initiator_device_id, identity_a.device_id);
        assert_eq!(offer.initiator_snapshot, Some(snapshot_a.clone()));
        assert_eq!(offer.initiator_revision, snapshot_a.revision);
        client_b
            .send_connectivity_answer(
                &offer,
                true,
                "spoofed-responder",
                snapshot_b.runtime_epoch.clone().expect("device-b epoch"),
                snapshot_b.revision,
                Some(snapshot_b.clone()),
            )
            .await
            .expect("send device-b connectivity answer");
        offer
    };
    let (start_result, observed_offer) = tokio::join!(initiator, responder);
    let start = start_result.expect("device-a connectivity attempt start");
    assert_eq!(start.resolved.status, ResolveStatus::Ready as i32);
    assert_eq!(start.resolved.discovery, Some(snapshot_b.clone()));
    let answer = start
        .wait_for_answer()
        .await
        .expect("device-a connectivity answer");
    assert_eq!(answer.attempt_id, attempt_id);
    assert!(answer.accepted);
    assert_eq!(answer.responder_device_id, identity_b.device_id);
    assert_eq!(answer.responder_snapshot, Some(snapshot_b));
    assert_eq!(observed_offer.initiator_device_id, identity_a.device_id);

    let state = server.state.lock().await;
    assert_eq!(state.resolve_count, 1);
    assert_eq!(state.offer_count, 1);
    assert_eq!(
        state.sequence,
        vec!["resolve:device-b".to_string(), "offer".to_string()]
    );
    drop(state);

    client_a.disconnect().await;
    client_b.disconnect().await;
    let mut server = server;
    server.shutdown().await;
}
