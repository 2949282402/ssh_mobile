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
#[path = "tests/file_stream.rs"]
mod tests;
