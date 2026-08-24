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
