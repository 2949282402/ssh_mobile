use super::*;
use crate::manifest::NETWORK_TRANSFER_PROTOCOL_VERSION;

fn manifest(file_name: &str, data: &[u8]) -> FileManifest {
    FileManifest {
        transfer_id: "transfer_test_1".into(),
        file_name: file_name.into(),
        file_size: data.len() as u64,
        modified_at: 0,
        content_hash: hex::encode(Sha256::digest(data)),
        protocol_version: NETWORK_TRANSFER_PROTOCOL_VERSION,
    }
}

fn test_directory() -> std::path::PathBuf {
    std::env::temp_dir().join(format!(
        "ssh_mobile_network_transfer_{}",
        rand::random::<u64>()
    ))
}

#[tokio::test]
async fn rejects_traversal_file_name() {
    let data = b"payload";
    let unsafe_manifest = manifest("../escaped.txt", data);
    let directory = test_directory();
    let result = stream_receive_file(&unsafe_manifest, &directory, 0, &data[..], None).await;
    assert!(result.is_err());
    assert!(!directory.join("escaped.txt").exists());
}

#[tokio::test]
async fn does_not_commit_an_early_eof() {
    let declared = b"payload";
    let partial = b"pay";
    let file_manifest = manifest("received.txt", declared);
    let directory = test_directory();
    let result = stream_receive_file(&file_manifest, &directory, 0, &partial[..], None).await;
    assert!(result.is_err());
    assert!(!directory.join("received.txt").exists());
    fs::remove_dir_all(directory).await.ok();
}

#[tokio::test]
async fn commits_only_after_size_and_hash_validation() {
    let data = b"payload";
    let file_manifest = manifest("received.txt", data);
    let directory = test_directory();
    let result = stream_receive_file(&file_manifest, &directory, 0, &data[..], None).await;
    assert!(result.is_ok());
    assert_eq!(
        fs::read(directory.join("received.txt")).await.unwrap(),
        data
    );
    fs::remove_dir_all(directory).await.ok();
}

#[tokio::test]
async fn discovers_a_matching_partial_offset() {
    let data = b"payload";
    let file_manifest = manifest("received.txt", data);
    let directory = test_directory();
    fs::create_dir_all(&directory).await.unwrap();
    fs::write(
        directory.join(format!("{}.part", file_manifest.transfer_id)),
        &data[..3],
    )
    .await
    .unwrap();
    assert_eq!(
        existing_partial_offset(&file_manifest, &directory)
            .await
            .unwrap(),
        3
    );
    fs::remove_dir_all(directory).await.ok();
}

#[tokio::test]
async fn ignores_a_partial_file_larger_than_the_manifest() {
    let data = b"payload";
    let file_manifest = manifest("received.txt", data);
    let directory = test_directory();
    fs::create_dir_all(&directory).await.unwrap();
    fs::write(
        directory.join(format!("{}.part", file_manifest.transfer_id)),
        b"payload-too-large",
    )
    .await
    .unwrap();
    assert_eq!(
        existing_partial_offset(&file_manifest, &directory)
            .await
            .unwrap(),
        0
    );
    fs::remove_dir_all(directory).await.ok();
}

#[tokio::test]
async fn recognizes_an_already_completed_file() {
    let data = b"payload";
    let file_manifest = manifest("received.txt", data);
    let directory = test_directory();
    fs::create_dir_all(&directory).await.unwrap();
    let final_path = directory.join("received.txt");
    fs::write(&final_path, data).await.unwrap();
    assert_eq!(
        existing_completed_file(&file_manifest, &directory)
            .await
            .unwrap(),
        Some(final_path.to_string_lossy().to_string())
    );
    fs::remove_dir_all(directory).await.ok();
}

#[tokio::test]
async fn resumes_from_a_matching_partial_file_and_finalizes_atomically() {
    let data = b"payload";
    let file_manifest = manifest("received.txt", data);
    let directory = test_directory();
    fs::create_dir_all(&directory).await.unwrap();
    fs::write(
        directory.join(format!("{}.part", file_manifest.transfer_id)),
        &data[..3],
    )
    .await
    .unwrap();
    let local_path = stream_receive_file(&file_manifest, &directory, 3, &data[3..], None)
        .await
        .unwrap();
    assert_eq!(fs::read(&local_path).await.unwrap(), data);
    assert!(!directory.join("received.txt.part").exists());
    fs::remove_dir_all(directory).await.ok();
}

#[tokio::test]
async fn rejects_bad_resume_offset_checksum_and_cancellation() {
    let data = b"payload";
    let file_manifest = manifest("received.txt", data);
    let directory = test_directory();
    let result = stream_receive_file(&file_manifest, &directory, 99, &data[..], None).await;
    assert!(matches!(
        result,
        Err(error) if error
            .downcast_ref::<Error>()
            .is_some_and(|error| error.kind() == ErrorKind::InvalidInput)
    ));

    let wrong_manifest = FileManifest {
        content_hash: "00".repeat(32),
        ..file_manifest.clone()
    };
    let result = stream_receive_file(&wrong_manifest, &directory, 0, &data[..], None).await;
    assert!(result.is_err());
    assert!(!directory.join("received.txt").exists());

    let cancellation = TransferCancellation::default();
    cancellation.cancel();
    let result = stream_receive_file_cancellable(
        &file_manifest,
        &directory,
        0,
        &data[..],
        None,
        Some(&cancellation),
    )
    .await;
    assert!(matches!(
        result,
        Err(error) if error
            .downcast_ref::<Error>()
            .is_some_and(|error| error.kind() == ErrorKind::Interrupted)
    ));
    fs::remove_dir_all(directory).await.ok();
}

#[tokio::test]
async fn completed_file_with_wrong_size_or_hash_is_not_reused() {
    let data = b"payload";
    let file_manifest = manifest("received.txt", data);
    let directory = test_directory();
    fs::create_dir_all(&directory).await.unwrap();
    let final_path = directory.join("received.txt");
    fs::write(&final_path, b"wrong").await.unwrap();
    assert_eq!(
        existing_completed_file(&file_manifest, &directory)
            .await
            .unwrap(),
        None
    );
    fs::write(&final_path, b"payload").await.unwrap();
    let wrong_hash_manifest = FileManifest {
        content_hash: "00".repeat(32),
        ..file_manifest
    };
    assert_eq!(
        existing_completed_file(&wrong_hash_manifest, &directory)
            .await
            .unwrap(),
        None
    );
    fs::remove_dir_all(directory).await.ok();
}
