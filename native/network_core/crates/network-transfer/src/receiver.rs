use std::path::Path;
use sha2::{Digest, Sha256};
use tokio::fs::{self, File, OpenOptions};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc::UnboundedSender;
use tracing::info;
use crate::manifest::{FileManifest, DEFAULT_TRANSFER_BUFFER};

pub async fn stream_receive_file<R>(
    manifest: &FileManifest,
    destination_dir: &Path,
    offset: u64,
    mut reader: R,
    progress_tx: Option<UnboundedSender<(u64, u64)>>,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>>
where
    R: tokio::io::AsyncReadExt + Unpin,
{
    let temp_filename = format!("{}.part", manifest.transfer_id);
    let temp_path = destination_dir.join(temp_filename);

    let mut file = OpenOptions::new()
        .create(true)
        .write(true)
        .append(offset > 0)
        .open(&temp_path)
        .await?;

    let mut buffer = vec![0u8; DEFAULT_TRANSFER_BUFFER];
    let mut transferred = offset;

    while transferred < manifest.file_size {
        let to_read = std::cmp::min(
            buffer.len() as u64,
            manifest.file_size - transferred,
        ) as usize;

        let n = reader.read(&mut buffer[..to_read]).await?;
        if n == 0 {
            break;
        }
        file.write_all(&buffer[..n]).await?;
        transferred += n as u64;

        if let Some(ref tx) = progress_tx {
            let _ = tx.send((transferred, manifest.file_size));
        }
    }

    file.flush().await?;
    drop(file);

    // Verify SHA-256 checksum if provided
    if !manifest.content_hash.is_empty() {
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
        if hash_hex.to_lowercase() != manifest.content_hash.to_lowercase() {
            fs::remove_file(&temp_path).await?;
            return Err("Checksum verification failed".into());
        }
    }

    // Atomic rename on success
    let final_path = destination_dir.join(&manifest.file_name);
    fs::rename(&temp_path, &final_path).await?;

    info!("Completed streaming receive for file: {:?}, verified checksum", final_path);
    Ok(final_path.to_string_lossy().to_string())
}
