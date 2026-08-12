use crate::TransportError;
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpStream;
use tokio_tungstenite::{
    accept_async, connect_async,
    tungstenite::{client::IntoClientRequest, Message},
    MaybeTlsStream, WebSocketStream,
};
use url::Url;

/// Maximum binary WebSocket message accepted by the generic transport.
pub const MAX_WEBSOCKET_MESSAGE_BYTES: usize = 512 * 1024;

pub struct WebSocketTransport {
    socket: WebSocketStream<MaybeTlsStream<TcpStream>>,
}

impl WebSocketTransport {
    pub async fn connect(url: &str) -> Result<Self, TransportError> {
        let parsed = Url::parse(url).map_err(|_| TransportError::InvalidUrl)?;
        if !matches!(parsed.scheme(), "ws" | "wss") {
            return Err(TransportError::InvalidUrl);
        }
        let request = url
            .into_client_request()
            .map_err(|_| TransportError::InvalidUrl)?;
        let (socket, _) = connect_async(request)
            .await
            .map_err(|error| TransportError::WebSocket(error.to_string()))?;
        Ok(Self { socket })
    }

    /// Accepts a binary WebSocket on the runtime's shared TCP listener. The
    /// caller is responsible for dispatching HTTP-looking connections here;
    /// identity authentication still belongs to `network-core`.
    pub async fn accept(stream: TcpStream) -> Result<Self, TransportError> {
        let socket = accept_async(MaybeTlsStream::Plain(stream))
            .await
            .map_err(|error| TransportError::WebSocket(error.to_string()))?;
        Ok(Self { socket })
    }

    pub async fn send_binary(&mut self, payload: &[u8]) -> Result<usize, TransportError> {
        if payload.is_empty() || payload.len() > MAX_WEBSOCKET_MESSAGE_BYTES {
            return Err(TransportError::FrameTooLarge);
        }
        self.socket
            .send(Message::Binary(payload.to_vec().into()))
            .await
            .map_err(|error| TransportError::WebSocket(error.to_string()))?;
        Ok(payload.len())
    }

    pub async fn recv_binary(&mut self) -> Result<Vec<u8>, TransportError> {
        while let Some(message) = self.socket.next().await {
            let message = message.map_err(|error| TransportError::WebSocket(error.to_string()))?;
            match message {
                Message::Binary(payload) if payload.len() <= MAX_WEBSOCKET_MESSAGE_BYTES => {
                    return Ok(payload.to_vec());
                }
                Message::Binary(_) => return Err(TransportError::FrameTooLarge),
                Message::Close(_) => return Err(TransportError::Closed),
                Message::Ping(_) | Message::Pong(_) => {}
                Message::Text(_) | Message::Frame(_) => {
                    return Err(TransportError::InvalidFrame);
                }
            }
        }
        Err(TransportError::Closed)
    }

    pub async fn close(&mut self) -> Result<(), TransportError> {
        self.socket
            .close(None)
            .await
            .map_err(|error| TransportError::WebSocket(error.to_string()))
    }
}
