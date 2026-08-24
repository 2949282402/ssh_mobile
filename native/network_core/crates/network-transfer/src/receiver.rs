use crate::cancellation::TransferCancellation;
use crate::manifest::{FileManifest, DEFAULT_TRANSFER_BUFFER};
use sha2::{Digest, Sha256};
use std::io::{Error, ErrorKind};
use std::path::Path;
use tokio::fs::{self, File, OpenOptions};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt, SeekFrom};
use tokio::sync::mpsc::Sender;
use tracing::info;

pub async fn stream_receive_file<R>(
    manifest: &FileManifest,
    destination_dir: &Path,
    offset: u64,
    reader: R,
    progress_tx: Option<Sender<(u64, u64)>>,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>>
where
    R: tokio::io::AsyncReadExt + Unpin,
{
    stream_receive_file_cancellable(manifest, destination_dir, offset, reader, progress_tx, None)
        .await
}

/// 返回与 manifest 对应的安全 `.part` checkpoint。
///
/// 只接受普通文件，并且不会跟随 symlink；checkpoint 大于当前 manifest
/// 时返回 0，让后续正式接收流程安全地从头重建临时文件。
pub async fn existing_partial_offset(
    manifest: &FileManifest,
    destination_dir: &Path,
) -> Result<u64, Box<dyn std::error::Error + Send + Sync>> {
    manifest
        .validate()
        .map_err(|message| Error::new(ErrorKind::InvalidInput, message))?;
    let temporary_path = destination_dir.join(format!("{}.part", manifest.transfer_id));
    let metadata = match fs::symlink_metadata(&temporary_path).await {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error.into()),
    };
    if !metadata.file_type().is_file() {
        return Err(
            Error::new(ErrorKind::InvalidData, "partial file is not a regular file").into(),
        );
    }
    let offset = metadata.len();
    Ok(if offset <= manifest.file_size {
        offset
    } else {
        0
    })
}

/// 检查目标文件是否已经完整校验过，用于 completion ACK 丢失后的幂等恢复。
pub async fn existing_completed_file(
    manifest: &FileManifest,
    destination_dir: &Path,
) -> Result<Option<String>, Box<dyn std::error::Error + Send + Sync>> {
    manifest
        .validate()
        .map_err(|message| Error::new(ErrorKind::InvalidInput, message))?;
    let final_path = destination_dir.join(&manifest.file_name);
    let metadata = match fs::symlink_metadata(&final_path).await {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if !metadata.file_type().is_file() {
        return Err(Error::new(ErrorKind::InvalidData, "destination is not a regular file").into());
    }
    if metadata.len() != manifest.file_size {
        return Ok(None);
    }
    let mut file = File::open(&final_path).await?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; DEFAULT_TRANSFER_BUFFER];
    loop {
        let read = file.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    if hex::encode(hasher.finalize()).eq_ignore_ascii_case(&manifest.content_hash) {
        Ok(Some(final_path.to_string_lossy().to_string()))
    } else {
        Ok(None)
    }
}

pub async fn stream_receive_file_cancellable<R>(
    manifest: &FileManifest,
    destination_dir: &Path,
    offset: u64,
    mut reader: R,
    progress_tx: Option<Sender<(u64, u64)>>,
    cancellation: Option<&TransferCancellation>,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>>
where
    R: tokio::io::AsyncReadExt + Unpin,
{
    manifest
        .validate()
        .map_err(|message| Error::new(ErrorKind::InvalidInput, message))?;
    if offset > manifest.file_size {
        return Err(Error::new(ErrorKind::InvalidInput, "resume offset exceeds file size").into());
    }
    fs::create_dir_all(destination_dir).await?;

    let temp_filename = format!("{}.part", manifest.transfer_id);
    let temp_path = destination_dir.join(temp_filename);

    let mut file = if offset == 0 {
        match fs::remove_file(&temp_path).await {
            Ok(()) => {}
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temp_path)
            .await?
    } else {
        let metadata = fs::symlink_metadata(&temp_path).await?;
        if !metadata.file_type().is_file() || metadata.len() != offset {
            return Err(Error::new(
                ErrorKind::InvalidData,
                "partial file does not match resume offset",
            )
            .into());
        }
        let mut existing = OpenOptions::new().write(true).open(&temp_path).await?;
        existing.seek(SeekFrom::Start(offset)).await?;
        existing
    };

    let mut buffer = vec![0u8; DEFAULT_TRANSFER_BUFFER];
    let mut transferred = offset;

    while transferred < manifest.file_size {
        if cancellation.is_some_and(TransferCancellation::is_cancelled) {
            return Err(Error::new(ErrorKind::Interrupted, "transfer cancelled").into());
        }
        let to_read = std::cmp::min(buffer.len() as u64, manifest.file_size - transferred) as usize;

        let n = reader.read(&mut buffer[..to_read]).await?;
        if n == 0 {
            return Err(Error::new(
                ErrorKind::UnexpectedEof,
                "transfer stream ended before declared file size",
            )
            .into());
        }
        file.write_all(&buffer[..n]).await?;
        transferred += n as u64;

        if let Some(ref tx) = progress_tx {
            let _ = tx.send((transferred, manifest.file_size)).await;
        }
    }

    file.flush().await?;
    drop(file);

    let mut hasher = Sha256::new();
    let mut check_file = File::open(&temp_path).await?;
    let mut check_buf = vec![0u8; DEFAULT_TRANSFER_BUFFER];

    loop {
        let n = check_file.read(&mut check_buf).await?;
        if n == 0 {
            break;
        }
        hasher.update(&check_buf[..n]);
    }

    let hash_hex = hex::encode(hasher.finalize());
    if !hash_hex.eq_ignore_ascii_case(&manifest.content_hash) {
        fs::remove_file(&temp_path).await?;
        return Err(Error::new(ErrorKind::InvalidData, "checksum verification failed").into());
    }
    if cancellation.is_some_and(TransferCancellation::is_cancelled) {
        return Err(Error::new(ErrorKind::Interrupted, "transfer cancelled").into());
    }

    let final_path = destination_dir.join(&manifest.file_name);
    if fs::symlink_metadata(&final_path).await.is_ok() {
        return Err(Error::new(ErrorKind::AlreadyExists, "destination file already exists").into());
    }
    fs::rename(&temp_path, &final_path).await?;

    info!(
        "Completed streaming receive for file: {:?}, verified checksum",
        final_path
    );
    Ok(final_path.to_string_lossy().to_string())
}

#[cfg(test)]
#[path = "tests/receiver.rs"]
mod tests;
