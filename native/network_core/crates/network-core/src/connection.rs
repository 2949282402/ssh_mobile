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
                ConnectionCapability::ReliableStream
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

    /// Returns the existing event projection when one is defined. New generic
    /// routes stay native-composed until the public event contract gains
    /// separate topology and transport fields.
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
        let transport = match kind {
            TransportKind::Tcp => RouteTransport::Tcp,
            TransportKind::Udp => RouteTransport::Udp,
            TransportKind::WebSocket => RouteTransport::WebSocket,
        };
        Self::new(Route::direct(transport))
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

    pub fn route(&self) -> Route {
        self.profile.route()
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
}
