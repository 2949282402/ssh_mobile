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
    let send =
        tokio::spawn(
            async move { stream_send_file(&send_path, 4, writer, Some(progress_tx)).await },
        );
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
    let result = stream_send_file_cancellable(&path, 0, writer, None, Some(&cancellation)).await;
    assert!(
        matches!(result, Err(error) if error.downcast_ref::<Error>().is_some_and(|error| error.kind() == ErrorKind::Interrupted))
    );
    tokio::fs::remove_file(path).await.unwrap();
}
