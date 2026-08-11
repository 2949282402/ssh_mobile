//! Connection-layer capabilities shared by route selection and generic native
//! transport primitives.
//!
//! This layer deliberately does not own a Session, Delivery queue, or
//! application payload. It translates the transport primitive into a stable
//! capability and lets higher layers choose a route without depending on a
//! concrete TCP/UDP/WebSocket implementation.

use network_protocol::RouteType;
use network_transport::{Transport, TransportError, TransportKind};
use std::net::SocketAddr;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionTransportKind {
    Tcp,
    Udp,
    WebSocket,
    Quic,
    Relay,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionCapability {
    ReliableStream,
    ReliableMessage,
    UnreliableDatagram,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConnectionProfile {
    transport: ConnectionTransportKind,
}

impl ConnectionProfile {
    pub const fn new(transport: ConnectionTransportKind) -> Self {
        Self { transport }
    }

    pub const fn transport(self) -> ConnectionTransportKind {
        self.transport
    }

    pub const fn supports(self, capability: ConnectionCapability) -> bool {
        matches!(
            (self.transport, capability),
            (
                ConnectionTransportKind::Tcp,
                ConnectionCapability::ReliableStream
            ) | (
                ConnectionTransportKind::Quic,
                ConnectionCapability::ReliableStream
            ) | (
                ConnectionTransportKind::Relay,
                ConnectionCapability::ReliableMessage
            ) | (
                ConnectionTransportKind::WebSocket,
                ConnectionCapability::ReliableMessage
            ) | (
                ConnectionTransportKind::Udp,
                ConnectionCapability::UnreliableDatagram
            ) | (
                ConnectionTransportKind::Quic,
                ConnectionCapability::UnreliableDatagram
            )
        )
    }

    pub const fn for_route(route: RouteType) -> Option<Self> {
        match route {
            RouteType::QuicDirect | RouteType::Lan => {
                Some(Self::new(ConnectionTransportKind::Quic))
            }
            RouteType::Relay => Some(Self::new(ConnectionTransportKind::Relay)),
            RouteType::Unspecified => None,
        }
    }

    pub const fn for_generic(kind: TransportKind) -> Self {
        let transport = match kind {
            TransportKind::Tcp => ConnectionTransportKind::Tcp,
            TransportKind::Udp => ConnectionTransportKind::Udp,
            TransportKind::WebSocket => ConnectionTransportKind::WebSocket,
        };
        Self::new(transport)
    }
}

/// Selects the first route that actually advertises the requested capability.
/// Candidate order is supplied by the Session/Route owner, so this helper does
/// not invent a second priority or retry policy.
pub struct ConnectionRouteSelector;

impl ConnectionRouteSelector {
    pub fn select(
        capability: ConnectionCapability,
        candidates: impl IntoIterator<Item = ConnectionTransportKind>,
    ) -> Option<ConnectionProfile> {
        candidates
            .into_iter()
            .map(ConnectionProfile::new)
            .find(|profile| profile.supports(capability))
    }
}

/// Owns one generic primitive connection. QUIC and Relay remain Session-owned
/// routes because their authentication, Delivery, and recovery state are
/// managed by `network-core`; this wrapper only proves the generic transport
/// boundary is usable by the Connection layer.
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

    pub async fn send(&mut self, payload: &[u8]) -> Result<usize, TransportError> {
        self.transport.send(payload).await
    }

    pub async fn recv(&mut self) -> Result<Vec<u8>, TransportError> {
        self.transport.recv().await
    }

    pub async fn close(&mut self) -> Result<(), TransportError> {
        self.transport.close().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use network_transport::{TcpTransport, Transport};
    use tokio::net::TcpListener;

    #[test]
    fn capability_mapping_and_route_selection_are_explicit() {
        assert!(ConnectionProfile::new(ConnectionTransportKind::Tcp)
            .supports(ConnectionCapability::ReliableStream));
        assert!(ConnectionProfile::new(ConnectionTransportKind::WebSocket)
            .supports(ConnectionCapability::ReliableMessage));
        assert!(ConnectionProfile::new(ConnectionTransportKind::Udp)
            .supports(ConnectionCapability::UnreliableDatagram));
        assert!(ConnectionProfile::new(ConnectionTransportKind::Quic)
            .supports(ConnectionCapability::ReliableStream));

        assert_eq!(
            ConnectionRouteSelector::select(
                ConnectionCapability::ReliableStream,
                [ConnectionTransportKind::Udp, ConnectionTransportKind::Tcp]
            )
            .expect("TCP fallback")
            .transport(),
            ConnectionTransportKind::Tcp
        );
        assert_eq!(
            ConnectionProfile::for_route(RouteType::Relay)
                .expect("Relay profile")
                .transport(),
            ConnectionTransportKind::Relay
        );
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
        assert_eq!(client.profile().transport(), ConnectionTransportKind::Tcp);
        client.send(b"reliable-stream").await.unwrap();
        assert_eq!(client.recv().await.unwrap(), b"reliable-stream");
        client.close().await.unwrap();
        server.await.unwrap();
    }
}
