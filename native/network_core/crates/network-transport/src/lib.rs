//! Generic native transport primitives.
//!
//! The crate deliberately stops at transport semantics: TCP provides bounded
//! framed streams, UDP provides connected datagrams, and WebSocket provides
//! binary messages. Session identity, Delivery/Recovery, application E2EE, and
//! route selection remain owned by higher layers.
//!
//! [`Transport::into_split`] is available for every transport, including UDP.
//! UDP remains a datagram primitive only: it is not eligible for acknowledged,
//! ordered, or file-delivery (reliable-message) generic routes.

mod tcp;
mod udp;
mod websocket;

#[cfg(feature = "testkit")]
pub mod testkit;

pub use tcp::{TcpTransport, MAX_STREAM_FRAME_BYTES};
pub use udp::{UdpTransport, MAX_DATAGRAM_BYTES};
pub use websocket::{WebSocketTransport, MAX_WEBSOCKET_MESSAGE_BYTES};

use tcp::{TcpReader, TcpWriter};
use udp::{UdpReader, UdpWriter};
use websocket::{WebSocketReader, WebSocketWriter};

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
    /// Test-only deterministic write gate. Compiled only with `testkit`.
    #[cfg(feature = "testkit")]
    Gated(Box<testkit::GatedTransport>),
}

enum TransportReaderKind {
    Tcp(TcpReader),
    Udp(UdpReader),
    WebSocket(WebSocketReader),
}

/// Read half of a generic transport. It owns no write-side state, so a
/// blocked writer cannot prevent the carrier from receiving ACK/Data frames.
pub struct TransportReader {
    inner: TransportReaderKind,
}

enum TransportWriterKind {
    Tcp(TcpWriter),
    Udp(UdpWriter),
    WebSocket(WebSocketWriter),
    #[cfg(feature = "testkit")]
    Gated(testkit::GatedWriter),
}

/// Write half of a generic transport. Dropping it cancels an in-flight write
/// by dropping the underlying Tokio/Futures I/O future and socket half.
pub struct TransportWriter {
    inner: TransportWriterKind,
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
            #[cfg(feature = "testkit")]
            Self::Gated(transport) => transport.kind(),
        }
    }

    /// Wraps any transport writer with a deterministic write gate for tests.
    ///
    /// Compiled only with the `testkit` feature and never used in production.
    /// The returned transport keeps a real reader half and parks the first
    /// `send` on the supplied gate, so a test can prove an in-flight write does
    /// not stall the read half and that cancellation preempts it.
    #[cfg(feature = "testkit")]
    pub fn with_gated_writer(self, gate: testkit::WriterGate) -> Self {
        let kind = self.kind();
        let (reader, writer) = self.into_split();
        Self::Gated(Box::new(testkit::GatedTransport {
            kind,
            reader,
            writer: testkit::GatedWriter {
                inner: Box::new(writer.inner),
                gate,
            },
        }))
    }

    /// Splits the carrier into independently polled read and write halves.
    /// Framing and size limits remain identical to the unsplit surface.
    ///
    /// For UDP the two halves share the connected socket, so closing one half
    /// releases only that half's reference; the other half keeps delivering
    /// datagrams until it is dropped. UDP is a datagram primitive only and is
    /// not eligible for reliable-message generic routes.
    pub fn into_split(self) -> (TransportReader, TransportWriter) {
        match self {
            Self::Tcp(transport) => {
                let (reader, writer) = transport.into_split();
                (
                    TransportReader {
                        inner: TransportReaderKind::Tcp(reader),
                    },
                    TransportWriter {
                        inner: TransportWriterKind::Tcp(writer),
                    },
                )
            }
            Self::Udp(transport) => {
                let (reader, writer) = transport.into_split();
                (
                    TransportReader {
                        inner: TransportReaderKind::Udp(reader),
                    },
                    TransportWriter {
                        inner: TransportWriterKind::Udp(writer),
                    },
                )
            }
            Self::WebSocket(transport) => {
                let (reader, writer) = transport.into_split();
                (
                    TransportReader {
                        inner: TransportReaderKind::WebSocket(reader),
                    },
                    TransportWriter {
                        inner: TransportWriterKind::WebSocket(writer),
                    },
                )
            }
            #[cfg(feature = "testkit")]
            Self::Gated(transport) => transport.into_split(),
        }
    }

    /// Sends one logical payload using the selected transport's bounded frame.
    pub async fn send(&mut self, payload: &[u8]) -> Result<usize, TransportError> {
        match self {
            Self::Tcp(transport) => transport.send_frame(payload).await,
            Self::Udp(transport) => transport.send_datagram(payload).await,
            Self::WebSocket(transport) => transport.send_binary(payload).await,
            #[cfg(feature = "testkit")]
            Self::Gated(transport) => transport.send(payload).await,
        }
    }

    /// Receives one logical payload; UDP preserves datagram boundaries.
    pub async fn recv(&mut self) -> Result<Vec<u8>, TransportError> {
        match self {
            Self::Tcp(transport) => transport.recv_frame().await,
            Self::Udp(transport) => transport.recv_datagram().await,
            Self::WebSocket(transport) => transport.recv_binary().await,
            #[cfg(feature = "testkit")]
            Self::Gated(transport) => transport.recv().await,
        }
    }

    pub async fn close(&mut self) -> Result<(), TransportError> {
        match self {
            Self::Tcp(transport) => transport.close().await,
            Self::Udp(transport) => transport.close().await,
            Self::WebSocket(transport) => transport.close().await,
            #[cfg(feature = "testkit")]
            Self::Gated(transport) => transport.close().await,
        }
    }
}

impl TransportReader {
    pub async fn recv(&mut self) -> Result<Vec<u8>, TransportError> {
        match &mut self.inner {
            TransportReaderKind::Tcp(reader) => reader.recv_frame().await,
            TransportReaderKind::Udp(reader) => reader.recv_datagram().await,
            TransportReaderKind::WebSocket(reader) => websocket::recv_binary(reader).await,
        }
    }
}

impl TransportWriter {
    pub async fn send(&mut self, payload: &[u8]) -> Result<usize, TransportError> {
        match &mut self.inner {
            TransportWriterKind::Tcp(writer) => writer.send_frame(payload).await,
            TransportWriterKind::Udp(writer) => writer.send_datagram(payload).await,
            TransportWriterKind::WebSocket(writer) => websocket::send_binary(writer, payload).await,
            #[cfg(feature = "testkit")]
            TransportWriterKind::Gated(writer) => writer.send(payload).await,
        }
    }

    pub async fn close(&mut self) -> Result<(), TransportError> {
        match &mut self.inner {
            TransportWriterKind::Tcp(writer) => writer.close().await,
            TransportWriterKind::Udp(writer) => writer.close().await,
            TransportWriterKind::WebSocket(writer) => websocket::close(writer).await,
            #[cfg(feature = "testkit")]
            TransportWriterKind::Gated(writer) => writer.close().await,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::AsyncWriteExt;
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

    #[tokio::test]
    async fn transport_rejects_oversized_frames_and_closed_udp_writes() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let peer = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            stream
                .write_u32((MAX_STREAM_FRAME_BYTES as u32).saturating_add(1))
                .await
                .unwrap();
        });
        let mut tcp = TcpTransport::connect("0.0.0.0:0".parse().unwrap(), peer)
            .await
            .unwrap();
        assert!(matches!(
            tcp.send_frame(&vec![0; MAX_STREAM_FRAME_BYTES + 1]).await,
            Err(TransportError::FrameTooLarge)
        ));
        assert!(matches!(
            tcp.recv_frame().await,
            Err(TransportError::FrameTooLarge)
        ));
        server.await.unwrap();

        let left_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let right_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let right_addr = right_socket.local_addr().unwrap();
        left_socket.connect(right_addr).await.unwrap();
        let mut udp = UdpTransport::from_socket(left_socket, right_addr);
        assert!(matches!(
            udp.send_datagram(&[]).await,
            Err(TransportError::FrameTooLarge)
        ));
        assert!(matches!(
            udp.send_datagram(&vec![0; MAX_DATAGRAM_BYTES + 1]).await,
            Err(TransportError::FrameTooLarge)
        ));
        udp.close().await.unwrap();
        assert!(matches!(
            udp.send_datagram(b"closed").await,
            Err(TransportError::Closed)
        ));
        assert!(matches!(
            udp.recv_datagram().await,
            Err(TransportError::Closed)
        ));
    }

    #[tokio::test]
    async fn websocket_rejects_invalid_urls_and_binary_boundaries() {
        assert!(matches!(
            WebSocketTransport::connect("http://127.0.0.1:1").await,
            Err(TransportError::InvalidUrl)
        ));
        assert!(matches!(
            WebSocketTransport::connect("ws://[invalid").await,
            Err(TransportError::InvalidUrl)
        ));

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let peer = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
            let _ = futures_util::StreamExt::next(&mut socket).await;
        });
        let mut websocket = WebSocketTransport::connect(&format!("ws://{peer}/transport"))
            .await
            .unwrap();
        assert!(matches!(
            websocket.send_binary(&[]).await,
            Err(TransportError::FrameTooLarge)
        ));
        assert!(matches!(
            websocket
                .send_binary(&vec![0; MAX_WEBSOCKET_MESSAGE_BYTES + 1])
                .await,
            Err(TransportError::FrameTooLarge)
        ));
        websocket.close().await.unwrap();
        server.await.unwrap();
    }

    #[tokio::test]
    async fn websocket_split_halves_deliver_duplex_binary_frames() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let peer = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
            // Echo the first binary message back to the client.
            if let Some(Ok(Message::Binary(payload))) =
                futures_util::StreamExt::next(&mut socket).await
            {
                futures_util::SinkExt::send(&mut socket, Message::Binary(payload))
                    .await
                    .unwrap();
            }
        });

        let transport = Transport::connect_websocket(&format!("ws://{peer}/v1/transport"))
            .await
            .unwrap();
        let (mut reader, mut writer) = transport.into_split();
        // The halves are independent: send and receive concurrently (duplex).
        let write = tokio::spawn(async move { writer.send(b"websocket-split").await });
        let received = tokio::time::timeout(Duration::from_secs(2), reader.recv())
            .await
            .expect("split reader did not receive the echo")
            .unwrap();
        assert_eq!(received, b"websocket-split");
        assert_eq!(
            write.await.expect("split writer task panicked").unwrap(),
            b"websocket-split".len()
        );
        server.await.unwrap();
    }

    /// A gated WebSocket write parks inside `send` without blocking the read
    /// half, and cancelling the in-flight write (dropping the send future)
    /// does not disturb the reader's independent delivery.
    #[cfg(feature = "testkit")]
    #[tokio::test]
    async fn websocket_cancelled_write_keeps_the_reader_half_live() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let peer = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
            // Push an independent frame, then hold the socket open until the
            // test ends so the reader has a deterministic delivery target.
            futures_util::SinkExt::send(
                &mut socket,
                Message::Binary(b"server-push".to_vec().into()),
            )
            .await
            .unwrap();
            let _ = futures_util::StreamExt::next(&mut socket).await;
        });

        let gate = crate::testkit::WriterGate::new();
        let transport = Transport::connect_websocket(&format!("ws://{peer}/v1/transport"))
            .await
            .unwrap();
        let (mut reader, mut writer) = transport.with_gated_writer(gate.clone()).into_split();

        // Provably park a write inside TransportWriter::send.
        let write_task = tokio::spawn(async move { writer.send(b"parked").await });
        gate.entered().await;
        assert!(
            !write_task.is_finished(),
            "gated WebSocket write is not blocked in-flight"
        );

        // Cancelling the in-flight write does not disturb the read half.
        write_task.abort();
        let pushed = tokio::time::timeout(Duration::from_secs(2), reader.recv())
            .await
            .expect("reader was blocked after the write was cancelled")
            .unwrap();
        assert_eq!(pushed, b"server-push");

        // Releasing the reader half drops the last shared stream reference, so
        // the socket closes and the server task can observe the connection end.
        drop(reader);
        tokio::time::timeout(Duration::from_secs(2), server)
            .await
            .expect("server did not observe the client release")
            .expect("server task panicked");
    }

    #[tokio::test]
    async fn udp_split_halves_share_the_connected_datagram_socket() {
        let left_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let right_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let left_addr = left_socket.local_addr().unwrap();
        let right_addr = right_socket.local_addr().unwrap();
        left_socket.connect(right_addr).await.unwrap();
        right_socket.connect(left_addr).await.unwrap();
        let left = Transport::Udp(UdpTransport::from_socket(left_socket, right_addr));
        let right = Transport::Udp(UdpTransport::from_socket(right_socket, left_addr));

        let (mut left_reader, mut left_writer) = left.into_split();
        let (mut right_reader, mut right_writer) = right.into_split();

        // Split halves preserve datagram boundaries and full-duplex flow.
        assert_eq!(
            left_writer.send(b"split-datagram").await.unwrap(),
            b"split-datagram".len()
        );
        assert_eq!(right_reader.recv().await.unwrap(), b"split-datagram");
        assert_eq!(right_writer.send(b"reply").await.unwrap(), b"reply".len());
        assert_eq!(left_reader.recv().await.unwrap(), b"reply");

        // Closing the writer half releases only that half's Arc reference; the
        // reader half keeps delivering until it is also dropped.
        left_writer.close().await.unwrap();
        assert!(matches!(
            left_writer.send(b"after-close").await,
            Err(TransportError::Closed)
        ));
        assert_eq!(
            right_writer.send(b"still-live").await.unwrap(),
            b"still-live".len()
        );
        assert_eq!(left_reader.recv().await.unwrap(), b"still-live");
        right_writer.close().await.unwrap();
    }
}
