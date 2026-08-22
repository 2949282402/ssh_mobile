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
mod tests {
    use super::*;
    use tokio::io::{duplex, AsyncReadExt};

    fn test_path(suffix: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "ssh_mobile_transfer_sender_{suffix}_{}",
            rand::random::<u64>()
        ))
    }

    #[tokio::test]
    async fn builds_manifest_and_streams_from_a_confirmed_offset() {
        let path = test_path("manifest");
        tokio::fs::write(&path, b"0123456789").await.unwrap();
        let manifest = build_file_manifest("sender-test".into(), &path)
            .await
            .unwrap();
        assert_eq!(manifest.transfer_id, "sender-test");
        assert_eq!(
            manifest.file_name,
            path.file_name().unwrap().to_str().unwrap()
        );
        assert_eq!(manifest.file_size, 10);

        let (mut reader, writer) = duplex(64);
        let (progress_tx, mut progress_rx) = tokio::sync::mpsc::channel(4);
        let send_path = path.clone();
        let send = tokio::spawn(async move {
            stream_send_file(&send_path, 4, writer, Some(progress_tx)).await
        });
        let mut received = Vec::new();
        reader.read_to_end(&mut received).await.unwrap();
        assert_eq!(received, b"456789");
        assert_eq!(progress_rx.recv().await, Some((10, 10)));
        assert_eq!(send.await.unwrap().unwrap(), 10);
        tokio::fs::remove_file(path).await.unwrap();
    }

    #[tokio::test]
    async fn rejects_invalid_offset_and_honors_cancellation_before_reading() {
        let path = test_path("cancel");
        tokio::fs::write(&path, b"payload").await.unwrap();
        let (_reader, writer) = duplex(64);
        assert!(stream_send_file(&path, 99, writer, None).await.is_err());

        let cancellation = TransferCancellation::default();
        cancellation.cancel();
        let (_reader, writer) = duplex(64);
        let result =
            stream_send_file_cancellable(&path, 0, writer, None, Some(&cancellation)).await;
        assert!(
            matches!(result, Err(error) if error.downcast_ref::<Error>().is_some_and(|error| error.kind() == ErrorKind::Interrupted))
        );
        tokio::fs::remove_file(path).await.unwrap();
    }
}
