//! Connection-layer capabilities shared by route selection and generic native
//! transport primitives.
//!
//! This layer deliberately does not own a Session, Delivery queue, or
//! application payload. It translates the transport primitive into a stable
//! capability and lets higher layers choose a route without depending on a
//! concrete TCP/UDP/WebSocket implementation.

use network_protocol::RouteType;
use network_transport::{
    Transport, TransportError, TransportKind, TransportReader, TransportWriter,
};
use std::future::Future;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc,
};
use tokio::sync::{mpsc, oneshot};

use crate::task_supervisor::CancellationToken;

const GENERIC_FRAME_MAGIC: &[u8; 4] = b"SMGF";
const GENERIC_FRAME_HEADER_BYTES: usize = 4 + 4 + 1 + 4;
const GENERIC_ROUTE_CHANNEL_CAPACITY: usize = 32;
static NEXT_GENERIC_ROUTE_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RouteTopology {
    Direct,
    Relay,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RouteTransport {
    Quic,
    Tcp,
    Udp,
    WebSocket,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Route {
    topology: RouteTopology,
    transport: RouteTransport,
}

impl Route {
    pub const fn direct(transport: RouteTransport) -> Self {
        Self {
            topology: RouteTopology::Direct,
            transport,
        }
    }

    pub const fn relay(transport: RouteTransport) -> Self {
        Self {
            topology: RouteTopology::Relay,
            transport,
        }
    }

    pub const fn topology(self) -> RouteTopology {
        self.topology
    }

    pub const fn transport(self) -> RouteTransport {
        self.transport
    }

    pub const fn supports(self, capability: ConnectionCapability) -> bool {
        matches!(
            (self.transport, capability),
            (
                RouteTransport::Tcp | RouteTransport::Quic,
                ConnectionCapability::ReliableStream | ConnectionCapability::ReliableMessage
            ) | (
                RouteTransport::WebSocket,
                ConnectionCapability::ReliableMessage
            ) | (
                RouteTransport::Udp | RouteTransport::Quic,
                ConnectionCapability::UnreliableDatagram
            )
        )
    }

    /// Converts the current wire-era route projection into the composed form.
    /// Generic transports intentionally have no flat v1 enum projection.
    pub const fn from_wire(route: RouteType) -> Option<Self> {
        match route {
            RouteType::QuicDirect | RouteType::Lan => Some(Self::direct(RouteTransport::Quic)),
            RouteType::Relay => Some(Self::relay(RouteTransport::WebSocket)),
            RouteType::Unspecified => None,
        }
    }

    /// Returns the existing event projection when one is defined. Generic
    /// routes use the composed topology/transport event fields instead of
    /// expanding the legacy flat enum.
    pub const fn to_wire(self) -> Option<RouteType> {
        match (self.topology, self.transport) {
            (RouteTopology::Direct, RouteTransport::Quic) => Some(RouteType::QuicDirect),
            (RouteTopology::Relay, RouteTransport::WebSocket) => Some(RouteType::Relay),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionCapability {
    ReliableStream,
    ReliableMessage,
    UnreliableDatagram,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RouteCandidate {
    route: Route,
    available: bool,
}

impl RouteCandidate {
    pub const fn available(route: Route) -> Self {
        Self {
            route,
            available: true,
        }
    }

    pub const fn blocked(route: Route) -> Self {
        Self {
            route,
            available: false,
        }
    }

    pub const fn route(self) -> Route {
        self.route
    }

    pub const fn is_available(self) -> bool {
        self.available
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConnectionProfile {
    route: Route,
}

impl ConnectionProfile {
    pub const fn new(route: Route) -> Self {
        Self { route }
    }

    pub const fn route(self) -> Route {
        self.route
    }

    pub const fn topology(self) -> RouteTopology {
        self.route.topology()
    }

    pub const fn transport(self) -> RouteTransport {
        self.route.transport()
    }

    pub const fn supports(self, capability: ConnectionCapability) -> bool {
        self.route.supports(capability)
    }

    pub const fn for_route(route: RouteType) -> Option<Self> {
        match Route::from_wire(route) {
            Some(route) => Some(Self::new(route)),
            None => None,
        }
    }

    pub const fn for_generic(kind: TransportKind) -> Self {
        Self::for_generic_with_topology(kind, RouteTopology::Direct)
    }

    pub const fn for_generic_with_topology(kind: TransportKind, topology: RouteTopology) -> Self {
        let transport = match kind {
            TransportKind::Tcp => RouteTransport::Tcp,
            TransportKind::Udp => RouteTransport::Udp,
            TransportKind::WebSocket => RouteTransport::WebSocket,
        };
        let route = match topology {
            RouteTopology::Direct => Route::direct(transport),
            RouteTopology::Relay => Route::relay(transport),
        };
        Self::new(route)
    }
}

/// Selects the first available route that advertises the requested capability.
/// Candidate order is supplied by the Session/Route owner, so this helper does
/// not invent a second priority or retry policy. A blocked candidate is a
/// normal probe result, not a transport error or an application retry.
pub struct ConnectionRouteSelector;

impl ConnectionRouteSelector {
    pub fn select(
        capability: ConnectionCapability,
        candidates: impl IntoIterator<Item = RouteCandidate>,
    ) -> Option<ConnectionProfile> {
        candidates
            .into_iter()
            .filter(|candidate| candidate.is_available())
            .map(RouteCandidate::route)
            .map(ConnectionProfile::new)
            .find(|profile| profile.supports(capability))
    }
}

/// Owns one generic primitive connection until identity authentication has
/// completed. After authentication, [`prepare_generic_route`] moves the
/// primitive into a staged I/O driver. The driver is intentionally returned as
/// a Future; the Session/Runtime owner decides when and where it is spawned.
pub struct GenericConnection {
    transport: Transport,
    profile: ConnectionProfile,
}

impl GenericConnection {
    pub fn from_transport(transport: Transport) -> Self {
        let profile = ConnectionProfile::for_generic(transport.kind());
        Self { transport, profile }
    }

    pub async fn connect_tcp(local: SocketAddr, peer: SocketAddr) -> Result<Self, TransportError> {
        Ok(Self::from_transport(
            Transport::connect_tcp(local, peer).await?,
        ))
    }

    pub async fn bind_udp(local: SocketAddr, peer: SocketAddr) -> Result<Self, TransportError> {
        Ok(Self::from_transport(
            Transport::bind_udp(local, peer).await?,
        ))
    }

    pub async fn connect_websocket(url: &str) -> Result<Self, TransportError> {
        Ok(Self::from_transport(
            Transport::connect_websocket(url).await?,
        ))
    }

    pub fn profile(&self) -> ConnectionProfile {
        self.profile
    }

    pub fn route(&self) -> Route {
        self.profile.route()
    }

    pub fn with_topology(mut self, topology: RouteTopology) -> Self {
        self.profile =
            ConnectionProfile::for_generic_with_topology(self.transport.kind(), topology);
        self
    }

    pub async fn send(&mut self, payload: &[u8]) -> Result<usize, TransportError> {
        self.transport.send(payload).await
    }

    pub async fn recv(&mut self) -> Result<Vec<u8>, TransportError> {
        self.transport.recv().await
    }

    pub async fn close(&mut self) -> Result<(), TransportError> {
        self.transport.close().await
    }

    pub(crate) fn into_route_parts(self) -> (TransportReader, TransportWriter) {
        self.transport.into_split()
    }
}

/// The two application channel frames supported by reliable generic routes.
/// UDP deliberately has no conversion into this type, so it cannot silently
/// acquire Delivery semantics.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum GenericFrameKind {
    DataMessage = 1,
    DeliveryAck = 2,
}

impl TryFrom<u8> for GenericFrameKind {
    type Error = ConnectionError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::DataMessage),
            2 => Ok(Self::DeliveryAck),
            _ => Err(ConnectionError::InvalidFrame),
        }
    }
}

#[derive(Debug)]
pub(crate) struct GenericInboundFrame {
    pub(crate) kind: GenericFrameKind,
    pub(crate) payload: Vec<u8>,
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum ConnectionError {
    #[error("generic route is closed")]
    Closed,
    #[error("generic route frame is invalid")]
    InvalidFrame,
    #[error("generic route frame is too large")]
    FrameTooLarge,
    #[error("generic route transport failed: {0}")]
    Transport(#[from] TransportError),
    #[error("generic route command was cancelled")]
    Cancelled,
}

enum GenericRouteCommand {
    Send {
        kind: GenericFrameKind,
        payload: Vec<u8>,
        result: oneshot::Sender<Result<(), ConnectionError>>,
    },
    Close {
        result: oneshot::Sender<Result<(), ConnectionError>>,
    },
}

/// A bounded, authenticated generic transport carrier owned by one Session.
/// The I/O task owns the underlying socket, allowing receive and send to make
/// progress concurrently without holding a mutex across a blocking read.
#[derive(Clone)]
pub(crate) struct GenericRouteHandle {
    id: u64,
    profile: ConnectionProfile,
    commands: mpsc::Sender<GenericRouteCommand>,
    stop: CancellationToken,
}

impl GenericRouteHandle {
    pub(crate) fn id(&self) -> u64 {
        self.id
    }

    pub(crate) fn profile(&self) -> ConnectionProfile {
        self.profile
    }

    pub(crate) async fn send(
        &self,
        kind: GenericFrameKind,
        payload: &[u8],
    ) -> Result<(), ConnectionError> {
        let (result_tx, result_rx) = oneshot::channel();
        tokio::select! {
            _ = self.stop.cancelled() => Err(ConnectionError::Cancelled),
            result = self.commands.send(GenericRouteCommand::Send {
                kind,
                payload: payload.to_vec(),
                result: result_tx,
            }) => {
                result.map_err(|_| ConnectionError::Closed)?;
                tokio::select! {
                    _ = self.stop.cancelled() => Err(ConnectionError::Cancelled),
                    result = result_rx => result.map_err(|_| ConnectionError::Cancelled)?,
                }
            }
        }
    }

    pub(crate) async fn close(&self) -> Result<(), ConnectionError> {
        let (result_tx, result_rx) = oneshot::channel();
        tokio::select! {
            _ = self.stop.cancelled() => Err(ConnectionError::Cancelled),
            result = self.commands.send(GenericRouteCommand::Close { result: result_tx }) => {
                result.map_err(|_| ConnectionError::Closed)?;
                tokio::select! {
                    _ = self.stop.cancelled() => Err(ConnectionError::Cancelled),
                    result = result_rx => result.map_err(|_| ConnectionError::Cancelled)?,
                }
            }
        }
    }
}

/// A prepared GenericRoute whose driver has not been started by the runtime
/// owner yet. The driver reports readiness before waiting for `commit`, which
/// lets the Session attach atomically without a pre-attach socket race.
pub(crate) struct GenericRouteRuntime {
    pub(crate) handle: GenericRouteHandle,
    pub(crate) inbound: mpsc::Receiver<GenericInboundFrame>,
    pub(crate) driver: Pin<Box<dyn Future<Output = ()> + Send>>,
    pub(crate) ready: oneshot::Receiver<()>,
    pub(crate) commit: oneshot::Sender<()>,
    pub(crate) stop: CancellationToken,
    pub(crate) stopping: Arc<AtomicBool>,
}

struct GenericRouteStopGuard {
    stop: CancellationToken,
    stopping: Arc<AtomicBool>,
}

impl Drop for GenericRouteStopGuard {
    fn drop(&mut self) {
        if !self.stopping.load(Ordering::Acquire) {
            self.stop.cancel();
        }
    }
}

#[cfg(test)]
pub(crate) struct TestBlockingGenericRoute {
    pub(crate) handle: GenericRouteHandle,
    pub(crate) started: oneshot::Receiver<()>,
    pub(crate) release: oneshot::Sender<()>,
    pub(crate) worker: tokio::task::JoinHandle<()>,
}

#[cfg(test)]
pub(crate) fn test_blocking_generic_route() -> TestBlockingGenericRoute {
    let (command_tx, mut command_rx) = mpsc::channel(GENERIC_ROUTE_CHANNEL_CAPACITY);
    let (started_tx, started_rx) = oneshot::channel();
    let (release_tx, release_rx) = oneshot::channel();
    let handle = GenericRouteHandle {
        id: NEXT_GENERIC_ROUTE_ID.fetch_add(1, Ordering::Relaxed),
        profile: ConnectionProfile::for_generic(TransportKind::Tcp),
        commands: command_tx,
        stop: CancellationToken::default(),
    };
    let worker = tokio::spawn(async move {
        let mut started_tx = Some(started_tx);
        let mut release_rx = Some(release_rx);
        while let Some(command) = command_rx.recv().await {
            match command {
                GenericRouteCommand::Send { kind, result, .. } => {
                    debug_assert_eq!(kind, GenericFrameKind::DeliveryAck);
                    if let Some(sender) = started_tx.take() {
                        let _ = sender.send(());
                    }
                    if let Some(release) = release_rx.take() {
                        let _ = release.await;
                    }
                    let _ = result.send(Ok(()));
                }
                GenericRouteCommand::Close { result } => {
                    let _ = result.send(Ok(()));
                    return;
                }
            }
        }
    });

    TestBlockingGenericRoute {
        handle,
        started: started_rx,
        release: release_tx,
        worker,
    }
}

/// Moves an authenticated primitive into one staged, bounded I/O driver.
///
/// This function constructs channels and the driver only. It never starts a
/// long-lived task; the caller must register `driver` with the
/// `RuntimeTaskSupervisor` before handing the route to a Session.
pub(crate) fn prepare_generic_route(connection: GenericConnection) -> GenericRouteRuntime {
    let (command_tx, command_rx) = mpsc::channel(GENERIC_ROUTE_CHANNEL_CAPACITY);
    let (inbound_tx, inbound_rx) = mpsc::channel(GENERIC_ROUTE_CHANNEL_CAPACITY);
    let (ready_tx, ready_rx) = oneshot::channel();
    let (commit_tx, mut commit_rx) = oneshot::channel();
    let stop = CancellationToken::default();
    let stopping = Arc::new(AtomicBool::new(false));
    let profile = connection.profile;
    let handle = GenericRouteHandle {
        id: NEXT_GENERIC_ROUTE_ID.fetch_add(1, Ordering::Relaxed),
        profile,
        commands: command_tx,
        stop: stop.clone(),
    };

    let stop_for_driver = stop.clone();
    let stopping_for_driver = Arc::clone(&stopping);
    let driver = Box::pin(async move {
        let mut connection = connection;
        let _stop_guard = GenericRouteStopGuard {
            stop: stop_for_driver.clone(),
            stopping: stopping_for_driver,
        };
        if ready_tx.send(()).is_err() {
            let _ = connection.close().await;
            return;
        }
        let committed = tokio::select! {
            _ = stop_for_driver.cancelled() => false,
            result = &mut commit_rx => result.is_ok(),
        };
        if !committed {
            let _ = connection.close().await;
            return;
        }
        let (reader, writer) = connection.into_route_parts();
        let reader_task = generic_route_reader(reader, inbound_tx, stop_for_driver.clone());
        let writer_task = generic_route_writer(writer, command_rx, stop_for_driver.clone());
        tokio::pin!(reader_task);
        tokio::pin!(writer_task);
        tokio::select! {
            _ = stop_for_driver.cancelled() => {}
            _ = &mut reader_task => {}
            _ = &mut writer_task => {}
        }
    });
    GenericRouteRuntime {
        handle,
        inbound: inbound_rx,
        driver,
        ready: ready_rx,
        commit: commit_tx,
        stop,
        stopping,
    }
}

/// Reads independently from the route writer. Once the bounded Session-facing
/// queue is full, awaiting `send` deliberately stops reading from the socket
/// until the receiver makes room; temporary saturation is not a route error.
async fn generic_route_reader(
    mut reader: TransportReader,
    inbound_tx: mpsc::Sender<GenericInboundFrame>,
    stop: CancellationToken,
) {
    loop {
        let encoded = tokio::select! {
            _ = stop.cancelled() => return,
            result = reader.recv() => match result {
                Ok(encoded) => encoded,
                Err(_) => return,
            },
        };
        let frame = match decode_generic_frame(&encoded) {
            Ok(frame) => frame,
            Err(_) => return,
        };
        tokio::select! {
            _ = stop.cancelled() => return,
            result = inbound_tx.send(frame) => {
                if result.is_err() {
                    return;
                }
            }
        }
    }
}

/// Serializes application frames on the route's write half. The in-flight
/// transport write is itself cancellation-aware, so route replacement and
/// shutdown can preempt a blocked OS write instead of waiting for the peer.
async fn generic_route_writer(
    mut writer: TransportWriter,
    mut command_rx: mpsc::Receiver<GenericRouteCommand>,
    stop: CancellationToken,
) {
    while let Some(command) = tokio::select! {
        _ = stop.cancelled() => return,
        command = command_rx.recv() => command,
    } {
        match command {
            GenericRouteCommand::Send {
                kind,
                payload,
                result,
            } => {
                let encoded = match encode_generic_frame(kind, &payload) {
                    Ok(encoded) => encoded,
                    Err(error) => {
                        let _ = result.send(Err(error));
                        continue;
                    }
                };
                let send_result = tokio::select! {
                    _ = stop.cancelled() => Err(ConnectionError::Cancelled),
                    result = writer.send(&encoded) => result
                        .map(|_| ())
                        .map_err(ConnectionError::from),
                };
                let failed = send_result.is_err();
                let _ = result.send(send_result);
                if failed {
                    return;
                }
            }
            GenericRouteCommand::Close { result } => {
                let close_result = tokio::select! {
                    _ = stop.cancelled() => Err(ConnectionError::Cancelled),
                    result = writer.close() => result
                        .map(|_| ())
                        .map_err(ConnectionError::from),
                };
                let _ = result.send(close_result);
                return;
            }
        }
    }
}

fn encode_generic_frame(
    kind: GenericFrameKind,
    payload: &[u8],
) -> Result<Vec<u8>, ConnectionError> {
    if payload.is_empty()
        || payload.len() + GENERIC_FRAME_HEADER_BYTES > network_quic::MAX_CHANNEL_FRAME_BYTES
    {
        return Err(ConnectionError::FrameTooLarge);
    }
    let mut encoded = Vec::with_capacity(GENERIC_FRAME_HEADER_BYTES + payload.len());
    encoded.extend_from_slice(GENERIC_FRAME_MAGIC);
    encoded.extend_from_slice(&network_protocol::NETWORK_PROTOCOL_VERSION.to_be_bytes());
    encoded.push(kind as u8);
    encoded.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    encoded.extend_from_slice(payload);
    Ok(encoded)
}

fn decode_generic_frame(encoded: &[u8]) -> Result<GenericInboundFrame, ConnectionError> {
    if encoded.len() < GENERIC_FRAME_HEADER_BYTES
        || &encoded[..4] != GENERIC_FRAME_MAGIC
        || u32::from_be_bytes(encoded[4..8].try_into().expect("version bytes"))
            != network_protocol::NETWORK_PROTOCOL_VERSION
    {
        return Err(ConnectionError::InvalidFrame);
    }
    let kind = GenericFrameKind::try_from(encoded[8])?;
    let payload_len = u32::from_be_bytes(encoded[9..13].try_into().expect("length bytes")) as usize;
    if payload_len == 0
        || payload_len + GENERIC_FRAME_HEADER_BYTES != encoded.len()
        || payload_len + GENERIC_FRAME_HEADER_BYTES > network_quic::MAX_CHANNEL_FRAME_BYTES
    {
        return Err(ConnectionError::FrameTooLarge);
    }
    Ok(GenericInboundFrame {
        kind,
        payload: encoded[GENERIC_FRAME_HEADER_BYTES..].to_vec(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use network_transport::testkit::WriterGate;
    use network_transport::{TcpTransport, Transport};
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};
    use tokio::task::JoinHandle;
    use tokio::time::{sleep, timeout};

    struct StartedGenericRoute {
        handle: GenericRouteHandle,
        inbound: mpsc::Receiver<GenericInboundFrame>,
        stop: CancellationToken,
        driver: JoinHandle<()>,
        server: TcpStream,
    }

    async fn started_tcp_generic_route() -> StartedGenericRoute {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind generic route test listener");
        let peer = listener
            .local_addr()
            .expect("generic route test listener address");
        let connection = GenericConnection::connect_tcp("0.0.0.0:0".parse().unwrap(), peer)
            .await
            .expect("connect generic route test client");
        let (server, _) = listener
            .accept()
            .await
            .expect("accept generic route test client");
        let runtime = prepare_generic_route(connection);
        let GenericRouteRuntime {
            handle,
            inbound,
            driver,
            ready,
            commit,
            stop,
            ..
        } = runtime;
        let driver = tokio::spawn(driver);
        timeout(Duration::from_secs(1), ready)
            .await
            .expect("generic route driver did not become ready")
            .expect("generic route ready signal dropped");
        commit
            .send(())
            .expect("generic route commit receiver dropped");
        StartedGenericRoute {
            handle,
            inbound,
            stop,
            driver,
            server,
        }
    }

    async fn read_wire_frame(stream: &mut TcpStream) -> Vec<u8> {
        let length = stream
            .read_u32()
            .await
            .expect("read generic route frame length") as usize;
        let mut payload = vec![0u8; length];
        stream
            .read_exact(&mut payload)
            .await
            .expect("read generic route frame payload");
        payload
    }

    async fn write_wire_frame(stream: &mut TcpStream, payload: &[u8]) {
        stream
            .write_u32(payload.len() as u32)
            .await
            .expect("write generic route frame length");
        stream
            .write_all(payload)
            .await
            .expect("write generic route frame payload");
    }

    fn spawn_write_pressure(
        handle: &GenericRouteHandle,
    ) -> Vec<JoinHandle<Result<(), ConnectionError>>> {
        let payload = Arc::new(vec![
            0x5a;
            network_quic::MAX_CHANNEL_FRAME_BYTES
                - GENERIC_FRAME_HEADER_BYTES
        ]);
        (0..256)
            .map(|_| {
                let handle = handle.clone();
                let payload = Arc::clone(&payload);
                tokio::spawn(async move {
                    handle
                        .send(GenericFrameKind::DataMessage, payload.as_slice())
                        .await
                })
            })
            .collect()
    }

    async fn wait_for_pending_write(tasks: &[JoinHandle<Result<(), ConnectionError>>]) {
        timeout(Duration::from_secs(1), async {
            loop {
                if tasks.iter().any(|task| !task.is_finished()) {
                    return;
                }
                sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("generic route test did not create pending writes");
    }

    #[test]
    fn capability_mapping_and_route_selection_are_explicit() {
        assert!(ConnectionProfile::new(Route::direct(RouteTransport::Tcp))
            .supports(ConnectionCapability::ReliableStream));
        assert!(
            ConnectionProfile::new(Route::relay(RouteTransport::WebSocket))
                .supports(ConnectionCapability::ReliableMessage)
        );
        assert!(ConnectionProfile::new(Route::direct(RouteTransport::Udp))
            .supports(ConnectionCapability::UnreliableDatagram));
        assert!(ConnectionProfile::new(Route::direct(RouteTransport::Quic))
            .supports(ConnectionCapability::ReliableStream));

        assert!(!Route::direct(RouteTransport::Udp).supports(ConnectionCapability::ReliableMessage));
        assert_eq!(
            ConnectionRouteSelector::select(
                ConnectionCapability::ReliableStream,
                [
                    RouteCandidate::blocked(Route::direct(RouteTransport::Quic)),
                    RouteCandidate::available(Route::direct(RouteTransport::Tcp)),
                ]
            )
            .expect("TCP fallback")
            .route(),
            Route::direct(RouteTransport::Tcp)
        );
        assert_eq!(
            ConnectionRouteSelector::select(
                ConnectionCapability::ReliableMessage,
                [
                    RouteCandidate::blocked(Route::direct(RouteTransport::Udp)),
                    RouteCandidate::available(Route::relay(RouteTransport::WebSocket)),
                ],
            )
            .expect("WSS fallback")
            .route(),
            Route::relay(RouteTransport::WebSocket)
        );
        assert_eq!(
            ConnectionProfile::for_route(RouteType::Relay)
                .expect("Relay profile")
                .route(),
            Route::relay(RouteTransport::WebSocket)
        );
        assert_eq!(
            Route::direct(RouteTransport::Quic).to_wire(),
            Some(RouteType::QuicDirect)
        );
        assert_eq!(Route::direct(RouteTransport::Tcp).to_wire(), None);
    }

    #[tokio::test]
    async fn generic_connection_lifecycle_and_message_limit_are_enforced() {
        let left_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let right_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let left_addr = left_socket.local_addr().unwrap();
        let right_addr = right_socket.local_addr().unwrap();
        left_socket.connect(right_addr).await.unwrap();
        right_socket.connect(left_addr).await.unwrap();
        let mut left = GenericConnection::from_transport(Transport::Udp(
            network_transport::UdpTransport::from_socket(left_socket, right_addr),
        ));
        let mut right = GenericConnection::from_transport(Transport::Udp(
            network_transport::UdpTransport::from_socket(right_socket, left_addr),
        ));

        assert_eq!(left.send(b"datagram").await.unwrap(), 8);
        assert_eq!(right.recv().await.unwrap(), b"datagram");
        assert!(matches!(
            left.send(&vec![0u8; network_transport::MAX_DATAGRAM_BYTES + 1])
                .await,
            Err(TransportError::FrameTooLarge)
        ));
        left.close().await.unwrap();
        assert!(matches!(
            left.send(b"closed").await,
            Err(TransportError::Closed)
        ));
        right.close().await.unwrap();
    }

    #[tokio::test]
    async fn reliable_stream_wrapper_round_trips_and_shuts_down() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let peer = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut server = GenericConnection::from_transport(Transport::Tcp(
                TcpTransport::from_stream(stream),
            ));
            let payload = server.recv().await.unwrap();
            server.send(&payload).await.unwrap();
            server.close().await.unwrap();
        });

        let mut client = GenericConnection::connect_tcp("0.0.0.0:0".parse().unwrap(), peer)
            .await
            .unwrap();
        assert_eq!(client.route(), Route::direct(RouteTransport::Tcp));
        client.send(b"reliable-stream").await.unwrap();
        assert_eq!(client.recv().await.unwrap(), b"reliable-stream");
        client.close().await.unwrap();
        server.await.unwrap();
    }

    #[tokio::test]
    async fn blocked_write_does_not_stop_inbound_ack_progress() {
        let mut route = started_tcp_generic_route().await;
        let mut server = route.server;
        let pressure = spawn_write_pressure(&route.handle);

        // Let the first write complete, then leave the peer's receive window
        // closed while enough queued frames make the client writer wait.
        let _ = read_wire_frame(&mut server).await;
        wait_for_pending_write(&pressure).await;

        let ack = encode_generic_frame(GenericFrameKind::DeliveryAck, b"ack")
            .expect("encode inbound delivery ack");
        write_wire_frame(&mut server, &ack).await;
        let frame = timeout(Duration::from_secs(1), route.inbound.recv())
            .await
            .expect("inbound ACK was blocked behind writer")
            .expect("generic route inbound channel closed");
        assert_eq!(frame.kind, GenericFrameKind::DeliveryAck);
        assert_eq!(frame.payload, b"ack");

        route.stop.cancel();
        timeout(Duration::from_secs(1), route.driver)
            .await
            .expect("route driver did not stop after cancellation")
            .expect("route driver panicked");
        for task in pressure {
            task.abort();
        }
    }

    /// Deterministic blocked-write proof: a `TransportWriter::send` parked at
    /// the transport level (not merely command-channel backpressure) does not
    /// stall the read half, and completes once the gate is released.
    #[tokio::test]
    async fn blocked_transport_write_delivers_ack_and_completes_after_release() {
        let gate = WriterGate::new();
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind gated route listener");
        let peer = listener.local_addr().expect("gated route peer address");
        let connection = GenericConnection::from_transport(
            Transport::connect_tcp("0.0.0.0:0".parse().unwrap(), peer)
                .await
                .expect("connect gated route client")
                .with_gated_writer(gate.clone()),
        );
        let (mut server, _) = listener.accept().await.expect("accept gated route client");

        let runtime = prepare_generic_route(connection);
        let GenericRouteRuntime {
            handle,
            mut inbound,
            driver,
            ready,
            commit,
            stop,
            ..
        } = runtime;
        let driver = tokio::spawn(driver);
        timeout(Duration::from_secs(1), ready)
            .await
            .expect("gated route driver did not become ready")
            .expect("gated route ready signal dropped");
        commit
            .send(())
            .expect("gated route commit receiver dropped");

        // A caller blocks inside `handle.send` at the transport level.
        let send_task = tokio::spawn({
            let handle = handle.clone();
            async move { handle.send(GenericFrameKind::DataMessage, b"blocked").await }
        });

        // The writer's `send` is provably in-flight and parked on the gate.
        timeout(Duration::from_secs(1), gate.entered())
            .await
            .expect("gated transport write never entered");
        assert!(
            !send_task.is_finished(),
            "send should be blocked at the transport writer"
        );

        // The reader still delivers an inbound ACK while the writer is parked.
        let ack = encode_generic_frame(GenericFrameKind::DeliveryAck, b"ack")
            .expect("encode inbound delivery ack");
        write_wire_frame(&mut server, &ack).await;
        let frame = timeout(Duration::from_secs(1), inbound.recv())
            .await
            .expect("inbound ACK was blocked behind the parked write")
            .expect("generic route inbound channel closed");
        assert_eq!(frame.kind, GenericFrameKind::DeliveryAck);
        assert_eq!(frame.payload, b"ack");

        // Release the gate: the parked write reaches the socket and the caller
        // completes with Ok.
        gate.release();
        let result = timeout(Duration::from_secs(1), send_task)
            .await
            .expect("blocked send did not complete after release")
            .expect("blocked send task panicked");
        assert!(matches!(result, Ok(())), "expected Ok, got {result:?}");

        // The peer observes the exact frame that was parked.
        let received = read_wire_frame(&mut server).await;
        let received = decode_generic_frame(&received).expect("decode released frame");
        assert_eq!(received.kind, GenericFrameKind::DataMessage);
        assert_eq!(received.payload, b"blocked");

        stop.cancel();
        timeout(Duration::from_secs(1), driver)
            .await
            .expect("gated route driver did not stop")
            .expect("gated route driver panicked");
    }

    #[tokio::test]
    async fn inbound_queue_saturation_applies_backpressure_without_closing_route() {
        let mut route = started_tcp_generic_route().await;
        let frame = encode_generic_frame(GenericFrameKind::DataMessage, b"queued")
            .expect("encode inbound data frame");
        for _ in 0..=GENERIC_ROUTE_CHANNEL_CAPACITY {
            write_wire_frame(&mut route.server, &frame).await;
        }

        for _ in 0..=GENERIC_ROUTE_CHANNEL_CAPACITY {
            let received = timeout(Duration::from_secs(1), route.inbound.recv())
                .await
                .expect("inbound queue remained blocked after saturation")
                .expect("generic route closed while queue was saturated");
            assert_eq!(received.kind, GenericFrameKind::DataMessage);
            assert_eq!(received.payload, b"queued");
        }

        // Post-drain usability: after backpressure clears, the route still
        // accepts an outbound frame and still delivers an inbound ACK.
        route
            .handle
            .send(GenericFrameKind::DataMessage, b"after-drain")
            .await
            .expect("route did not accept a frame after drain");
        let received = read_wire_frame(&mut route.server).await;
        let received = decode_generic_frame(&received).expect("decode after-drain frame");
        assert_eq!(received.kind, GenericFrameKind::DataMessage);
        assert_eq!(received.payload, b"after-drain");

        let ack = encode_generic_frame(GenericFrameKind::DeliveryAck, b"post-drain")
            .expect("encode post-drain ack");
        write_wire_frame(&mut route.server, &ack).await;
        let received = timeout(Duration::from_secs(1), route.inbound.recv())
            .await
            .expect("post-drain ACK was blocked")
            .expect("route closed after drain");
        assert_eq!(received.kind, GenericFrameKind::DeliveryAck);
        assert_eq!(received.payload, b"post-drain");

        route.stop.cancel();
        timeout(Duration::from_secs(1), route.driver)
            .await
            .expect("route driver did not stop after queue test")
            .expect("route driver panicked");
    }

    #[tokio::test]
    async fn cancellation_preempts_a_blocked_generic_route_write() {
        let route = started_tcp_generic_route().await;
        let mut server = route.server;
        let pressure = spawn_write_pressure(&route.handle);
        let _ = read_wire_frame(&mut server).await;
        wait_for_pending_write(&pressure).await;

        route.stop.cancel();
        timeout(Duration::from_secs(1), route.driver)
            .await
            .expect("cancellation did not preempt the blocked route write")
            .expect("route driver panicked");
        let mut remaining = [0u8; 64 * 1024];
        timeout(Duration::from_secs(1), async {
            loop {
                let read = server
                    .read(&mut remaining)
                    .await
                    .expect("server read cancelled route");
                if read == 0 {
                    break;
                }
            }
        })
        .await
        .expect("server did not observe cancelled route close");
        for task in pressure {
            task.abort();
        }
    }

    /// Deterministic cancellation of an in-flight transport write: a caller
    /// blocked inside `handle.send` at the transport writer resolves promptly
    /// to `ConnectionError::Cancelled` when the route is cancelled.
    #[tokio::test]
    async fn cancellation_resolves_a_caller_blocked_in_transport_write() {
        let gate = WriterGate::new();
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind cancellation listener");
        let peer = listener.local_addr().expect("cancellation peer address");
        let connection = GenericConnection::from_transport(
            Transport::connect_tcp("0.0.0.0:0".parse().unwrap(), peer)
                .await
                .expect("connect cancellation client")
                .with_gated_writer(gate.clone()),
        );
        let (_server, _) = listener.accept().await.expect("accept cancellation client");

        let runtime = prepare_generic_route(connection);
        let GenericRouteRuntime {
            handle,
            driver,
            ready,
            commit,
            stop,
            ..
        } = runtime;
        let driver = tokio::spawn(driver);
        timeout(Duration::from_secs(1), ready)
            .await
            .expect("cancellation route driver not ready")
            .expect("cancellation route ready signal dropped");
        commit
            .send(())
            .expect("cancellation route commit receiver dropped");

        let send_task = tokio::spawn({
            let handle = handle.clone();
            async move { handle.send(GenericFrameKind::DataMessage, b"blocked").await }
        });
        timeout(Duration::from_secs(1), gate.entered())
            .await
            .expect("gated write never entered the transport");
        assert!(
            !send_task.is_finished(),
            "send should be blocked at the transport writer"
        );

        // Cancelling the route preempts the in-flight transport write and the
        // blocked caller resolves promptly to Cancelled.
        stop.cancel();
        let result = timeout(Duration::from_secs(1), send_task)
            .await
            .expect("cancelled send caller did not resolve")
            .expect("cancelled send task panicked");
        assert!(
            matches!(result, Err(ConnectionError::Cancelled)),
            "expected Cancelled, got {result:?}"
        );

        timeout(Duration::from_secs(1), driver)
            .await
            .expect("route driver did not stop after cancellation")
            .expect("route driver panicked");
    }

    #[tokio::test]
    async fn route_shutdown_releases_socket_for_a_replacement_route() {
        let first = started_tcp_generic_route().await;
        let mut first_server = first.server;
        first.stop.cancel();
        timeout(Duration::from_secs(1), first.driver)
            .await
            .expect("first route did not shut down")
            .expect("first route driver panicked");
        let mut byte = [0u8; 1];
        assert_eq!(
            timeout(Duration::from_secs(1), first_server.read(&mut byte))
                .await
                .expect("first route socket did not close")
                .expect("read first route shutdown"),
            0
        );

        let replacement = started_tcp_generic_route().await;
        let mut replacement_server = replacement.server;
        replacement
            .handle
            .send(GenericFrameKind::DataMessage, b"replacement")
            .await
            .expect("replacement route did not accept a frame");
        let received = read_wire_frame(&mut replacement_server).await;
        let received = decode_generic_frame(&received).expect("decode replacement frame");
        assert_eq!(received.kind, GenericFrameKind::DataMessage);
        assert_eq!(received.payload, b"replacement");
        replacement.stop.cancel();
        timeout(Duration::from_secs(1), replacement.driver)
            .await
            .expect("replacement route did not shut down")
            .expect("replacement route driver panicked");
    }
}
