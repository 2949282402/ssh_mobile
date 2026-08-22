//! QUIC 单向应用通道帧。
//!
//! 文件传输继续使用独立的双向 stream；Delivery 消息使用单向 stream，
//! 这样文件协议和应用信封不会因为各自演进而互相误解析。每次重连只
//! 重新建立 stream，真正的 MessageId、Sequence 和 RecoveryEpoch 由上层
//! DataMessage 持有。

use network_protocol::NETWORK_PROTOCOL_VERSION;
use quinn::{Connection, RecvStream, SendStream};
use std::io::{Error, ErrorKind};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const CHANNEL_MAGIC: &[u8; 4] = b"SMCH";
pub const MAX_CHANNEL_FRAME_BYTES: usize = 48 * 1024;

/// 应用通道内的两类非业务 transport frame。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ChannelFrameKind {
    DataMessage = 1,
    DeliveryAck = 2,
}

impl TryFrom<u8> for ChannelFrameKind {
    type Error = Error;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::DataMessage),
            2 => Ok(Self::DeliveryAck),
            _ => Err(Error::new(
                ErrorKind::InvalidData,
                "unsupported channel frame kind",
            )),
        }
    }
}

/// 在新建的 QUIC 单向 stream 上发送一个已编码的应用信封。
pub async fn send_channel_frame(
    connection: &Connection,
    kind: ChannelFrameKind,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut send = connection.open_uni().await?;
    write_channel_frame(&mut send, kind, payload).await?;
    send.finish()?;
    Ok(())
}

/// 写入带长度边界的应用通道帧。
pub async fn write_channel_frame(
    send: &mut SendStream,
    kind: ChannelFrameKind,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if payload.is_empty() || payload.len() > MAX_CHANNEL_FRAME_BYTES {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "channel payload is outside protocol bounds",
        )
        .into());
    }
    send.write_all(CHANNEL_MAGIC).await?;
    send.write_u32(NETWORK_PROTOCOL_VERSION).await?;
    send.write_u8(kind as u8).await?;
    send.write_u32(payload.len() as u32).await?;
    send.write_all(payload).await?;
    send.flush().await?;
    Ok(())
}

/// 读取一个完整应用通道帧；长度先于分配校验，避免远端控制内存。
pub async fn read_channel_frame(
    recv: &mut RecvStream,
) -> Result<(ChannelFrameKind, Vec<u8>), Box<dyn std::error::Error + Send + Sync>> {
    let mut magic = [0u8; 4];
    recv.read_exact(&mut magic).await?;
    if &magic != CHANNEL_MAGIC {
        return Err(Error::new(ErrorKind::InvalidData, "invalid channel frame magic").into());
    }
    if recv.read_u32().await? != NETWORK_PROTOCOL_VERSION {
        return Err(Error::new(ErrorKind::InvalidData, "unsupported channel frame version").into());
    }
    let kind = ChannelFrameKind::try_from(recv.read_u8().await?)?;
    let payload_len = recv.read_u32().await? as usize;
    if payload_len == 0 || payload_len > MAX_CHANNEL_FRAME_BYTES {
        return Err(Error::new(
            ErrorKind::InvalidData,
            "channel payload is outside protocol bounds",
        )
        .into());
    }
    let mut payload = vec![0u8; payload_len];
    recv.read_exact(&mut payload).await?;
    Ok((kind, payload))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::endpoint::QuicEndpointManager;
    use network_nat::PathManager;
    use std::sync::Arc;

    async fn quic_pair() -> (quinn::Endpoint, quinn::Connection, quinn::Connection) {
        let server =
            QuicEndpointManager::new("127.0.0.1:0".parse().unwrap(), Arc::new(PathManager::new()))
                .unwrap();
        let client =
            QuicEndpointManager::new("127.0.0.1:0".parse().unwrap(), Arc::new(PathManager::new()))
                .unwrap();
        let server_addr = server.endpoint.local_addr().unwrap();
        let server_endpoint = server.endpoint;
        let server_connection = tokio::spawn(async move {
            server_endpoint
                .accept()
                .await
                .expect("incoming connection")
                .await
                .expect("server connection")
        });
        let client_endpoint = client.endpoint;
        let client_connection = client_endpoint
            .connect(server_addr, "ssh-mobile")
            .unwrap()
            .await
            .unwrap();
        let server_connection = server_connection.await.unwrap();
        (client_endpoint, client_connection, server_connection)
    }

    #[test]
    fn channel_frame_budget_includes_a_bounded_payload() {
        const CHANNEL_HEADER_BYTES: usize = 4 + 4 + 1 + 4;
        assert_eq!(CHANNEL_HEADER_BYTES, 13);
        assert_eq!(MAX_CHANNEL_FRAME_BYTES, 48 * 1024);
        assert_eq!(
            ChannelFrameKind::try_from(1).expect("data kind"),
            ChannelFrameKind::DataMessage
        );
        assert!(ChannelFrameKind::try_from(9).is_err());
    }

    #[tokio::test]
    async fn channel_frame_round_trips_and_rejects_bad_bounds() {
        let (endpoint, client, server) = quic_pair().await;
        let mut send = client.open_uni().await.unwrap();
        write_channel_frame(&mut send, ChannelFrameKind::DataMessage, b"hello")
            .await
            .unwrap();
        send.finish().unwrap();
        let mut recv = server.accept_uni().await.unwrap();
        assert_eq!(
            read_channel_frame(&mut recv).await.unwrap(),
            (ChannelFrameKind::DataMessage, b"hello".to_vec())
        );
        assert!(
            send_channel_frame(&client, ChannelFrameKind::DeliveryAck, &[])
                .await
                .is_err()
        );
        assert!(send_channel_frame(
            &client,
            ChannelFrameKind::DeliveryAck,
            &vec![0; MAX_CHANNEL_FRAME_BYTES + 1],
        )
        .await
        .is_err());
        endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
    }

    #[tokio::test]
    async fn channel_reader_fails_closed_for_magic_version_kind_and_length() {
        let (endpoint, client, server) = quic_pair().await;
        let cases: [(&[u8], &str); 4] = [
            (b"BAD!\0\0\0\x01\x01\0\0\0\x01x", "magic"),
            (b"SMCH\0\0\0\x03\x01\0\0\0\x01x", "version"),
            (b"SMCH\0\0\0\x01\x09\0\0\0\x01x", "kind"),
            (b"SMCH\0\0\0\x01\x01\0\0\0\0", "length"),
        ];
        for (bytes, label) in cases {
            let mut send = server.open_uni().await.unwrap();
            send.write_all(bytes).await.unwrap();
            send.finish().unwrap();
            let mut recv = client.accept_uni().await.unwrap();
            assert!(read_channel_frame(&mut recv).await.is_err(), "{label}");
        }
        endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
    }
}
