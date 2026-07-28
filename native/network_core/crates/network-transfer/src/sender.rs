use std::path::Path;
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncSeekExt, SeekFrom};
use tokio::sync::mpsc::UnboundedSender;
use tracing::info;
use crate::manifest::DEFAULT_TRANSFER_BUFFER;

pub async fn stream_send_file<W>(
    file_path: &Path,
    offset: u64,
    mut writer: W,
    progress_tx: Option<UnboundedSender<(u64, u64)>>,
) -> Result<u64, Box<dyn std::error::Error + Send + Sync>>
where
    W: tokio::io::AsyncWriteExt + Unpin,
{
    let mut file = File::open(file_path).await?;
    let total_bytes = file.metadata().await?.len();

    if offset > 0 {
        file.seek(SeekFrom::Start(offset)).await?;
    }

    let mut buffer = vec![0u8; DEFAULT_TRANSFER_BUFFER];
    let mut transferred = offset;

    loop {
        let n = file.read(&mut buffer).await?;
        if n == 0 {
            break;
        }
        writer.write_all(&buffer[..n]).await?;
        transferred += n as u64;

        if let Some(ref tx) = progress_tx {
            let _ = tx.send((transferred, total_bytes));
        }
    }

    writer.flush().await?;
    info!("Completed streaming send for file: {:?}, transferred {} bytes", file_path, transferred);
    Ok(transferred)
}
