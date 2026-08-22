use network_transfer::{FileManifest, NETWORK_TRANSFER_PROTOCOL_VERSION};
use quinn::{RecvStream, SendStream};
use std::io::{Error, ErrorKind};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const FILE_OFFER_MAGIC: &[u8; 4] = b"SMFT";
const FILE_COMPLETION_ACK: u8 = 0xA1;
const MAX_TRANSFER_ID_BYTES: usize = 128;
const MAX_FILE_NAME_BYTES: usize = 255;

pub async fn write_file_offer(
    send: &mut SendStream,
    manifest: &FileManifest,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    manifest
        .validate()
        .map_err(|message| Error::new(ErrorKind::InvalidInput, message))?;
    let transfer_id = manifest.transfer_id.as_bytes();
    let file_name = manifest.file_name.as_bytes();
    let hash = hex::decode(&manifest.content_hash)
        .map_err(|_| Error::new(ErrorKind::InvalidInput, "invalid manifest hash"))?;
    if hash.len() != 32 {
        return Err(Error::new(ErrorKind::InvalidInput, "invalid manifest hash").into());
    }

    send.write_all(FILE_OFFER_MAGIC).await?;
    send.write_u32(NETWORK_TRANSFER_PROTOCOL_VERSION).await?;
    send.write_u16(transfer_id.len() as u16).await?;
    send.write_all(transfer_id).await?;
    send.write_u16(file_name.len() as u16).await?;
    send.write_all(file_name).await?;
    send.write_u64(manifest.file_size).await?;
    send.write_i64(manifest.modified_at).await?;
    send.write_all(&hash).await?;
    send.flush().await?;
    Ok(())
}

pub async fn read_file_offer(
    recv: &mut RecvStream,
) -> Result<FileManifest, Box<dyn std::error::Error + Send + Sync>> {
    let mut magic = [0u8; 4];
    recv.read_exact(&mut magic).await?;
    if &magic != FILE_OFFER_MAGIC {
        return Err(Error::new(ErrorKind::InvalidData, "invalid file offer magic").into());
    }
    let protocol_version = recv.read_u32().await?;
    if protocol_version != NETWORK_TRANSFER_PROTOCOL_VERSION {
        return Err(Error::new(ErrorKind::InvalidData, "unsupported file protocol").into());
    }
    let transfer_id = read_bounded_utf8(recv, MAX_TRANSFER_ID_BYTES, "transfer ID").await?;
    let file_name = read_bounded_utf8(recv, MAX_FILE_NAME_BYTES, "file name").await?;
    let file_size = recv.read_u64().await?;
    let modified_at = recv.read_i64().await?;
    let mut hash = [0u8; 32];
    recv.read_exact(&mut hash).await?;
    let manifest = FileManifest {
        transfer_id,
        file_name,
        file_size,
        modified_at,
        content_hash: hex::encode(hash),
        protocol_version,
    };
    manifest
        .validate()
        .map_err(|message| Error::new(ErrorKind::InvalidData, message))?;
    Ok(manifest)
}

pub async fn write_file_decision(
    send: &mut SendStream,
    accepted: bool,
    offset: u64,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    send.write_u8(u8::from(accepted)).await?;
    send.write_u64(offset).await?;
    send.flush().await?;
    Ok(())
}

pub async fn read_file_decision(
    recv: &mut RecvStream,
) -> Result<Option<u64>, Box<dyn std::error::Error + Send + Sync>> {
    let accepted = recv.read_u8().await?;
    let offset = recv.read_u64().await?;
    match accepted {
        0 => Ok(None),
        1 => Ok(Some(offset)),
        _ => Err(Error::new(ErrorKind::InvalidData, "invalid file decision").into()),
    }
}

pub async fn write_file_completion(
    send: &mut SendStream,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    send.write_u8(FILE_COMPLETION_ACK).await?;
    send.flush().await?;
    Ok(())
}

pub async fn read_file_completion(
    recv: &mut RecvStream,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if recv.read_u8().await? != FILE_COMPLETION_ACK {
        return Err(Error::new(ErrorKind::InvalidData, "invalid file completion ack").into());
    }
    Ok(())
}

async fn read_bounded_utf8(
    recv: &mut RecvStream,
    maximum: usize,
    label: &str,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let length = recv.read_u16().await? as usize;
    if length == 0 || length > maximum {
        return Err(Error::new(ErrorKind::InvalidData, format!("invalid {label} length")).into());
    }
    let mut value = vec![0u8; length];
    recv.read_exact(&mut value).await?;
    String::from_utf8(value)
        .map_err(|_| Error::new(ErrorKind::InvalidData, format!("{label} is not UTF-8")).into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::endpoint::QuicEndpointManager;

    use network_nat::PathManager;
    use std::sync::Arc;
    use tokio::io::AsyncWriteExt;

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

    fn manifest() -> FileManifest {
        FileManifest {
            transfer_id: "transfer-quic".into(),
            file_name: "payload.bin".into(),
            file_size: 5,
            modified_at: 7,
            content_hash: "ab".repeat(32),
            protocol_version: NETWORK_TRANSFER_PROTOCOL_VERSION,
        }
    }

    #[test]
    fn file_offer_limits_are_intentionally_bounded() {
        assert_eq!(MAX_TRANSFER_ID_BYTES, 128);
        assert_eq!(MAX_FILE_NAME_BYTES, 255);
        assert_eq!(FILE_COMPLETION_ACK, 0xA1);
    }

    #[tokio::test]
    async fn file_offer_decision_and_completion_round_trip() {
        let (endpoint, client, server) = quic_pair().await;
        let (mut client_send, mut client_recv) = client.open_bi().await.unwrap();
        write_file_offer(&mut client_send, &manifest())
            .await
            .unwrap();
        client_send.finish().unwrap();
        let (mut server_send, mut server_recv) = server.accept_bi().await.unwrap();
        assert_eq!(read_file_offer(&mut server_recv).await.unwrap(), manifest());
        write_file_decision(&mut server_send, true, 3)
            .await
            .unwrap();
        write_file_completion(&mut server_send).await.unwrap();
        server_send.finish().unwrap();
        assert_eq!(read_file_decision(&mut client_recv).await.unwrap(), Some(3));
        read_file_completion(&mut client_recv).await.unwrap();

        let invalid = FileManifest {
            file_name: "../unsafe".into(),
            ..manifest()
        };
        let (mut invalid_send, _invalid_recv) = client.open_bi().await.unwrap();
        assert!(write_file_offer(&mut invalid_send, &invalid).await.is_err());
        endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
    }

    #[tokio::test]
    async fn file_decoders_reject_invalid_decisions_and_completion_ack() {
        let (endpoint, client, server) = quic_pair().await;
        let mut send = server.open_uni().await.unwrap();
        send.write_u8(2).await.unwrap();
        send.write_u64(0).await.unwrap();
        send.finish().unwrap();
        let mut recv = client.accept_uni().await.unwrap();
        assert!(read_file_decision(&mut recv).await.is_err());

        let mut send = server.open_uni().await.unwrap();
        send.write_u8(0).await.unwrap();
        send.write_u64(0).await.unwrap();
        send.finish().unwrap();
        let mut recv = client.accept_uni().await.unwrap();
        assert_eq!(read_file_decision(&mut recv).await.unwrap(), None);

        let mut send = server.open_uni().await.unwrap();
        send.write_u8(0).await.unwrap();
        send.finish().unwrap();
        let mut recv = client.accept_uni().await.unwrap();
        assert!(read_file_completion(&mut recv).await.is_err());
        endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
    }
}
