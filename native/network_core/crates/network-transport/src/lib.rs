//! Generic native transport primitives.
//!
//! The crate deliberately stops at transport semantics: TCP provides bounded
//! framed streams, UDP provides connected datagrams, and WebSocket provides
//! binary messages. Session identity, Delivery/Recovery, application E2EE, and
//! route selection remain owned by higher layers.

mod tcp;
mod udp;
mod websocket;

pub use tcp::{TcpTransport, MAX_STREAM_FRAME_BYTES};
pub use udp::{UdpTransport, MAX_DATAGRAM_BYTES};
pub use websocket::{WebSocketTransport, MAX_WEBSOCKET_MESSAGE_BYTES};

use std::net::SocketAddr;

/// Stable transport kind for diagnostics and route policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportKind {
    Tcp,
    Udp,
    WebSocket,
}

/// Errors shared by all generic transport implementations.
#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("transport is closed")]
    Closed,
    #[error("transport frame is too large")]
    FrameTooLarge,
    #[error("transport frame is invalid")]
    InvalidFrame,
    #[error("transport URL is invalid")]
    InvalidUrl,
    #[error("transport I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("transport WebSocket operation failed: {0}")]
    WebSocket(String),
}

/// A common native send/receive surface with per-transport framing semantics.
pub enum Transport {
    Tcp(TcpTransport),
    Udp(UdpTransport),
    WebSocket(Box<WebSocketTransport>),
}

impl Transport {
    pub async fn connect_tcp(local: SocketAddr, peer: SocketAddr) -> Result<Self, TransportError> {
        Ok(Self::Tcp(TcpTransport::connect(local, peer).await?))
    }

    pub async fn bind_udp(local: SocketAddr, peer: SocketAddr) -> Result<Self, TransportError> {
        Ok(Self::Udp(UdpTransport::bind(local, peer).await?))
    }

    pub async fn connect_websocket(url: &str) -> Result<Self, TransportError> {
        Ok(Self::WebSocket(Box::new(
            WebSocketTransport::connect(url).await?,
        )))
    }

    pub fn kind(&self) -> TransportKind {
        match self {
            Self::Tcp(_) => TransportKind::Tcp,
            Self::Udp(_) => TransportKind::Udp,
            Self::WebSocket(_) => TransportKind::WebSocket,
        }
    }

    /// Sends one logical payload using the selected transport's bounded frame.
    pub async fn send(&mut self, payload: &[u8]) -> Result<usize, TransportError> {
        match self {
            Self::Tcp(transport) => transport.send_frame(payload).await,
            Self::Udp(transport) => transport.send_datagram(payload).await,
            Self::WebSocket(transport) => transport.send_binary(payload).await,
        }
    }

    /// Receives one logical payload; UDP preserves datagram boundaries.
    pub async fn recv(&mut self) -> Result<Vec<u8>, TransportError> {
        match self {
            Self::Tcp(transport) => transport.recv_frame().await,
            Self::Udp(transport) => transport.recv_datagram().await,
            Self::WebSocket(transport) => transport.recv_binary().await,
        }
    }

    pub async fn close(&mut self) -> Result<(), TransportError> {
        match self {
            Self::Tcp(transport) => transport.close().await,
            Self::Udp(transport) => transport.close().await,
            Self::WebSocket(transport) => transport.close().await,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;
    use tokio_tungstenite::{accept_async, tungstenite::Message, WebSocketStream};

    #[tokio::test]
    async fn tcp_transport_round_trips_bounded_frames() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let peer = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut transport = TcpTransport::from_stream(stream);
            let frame = transport.recv_frame().await.unwrap();
            transport.send_frame(&frame).await.unwrap();
        });

        let mut transport = TcpTransport::connect("0.0.0.0:0".parse().unwrap(), peer)
            .await
            .unwrap();
        assert_eq!(transport.send_frame(b"tcp-frame").await.unwrap(), 9);
        assert_eq!(transport.recv_frame().await.unwrap(), b"tcp-frame");
        transport.close().await.unwrap();
        server.await.unwrap();
    }

    #[tokio::test]
    async fn udp_transport_round_trips_datagrams_without_stream_framing() {
        // A connected UDP socket needs a known peer. Build the pair from two
        // sockets so the test also exercises source filtering.
        let left_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let right_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let left_addr = left_socket.local_addr().unwrap();
        let right_addr = right_socket.local_addr().unwrap();
        left_socket.connect(right_addr).await.unwrap();
        right_socket.connect(left_addr).await.unwrap();
        let mut left = UdpTransport::from_socket(left_socket, right_addr);
        let mut right = UdpTransport::from_socket(right_socket, left_addr);

        assert_eq!(left.send_datagram(b"udp-datagram").await.unwrap(), 12);
        assert_eq!(right.recv_datagram().await.unwrap(), b"udp-datagram");
        assert_eq!(right.send_datagram(b"reply").await.unwrap(), 5);
        assert_eq!(left.recv_datagram().await.unwrap(), b"reply");
        left.close().await.unwrap();
        right.close().await.unwrap();
    }

    #[tokio::test]
    async fn websocket_transport_round_trips_binary_messages() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let peer = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
            if let Some(Ok(Message::Binary(payload))) =
                futures_util::StreamExt::next(&mut socket).await
            {
                futures_util::SinkExt::send(&mut socket, Message::Binary(payload))
                    .await
                    .unwrap();
            }
        });

        let mut transport = WebSocketTransport::connect(&format!("ws://{peer}/v1/transport"))
            .await
            .unwrap();
        assert_eq!(
            transport.send_binary(b"websocket-message").await.unwrap(),
            17
        );
        assert_eq!(transport.recv_binary().await.unwrap(), b"websocket-message");
        transport.close().await.unwrap();
        server.await.unwrap();
    }

    #[tokio::test]
    async fn common_transport_reports_its_kind() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let peer = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = listener.accept().await.unwrap();
        });
        let transport = Transport::connect_tcp("0.0.0.0:0".parse().unwrap(), peer)
            .await
            .unwrap();
        assert_eq!(transport.kind(), TransportKind::Tcp);
        server.await.unwrap();
    }
}
