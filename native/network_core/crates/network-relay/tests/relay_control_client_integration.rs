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
use std::sync::atomic::{AtomicBool, Ordering};
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

struct ResolveObservation {
    request_id: u64,
    target_device_id: String,
}

struct ResolveGate {
    hold_next: AtomicBool,
    observed: mpsc::UnboundedSender<ResolveObservation>,
}

#[derive(Default)]
struct ControlState {
    peers: HashMap<String, ControlPeer>,
    attempts: HashMap<String, AttemptRoute>,
    deferred_resolves: HashMap<u64, (mpsc::Sender<Message>, RelayFrame)>,
    resolve_gate: Option<Arc<ResolveGate>>,
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
        Self::start_with_gate(identities, None).await
    }

    async fn start_with_resolve_gate(
        identities: Vec<TestIdentity>,
    ) -> (Self, mpsc::UnboundedReceiver<ResolveObservation>) {
        let (observed, observations) = mpsc::unbounded_channel();
        let gate = Arc::new(ResolveGate {
            hold_next: AtomicBool::new(true),
            observed,
        });
        (
            Self::start_with_gate(identities, Some(gate)).await,
            observations,
        )
    }

    async fn start_with_gate(
        identities: Vec<TestIdentity>,
        resolve_gate: Option<Arc<ResolveGate>>,
    ) -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind local v2 control listener");
        let address = listener.local_addr().expect("local v2 control address");
        let state = Arc::new(Mutex::new(ControlState {
            resolve_gate,
            ..ControlState::default()
        }));
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

    async fn release_resolve(&self, request_id: u64) {
        let (target, frame) = self
            .state
            .lock()
            .await
            .deferred_resolves
            .remove(&request_id)
            .expect("deferred resolve response");
        target
            .send(Message::Binary(
                network_relay::v2::proto::encode_control_frame(&frame)
                    .expect("encode deferred resolve response")
                    .into(),
            ))
            .await
            .expect("send deferred resolve response");
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
            let target_device_id = request.target_device_id.clone();
            let Some(target) = state.peers.get(&target_device_id) else {
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
                sender.coordination_target = Some(target_device_id.clone());
            }
            let response = resolve_response(
                sender_outbound,
                ResolvePeerResponse {
                    request_id: request.request_id,
                    status: ResolveStatus::Ready as i32,
                    discovery: Some(snapshot),
                    retry_after_ms: 0,
                },
            );
            let defer_response = state
                .resolve_gate
                .as_ref()
                .is_some_and(|gate| gate.hold_next.swap(false, Ordering::AcqRel));
            if let Some(gate) = state.resolve_gate.as_ref() {
                let _ = gate.observed.send(ResolveObservation {
                    request_id: request.request_id,
                    target_device_id: target_device_id.clone(),
                });
            }
            if defer_response {
                let (target, frame) = response;
                state
                    .deferred_resolves
                    .insert(request.request_id, (target, frame));
                Vec::new()
            } else {
                vec![response]
            }
        }
        relay_frame::Kind::ConnectivityOffer(offer) => {
            state.offer_count += 1;
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
            state
                .sequence
                .push(format!("offer:{target_id}:{}", offer.attempt_id));
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

async fn connect_and_publish(
    base_url: &str,
    identity: &TestIdentity,
    snapshot: DiscoverySnapshot,
) -> (RelayControlClient, mpsc::Receiver<ControlEvent>) {
    let mut client = RelayControlClient::new(
        base_url.to_string(),
        identity.device_id.clone(),
        identity.credential.clone(),
        identity.signing_seed,
    )
    .expect("construct local control client");
    client.connect().await.expect("local control connect");
    let mut events = client.take_events().expect("local control event stream");
    let _initial_presence = next_event(&mut events).await;
    client
        .publish_discovery(snapshot)
        .await
        .expect("publish local discovery");
    (client, events)
}

fn begin_attempt<'a>(
    client: &'a RelayControlClient,
    attempt_id: &'a str,
    target_device_id: &'a str,
    snapshot: &'a DiscoverySnapshot,
) -> impl std::future::Future<Output = Result<network_relay::v2::ConnectivityAttemptStart, RelayError>>
       + 'a {
    client.begin_connectivity_attempt(
        attempt_id.to_string(),
        target_device_id.to_string(),
        "spoofed-initiator".to_string(),
        snapshot
            .runtime_epoch
            .clone()
            .expect("initiator runtime epoch"),
        snapshot.revision,
        Some(snapshot.clone()),
    )
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
        vec![
            "resolve:device-b".to_string(),
            "offer:device-b:local-attempt-0001".to_string()
        ]
    );
    drop(state);

    client_a.disconnect().await;
    client_b.disconnect().await;
    let mut server = server;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dropped_connectivity_attempt_start_releases_answer_tracker() {
    let identity_a = TestIdentity::ephemeral("device-a");
    let identity_b = TestIdentity::ephemeral("device-b");
    let server = LocalControlServer::start(vec![identity_a.clone(), identity_b.clone()]).await;
    let base_url = server.base_url();
    let snapshot_a = discovery_snapshot(0xA, 0x01, 1);
    let snapshot_b = discovery_snapshot(0xB, 0x02, 2);

    let (client_a, _events_a) =
        connect_and_publish(&base_url, &identity_a, snapshot_a.clone()).await;
    let (mut client_b, mut events_b) =
        connect_and_publish(&base_url, &identity_b, snapshot_b.clone()).await;
    let attempt_id = "dropped-start";

    let start = begin_attempt(&client_a, attempt_id, &identity_b.device_id, &snapshot_a)
        .await
        .expect("initial connectivity attempt start");
    let ControlEvent::ConnectivityOffer(old_offer) = next_event(&mut events_b).await else {
        panic!("device-b must receive the initial connectivity offer");
    };
    assert_eq!(old_offer.attempt_id, attempt_id);
    drop(start);

    let retry = begin_attempt(&client_a, attempt_id, &identity_b.device_id, &snapshot_a)
        .await
        .expect("a dropped ConnectivityAttemptStart must release its tracker");
    let ControlEvent::ConnectivityOffer(new_offer) = next_event(&mut events_b).await else {
        panic!("device-b must receive the retry connectivity offer");
    };
    assert_eq!(new_offer.attempt_id, attempt_id);
    client_b
        .send_connectivity_answer(
            &new_offer,
            true,
            "spoofed-responder",
            snapshot_b.runtime_epoch.clone().expect("device-b epoch"),
            snapshot_b.revision,
            Some(snapshot_b.clone()),
        )
        .await
        .expect("send retry connectivity answer");
    let answer = retry
        .wait_for_answer()
        .await
        .expect("retry connectivity answer");
    assert_eq!(answer.attempt_id, attempt_id);
    assert_eq!(answer.responder_device_id, identity_b.device_id);

    let mut client_a = client_a;
    client_a.disconnect().await;
    client_b.disconnect().await;
    let mut server = server;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancelled_connectivity_answer_waiter_releases_answer_tracker() {
    let identity_a = TestIdentity::ephemeral("device-a");
    let identity_b = TestIdentity::ephemeral("device-b");
    let server = LocalControlServer::start(vec![identity_a.clone(), identity_b.clone()]).await;
    let base_url = server.base_url();
    let snapshot_a = discovery_snapshot(0xA, 0x01, 1);
    let snapshot_b = discovery_snapshot(0xB, 0x02, 2);

    let (client_a, _events_a) =
        connect_and_publish(&base_url, &identity_a, snapshot_a.clone()).await;
    let (mut client_b, mut events_b) =
        connect_and_publish(&base_url, &identity_b, snapshot_b.clone()).await;
    let attempt_id = "cancelled-answer-waiter";

    let start = begin_attempt(&client_a, attempt_id, &identity_b.device_id, &snapshot_a)
        .await
        .expect("initial connectivity attempt start");
    let ControlEvent::ConnectivityOffer(offer) = next_event(&mut events_b).await else {
        panic!("device-b must receive the connectivity offer");
    };
    assert_eq!(offer.attempt_id, attempt_id);

    let wait_task = tokio::spawn(async move { start.wait_for_answer().await });
    tokio::task::yield_now().await;
    wait_task.abort();
    assert!(
        wait_task
            .await
            .expect_err("cancelled waiter task")
            .is_cancelled(),
        "answer waiter task must be cancelled"
    );

    let retry = begin_attempt(&client_a, attempt_id, &identity_b.device_id, &snapshot_a)
        .await
        .expect("cancelling an answer waiter must release its tracker");
    let ControlEvent::ConnectivityOffer(retry_offer) = next_event(&mut events_b).await else {
        panic!("device-b must receive the retry connectivity offer");
    };
    client_b
        .send_connectivity_answer(
            &retry_offer,
            true,
            "spoofed-responder",
            snapshot_b.runtime_epoch.clone().expect("device-b epoch"),
            snapshot_b.revision,
            Some(snapshot_b.clone()),
        )
        .await
        .expect("send retry connectivity answer");
    let answer = retry
        .wait_for_answer()
        .await
        .expect("retry connectivity answer");
    assert_eq!(answer.attempt_id, attempt_id);
    assert_eq!(answer.responder_device_id, identity_b.device_id);

    let mut client_a = client_a;
    client_a.disconnect().await;
    client_b.disconnect().await;
    let mut server = server;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_connectivity_attempts_keep_targets_isolated_and_ordered() {
    let identity_a = TestIdentity::ephemeral("device-a");
    let identity_b = TestIdentity::ephemeral("device-b");
    let identity_c = TestIdentity::ephemeral("device-c");
    let (server, mut resolves) = LocalControlServer::start_with_resolve_gate(vec![
        identity_a.clone(),
        identity_b.clone(),
        identity_c.clone(),
    ])
    .await;
    let base_url = server.base_url();
    let snapshot_a = discovery_snapshot(0xA, 0x01, 1);
    let snapshot_b = discovery_snapshot(0xB, 0x02, 2);
    let snapshot_c = discovery_snapshot(0xC, 0x03, 3);

    let (client_a, _events_a) =
        connect_and_publish(&base_url, &identity_a, snapshot_a.clone()).await;
    let (client_b, mut events_b) =
        connect_and_publish(&base_url, &identity_b, snapshot_b.clone()).await;
    let (client_c, mut events_c) =
        connect_and_publish(&base_url, &identity_c, snapshot_c.clone()).await;
    let client_a = Arc::new(client_a);

    let begin_b = {
        let client = Arc::clone(&client_a);
        let snapshot = snapshot_a.clone();
        tokio::spawn(async move {
            begin_attempt(client.as_ref(), "attempt-b", "device-b", &snapshot).await
        })
    };
    let first_resolve = tokio::time::timeout(Duration::from_secs(2), resolves.recv())
        .await
        .expect("device-b Resolve observation timeout")
        .expect("resolve observation stream closed");
    assert_eq!(first_resolve.target_device_id, "device-b");

    let begin_c = {
        let client = Arc::clone(&client_a);
        let snapshot = snapshot_a.clone();
        tokio::spawn(async move {
            begin_attempt(client.as_ref(), "attempt-c", "device-c", &snapshot).await
        })
    };
    assert!(
        tokio::time::timeout(Duration::from_millis(100), resolves.recv())
            .await
            .is_err(),
        "the second target must not Resolve before the first Offer is enqueued"
    );

    server.release_resolve(first_resolve.request_id).await;
    let second_resolve = tokio::time::timeout(Duration::from_secs(2), resolves.recv())
        .await
        .expect("device-c Resolve observation timeout")
        .expect("resolve observation stream closed");
    assert_eq!(second_resolve.target_device_id, "device-c");

    let start_b = begin_b
        .await
        .expect("device-b begin task")
        .expect("device-b connectivity attempt start");
    let start_c = begin_c
        .await
        .expect("device-c begin task")
        .expect("device-c connectivity attempt start");
    assert_eq!(start_b.resolved.discovery, Some(snapshot_b.clone()));
    assert_eq!(start_c.resolved.discovery, Some(snapshot_c.clone()));

    let ControlEvent::ConnectivityOffer(offer_b) = next_event(&mut events_b).await else {
        panic!("device-b must receive its own connectivity offer");
    };
    let ControlEvent::ConnectivityOffer(offer_c) = next_event(&mut events_c).await else {
        panic!("device-c must receive its own connectivity offer");
    };
    assert_eq!(offer_b.attempt_id, "attempt-b");
    assert_eq!(offer_c.attempt_id, "attempt-c");
    assert_eq!(offer_b.initiator_device_id, identity_a.device_id);
    assert_eq!(offer_c.initiator_device_id, identity_a.device_id);

    client_b
        .send_connectivity_answer(
            &offer_b,
            true,
            "spoofed-responder",
            snapshot_b.runtime_epoch.clone().expect("device-b epoch"),
            snapshot_b.revision,
            Some(snapshot_b.clone()),
        )
        .await
        .expect("send device-b connectivity answer");
    client_c
        .send_connectivity_answer(
            &offer_c,
            true,
            "spoofed-responder",
            snapshot_c.runtime_epoch.clone().expect("device-c epoch"),
            snapshot_c.revision,
            Some(snapshot_c.clone()),
        )
        .await
        .expect("send device-c connectivity answer");
    let (answer_b, answer_c) = tokio::join!(start_b.wait_for_answer(), start_c.wait_for_answer());
    assert_eq!(answer_b.expect("device-b answer").attempt_id, "attempt-b");
    assert_eq!(answer_c.expect("device-c answer").attempt_id, "attempt-c");

    let state = server.state.lock().await;
    assert_eq!(state.resolve_count, 2);
    assert_eq!(state.offer_count, 2);
    assert_eq!(
        state.sequence,
        vec![
            "resolve:device-b".to_string(),
            "offer:device-b:attempt-b".to_string(),
            "resolve:device-c".to_string(),
            "offer:device-c:attempt-c".to_string(),
        ]
    );
    drop(state);

    client_a.request_disconnect().await;
    let mut client_b = client_b;
    client_b.disconnect().await;
    let mut client_c = client_c;
    client_c.disconnect().await;
    let mut server = server;
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn control_authentication_failure_never_enters_ready_state() {
    let identity = TestIdentity::ephemeral("device-a");
    let mut server = LocalControlServer::start(vec![identity.clone()]).await;
    let mut client = RelayControlClient::new(
        server.base_url(),
        identity.device_id.clone(),
        "wrong-credential".into(),
        identity.signing_seed,
    )
    .expect("construct client");

    let error = client
        .connect()
        .await
        .expect_err("invalid credential must not receive Ready");
    assert!(
        matches!(error, RelayError::Authentication(_) | RelayError::Socket(_)),
        "authentication failure must remain fail-closed: {error:?}"
    );
    assert!(!client.is_usable().await);
    server.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_control_disconnect_is_observable_and_cleans_client_state() {
    let identity = TestIdentity::ephemeral("device-a");
    let mut server = LocalControlServer::start(vec![identity.clone()]).await;
    let mut client = RelayControlClient::new(
        server.base_url(),
        identity.device_id.clone(),
        identity.credential.clone(),
        identity.signing_seed,
    )
    .expect("construct client");
    client.connect().await.expect("control connect");
    let mut events = client.take_events().expect("event stream");

    server.shutdown().await;
    let disconnected = tokio::time::timeout(Duration::from_secs(2), async {
        while let Some(event) = events.recv().await {
            if matches!(event, ControlEvent::Disconnected { .. }) {
                return true;
            }
        }
        false
    })
    .await
    .expect("disconnect event timeout");
    assert!(
        disconnected,
        "remote close must be observable as Disconnected"
    );
    assert!(!client.is_usable().await);
    client.disconnect().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn control_client_disconnect_then_reconnect_succeeds() {
    let identity = TestIdentity::ephemeral("device-a");
    let mut server = LocalControlServer::start(vec![identity.clone()]).await;
    let mut client = RelayControlClient::new(
        server.base_url(),
        identity.device_id.clone(),
        identity.credential.clone(),
        identity.signing_seed,
    )
    .expect("construct client");

    let first_ready = client.connect().await.expect("initial control connect");
    assert_eq!(first_ready.device_id, identity.device_id);
    client.disconnect().await;
    assert!(!client.is_usable().await);

    let second_ready = client.connect().await.expect("reconnect must succeed");
    assert_eq!(second_ready.device_id, identity.device_id);
    assert!(client.is_usable().await);
    client.disconnect().await;
    server.shutdown().await;
}
