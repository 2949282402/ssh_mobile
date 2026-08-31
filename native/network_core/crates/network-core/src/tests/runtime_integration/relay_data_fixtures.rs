// 运行时生命周期、传输契约与 reservation 数据面的集成式测试。

use super::*;
use futures_util::{SinkExt, StreamExt};
use network_identity::DeviceIdentity;
use network_protocol::{
    network_command, network_event, AcknowledgeMessageCommand, ChannelMessageEvent,
    CommandResultState, CommunicationClass, ConfigureRuntimeCommand, ConnectPeerCommand,
    DeliveryAckedEvent, DeliveryPolicyCode, NetworkCommand, NetworkError as ProtocolError,
    NetworkErrorCode, PeerConnectionState, RespondIncomingTransferCommand, RouteTransport,
    RouteType, SendFileCommand, SendMessageCommand, SshStreamCloseCommand, SshStreamDataCommand,
    SshStreamOpenCommand, StreamHandle, NETWORK_PROTOCOL_VERSION,
};
use network_relay::v2::proto::*;
use network_relay::v2::{DataEvent, RelayDataClient};
use network_transfer::build_file_manifest;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, VecDeque};
use std::fs;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio_tungstenite::{accept_hdr_async, tungstenite::Message};

#[path = "../relay_transfer_integration.rs"]
mod relay_transfer_integration;

#[path = "../network_v2_route_auth.rs"]
mod network_v2_route_auth;

/// 构造一个合法的 /v2/relay/{32-hex} 数据面地址（测试用 loopback）。
pub(crate) fn v2_relay_data_endpoint(address: SocketAddr, reservation_id: &str) -> String {
    format!("ws://{address}/v2/relay/{reservation_id}")
}

/// Fake Relay v2 数据面：/v2/relay/{reservation_id}。
///
/// 校验首帧 RelayDataConnect（reservation_id + local_token），把同一 reservation 的
/// 两个端点链接起来；对端未链接时把 Payload/Ack 缓冲到 reservation，链接后冲刷。
pub(crate) struct FakeRelayV2Server {
    pub(crate) address: SocketAddr,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<JoinHandle<()>>,
}

impl FakeRelayV2Server {
    pub(crate) async fn start(reservations: HashMap<String, (Vec<u8>, Vec<u8>)>) -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind fake Relay v2 listener");
        let address = listener.local_addr().expect("fake Relay v2 address");
        let (shutdown, shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(run_fake_relay_v2(listener, shutdown_rx, reservations));
        Self {
            address,
            shutdown: Some(shutdown),
            task: Some(task),
        }
    }
}

impl Drop for FakeRelayV2Server {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

/// reservation_id → (initiator_token, responder_token) + 已注册端点/缓冲。
struct RelayV2DataRegistry {
    reservations: HashMap<String, (Vec<u8>, Vec<u8>)>,
    /// reservation_id → 已注册端点。
    endpoints: HashMap<String, Vec<RelayV2DataEndpoint>>,
    /// reservation_id → 对端未链接时缓冲的帧。
    buffered: HashMap<String, Vec<Message>>,
    next_conn_id: u64,
}

struct RelayV2DataEndpoint {
    conn_id: u64,
    initiator: bool,
    outbound: mpsc::Sender<Message>,
}

impl RelayV2DataRegistry {
    fn new(reservations: HashMap<String, (Vec<u8>, Vec<u8>)>) -> Self {
        Self {
            reservations,
            endpoints: HashMap::new(),
            buffered: HashMap::new(),
            next_conn_id: 0,
        }
    }

    fn register(
        &mut self,
        reservation_id: &str,
        initiator: bool,
        outbound: mpsc::Sender<Message>,
    ) -> (u64, Option<Vec<mpsc::Sender<Message>>>) {
        let conn_id = self.next_conn_id;
        self.next_conn_id += 1;
        let endpoints = self
            .endpoints
            .entry(reservation_id.to_string())
            .or_default();
        // 对端已注册：把缓冲的帧冲刷给新端点。
        if let Some(buffered) = self.buffered.remove(reservation_id) {
            for message in buffered {
                let _ = outbound.try_send(message);
            }
        }
        endpoints.push(RelayV2DataEndpoint {
            conn_id,
            initiator,
            outbound,
        });
        let ready_targets = (endpoints.len() == 2
            && endpoints.iter().any(|endpoint| endpoint.initiator)
            && endpoints.iter().any(|endpoint| !endpoint.initiator))
        .then(|| {
            endpoints
                .iter()
                .map(|endpoint| endpoint.outbound.clone())
                .collect()
        });
        (conn_id, ready_targets)
    }

    /// 把一帧从 `from_id` 转发给同一 reservation 的对端；对端未链接则缓冲。
    async fn forward(&mut self, reservation_id: &str, from_id: u64, frame: Message) {
        let endpoints = self.endpoints.get(reservation_id);
        let target = endpoints.and_then(|endpoints| {
            endpoints
                .iter()
                .find(|endpoint| endpoint.conn_id != from_id)
                .map(|endpoint| endpoint.outbound.clone())
        });
        match target {
            Some(target) => {
                let _ = target.send(frame).await;
            }
            None => {
                self.buffered
                    .entry(reservation_id.to_string())
                    .or_default()
                    .push(frame);
            }
        }
    }
}

#[allow(clippy::result_large_err)]
async fn run_fake_relay_v2(
    listener: TcpListener,
    mut shutdown: oneshot::Receiver<()>,
    reservations: HashMap<String, (Vec<u8>, Vec<u8>)>,
) {
    let registry = Arc::new(tokio::sync::Mutex::new(RelayV2DataRegistry::new(
        reservations,
    )));
    let mut handles = Vec::new();
    loop {
        let (stream, _) = tokio::select! {
            result = listener.accept() => match result {
                Ok(value) => value,
                Err(_) => break,
            },
            _ = &mut shutdown => break,
        };
        let path_holder = Arc::new(Mutex::new(None::<String>));
        let path_capture = Arc::clone(&path_holder);
        let socket = match accept_hdr_async(
            stream,
            move |request: &tokio_tungstenite::tungstenite::handshake::server::Request,
                  response: tokio_tungstenite::tungstenite::handshake::server::Response| {
                *path_capture.lock().expect("fake relay path lock") =
                    Some(request.uri().path().to_string());
                Ok(response)
            },
        )
        .await
        {
            Ok(socket) => socket,
            Err(_) => continue,
        };
        let path = path_holder
            .lock()
            .expect("fake relay path lock")
            .take()
            .unwrap_or_default();
        if let Some(reservation_id) = path.strip_prefix("/v2/relay/") {
            let registry = Arc::clone(&registry);
            let handle = tokio::spawn(run_data_connection(
                registry,
                reservation_id.to_string(),
                socket,
            ));
            handles.push(handle);
        } else {
            drop(socket);
        }
    }
    drop(shutdown);
    for handle in handles {
        handle.abort();
    }
}

async fn run_data_connection(
    registry: Arc<tokio::sync::Mutex<RelayV2DataRegistry>>,
    reservation_id: String,
    socket: tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
) {
    let (writer, mut reader) = socket.split();
    // 阶段一：等待并校验首帧 RelayDataConnect，取得 writer 任务与 conn_id。
    let Some(Ok(message)) = reader.next().await else {
        return;
    };
    let Message::Binary(frame) = message else {
        return;
    };
    let Ok(frame) = decode_data_frame(&frame) else {
        return;
    };
    let Some(relay_data_frame::Kind::Connect(connect)) = frame.kind else {
        return;
    };
    let tokens = {
        let guard = registry.lock().await;
        guard.reservations.get(&reservation_id).cloned()
    };
    let Some((initiator_token, responder_token)) = tokens else {
        return;
    };
    if connect.reservation_id != reservation_id
        || (connect.local_token != initiator_token && connect.local_token != responder_token)
    {
        return;
    }
    let initiator = connect.local_token == initiator_token;
    let responder = connect.local_token == responder_token;
    if initiator == responder {
        return;
    }
    let (tx, mut rx) = mpsc::channel::<Message>(64);
    let mut writer_for_task = writer;
    let writer_task = tokio::spawn(async move {
        while let Some(message) = rx.recv().await {
            if writer_for_task.send(message).await.is_err() {
                break;
            }
        }
    });
    let (conn_id, ready_targets) = registry
        .lock()
        .await
        .register(&reservation_id, initiator, tx);
    if let Some(ready_targets) = ready_targets {
        let ready = Message::Ping(
            format!("ssh-mobile-relay-paired-v1:{reservation_id}")
                .into_bytes()
                .into(),
        );
        for target in ready_targets {
            let _ = target.send(ready.clone()).await;
        }
    }
    let writer_task = Some(writer_task);
    // 阶段二：转发 Payload/Ack/Close 到对端。
    while let Some(result) = reader.next().await {
        let Ok(message) = result else {
            break;
        };
        let Message::Binary(frame) = message else {
            continue;
        };
        let Ok(frame) = decode_data_frame(&frame) else {
            continue;
        };
        match frame.kind {
            Some(relay_data_frame::Kind::Payload(_)) | Some(relay_data_frame::Kind::Ack(_)) => {
                let encoded = encode_data_frame(&frame).expect("encode data frame");
                registry
                    .lock()
                    .await
                    .forward(&reservation_id, conn_id, Message::Binary(encoded.into()))
                    .await;
            }
            Some(relay_data_frame::Kind::Close(_)) => {
                let encoded = encode_data_frame(&frame).expect("encode data frame");
                registry
                    .lock()
                    .await
                    .forward(&reservation_id, conn_id, Message::Binary(encoded.into()))
                    .await;
                break;
            }
            _ => {}
        }
    }
    if let Some(task) = writer_task {
        task.abort();
    }
}
