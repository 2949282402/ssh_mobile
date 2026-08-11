use crate::TransportError;
use std::net::SocketAddr;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpSocket, TcpStream};

/// Maximum logical TCP frame accepted by the generic transport.
pub const MAX_STREAM_FRAME_BYTES: usize = 4 * 1024 * 1024;

/// TCP transport with a fixed four-byte big-endian length prefix.
pub struct TcpTransport {
    stream: TcpStream,
}

impl TcpTransport {
    pub async fn connect(local: SocketAddr, peer: SocketAddr) -> Result<Self, TransportError> {
        let stream = if local.ip().is_unspecified() && local.port() == 0 {
            TcpStream::connect(peer).await?
        } else {
            let socket = if peer.is_ipv4() {
                TcpSocket::new_v4()?
            } else {
                TcpSocket::new_v6()?
            };
            socket.bind(local)?;
            socket.connect(peer).await?
        };
        Ok(Self { stream })
    }

    pub fn from_stream(stream: TcpStream) -> Self {
        Self { stream }
    }

    pub async fn send_frame(&mut self, payload: &[u8]) -> Result<usize, TransportError> {
        if payload.len() > MAX_STREAM_FRAME_BYTES {
            return Err(TransportError::FrameTooLarge);
        }
        self.stream
            .write_u32(payload.len() as u32)
            .await
            .map_err(TransportError::Io)?;
        self.stream.write_all(payload).await?;
        Ok(payload.len())
    }

    pub async fn recv_frame(&mut self) -> Result<Vec<u8>, TransportError> {
        let length = self.stream.read_u32().await.map_err(TransportError::Io)? as usize;
        if length > MAX_STREAM_FRAME_BYTES {
            return Err(TransportError::FrameTooLarge);
        }
        let mut payload = vec![0u8; length];
        self.stream.read_exact(&mut payload).await?;
        Ok(payload)
    }

    pub async fn close(&mut self) -> Result<(), TransportError> {
        self.stream.shutdown().await.map_err(TransportError::Io)
    }
}
