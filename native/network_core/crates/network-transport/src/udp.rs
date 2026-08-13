use crate::TransportError;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::UdpSocket;

/// Maximum generic UDP datagram accepted by the transport.
pub const MAX_DATAGRAM_BYTES: usize = 64 * 1024;

/// Connected UDP transport. The OS filters receives to the configured peer.
pub struct UdpTransport {
    socket: Option<UdpSocket>,
    peer: SocketAddr,
}

pub(crate) struct UdpReader {
    socket: Option<Arc<UdpSocket>>,
}

pub(crate) struct UdpWriter {
    socket: Option<Arc<UdpSocket>>,
}

impl UdpTransport {
    pub async fn bind(local: SocketAddr, peer: SocketAddr) -> Result<Self, TransportError> {
        let socket = UdpSocket::bind(local).await?;
        socket.connect(peer).await?;
        Ok(Self {
            socket: Some(socket),
            peer,
        })
    }

    pub fn from_socket(socket: UdpSocket, peer: SocketAddr) -> Self {
        Self {
            socket: Some(socket),
            peer,
        }
    }

    pub fn peer_addr(&self) -> SocketAddr {
        self.peer
    }

    pub(crate) fn into_split(self) -> (UdpReader, UdpWriter) {
        let socket = self.socket.map(Arc::new);
        (
            UdpReader {
                socket: socket.clone(),
            },
            UdpWriter { socket },
        )
    }

    pub async fn send_datagram(&self, payload: &[u8]) -> Result<usize, TransportError> {
        if payload.is_empty() || payload.len() > MAX_DATAGRAM_BYTES {
            return Err(TransportError::FrameTooLarge);
        }
        self.socket
            .as_ref()
            .ok_or(TransportError::Closed)?
            .send(payload)
            .await
            .map_err(TransportError::Io)
    }

    pub async fn recv_datagram(&self) -> Result<Vec<u8>, TransportError> {
        let mut payload = vec![0u8; MAX_DATAGRAM_BYTES];
        let length = self
            .socket
            .as_ref()
            .ok_or(TransportError::Closed)?
            .recv(&mut payload)
            .await?;
        payload.truncate(length);
        Ok(payload)
    }

    pub async fn close(&mut self) -> Result<(), TransportError> {
        self.socket.take();
        Ok(())
    }
}

impl UdpReader {
    pub(crate) async fn recv_datagram(&self) -> Result<Vec<u8>, TransportError> {
        let mut payload = vec![0u8; MAX_DATAGRAM_BYTES];
        let length = self
            .socket
            .as_ref()
            .ok_or(TransportError::Closed)?
            .recv(&mut payload)
            .await?;
        payload.truncate(length);
        Ok(payload)
    }
}

impl UdpWriter {
    pub(crate) async fn send_datagram(&self, payload: &[u8]) -> Result<usize, TransportError> {
        if payload.is_empty() || payload.len() > MAX_DATAGRAM_BYTES {
            return Err(TransportError::FrameTooLarge);
        }
        self.socket
            .as_ref()
            .ok_or(TransportError::Closed)?
            .send(payload)
            .await
            .map_err(TransportError::Io)
    }

    pub(crate) async fn close(&mut self) -> Result<(), TransportError> {
        self.socket.take();
        Ok(())
    }
}
