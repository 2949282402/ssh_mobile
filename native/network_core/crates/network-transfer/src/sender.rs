use crate::cancellation::TransferCancellation;
use crate::manifest::{FileManifest, DEFAULT_TRANSFER_BUFFER, NETWORK_TRANSFER_PROTOCOL_VERSION};
use sha2::{Digest, Sha256};
use std::io::{Error, ErrorKind};
use std::path::Path;
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncSeekExt, SeekFrom};
use tokio::sync::mpsc::Sender;
use tracing::info;

pub async fn build_file_manifest(
    transfer_id: String,
    file_path: &Path,
) -> Result<FileManifest, Box<dyn std::error::Error + Send + Sync>> {
    let mut file = File::open(file_path).await?;
    let metadata = file.metadata().await?;
    if !metadata.is_file() {
        return Err(Error::new(ErrorKind::InvalidInput, "source is not a regular file").into());
    }
    let file_name = file_path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| Error::new(ErrorKind::InvalidInput, "source file name is not UTF-8"))?
        .to_string();
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; DEFAULT_TRANSFER_BUFFER];
    loop {
        let read = file.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    let modified_at = metadata
        .modified()
        .ok()
        .and_then(|value| value.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |value| value.as_millis() as i64);
    let manifest = FileManifest {
        transfer_id,
        file_name,
        file_size: metadata.len(),
        modified_at,
        content_hash: hex::encode(hasher.finalize()),
        protocol_version: NETWORK_TRANSFER_PROTOCOL_VERSION,
    };
    manifest
        .validate()
        .map_err(|message| Error::new(ErrorKind::InvalidInput, message))?;
    Ok(manifest)
}

pub async fn stream_send_file<W>(
    file_path: &Path,
    offset: u64,
    writer: W,
    progress_tx: Option<Sender<(u64, u64)>>,
) -> Result<u64, Box<dyn std::error::Error + Send + Sync>>
where
    W: tokio::io::AsyncWriteExt + Unpin,
{
    stream_send_file_cancellable(file_path, offset, writer, progress_tx, None).await
}

pub async fn stream_send_file_cancellable<W>(
    file_path: &Path,
    offset: u64,
    mut writer: W,
    progress_tx: Option<Sender<(u64, u64)>>,
    cancellation: Option<&TransferCancellation>,
) -> Result<u64, Box<dyn std::error::Error + Send + Sync>>
where
    W: tokio::io::AsyncWriteExt + Unpin,
{
    let mut file = File::open(file_path).await?;
    let total_bytes = file.metadata().await?.len();
    if offset > total_bytes {
        return Err(Error::new(ErrorKind::InvalidInput, "resume offset exceeds file size").into());
    }

    if offset > 0 {
        file.seek(SeekFrom::Start(offset)).await?;
    }

    let mut buffer = vec![0u8; DEFAULT_TRANSFER_BUFFER];
    let mut transferred = offset;

    loop {
        if cancellation.is_some_and(TransferCancellation::is_cancelled) {
            return Err(Error::new(ErrorKind::Interrupted, "transfer cancelled").into());
        }
        let n = file.read(&mut buffer).await?;
        if n == 0 {
            break;
        }
        writer.write_all(&buffer[..n]).await?;
        transferred += n as u64;

        if let Some(ref tx) = progress_tx {
            let _ = tx.send((transferred, total_bytes)).await;
        }
    }

    writer.flush().await?;
    info!(
        "Completed streaming send for file: {:?}, transferred {} bytes",
        file_path, transferred
    );
    Ok(transferred)
}

#[cfg(test)]
#[path = "tests/sender.rs"]
mod tests;
