use super::*;
use crate::endpoint::QuicEndpointManager;
use network_nat::PathManager;
use std::sync::Arc;

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

#[test]
fn channel_frame_budget_includes_a_bounded_payload() {
    const CHANNEL_HEADER_BYTES: usize = 4 + 4 + 1 + 4;
    assert_eq!(CHANNEL_HEADER_BYTES, 13);
    assert_eq!(MAX_CHANNEL_FRAME_BYTES, 48 * 1024);
    assert_eq!(
        ChannelFrameKind::try_from(1).expect("data kind"),
        ChannelFrameKind::DataMessage
    );
    assert_eq!(
        ChannelFrameKind::try_from(2).expect("ack kind"),
        ChannelFrameKind::DeliveryAck
    );
    assert!(ChannelFrameKind::try_from(9).is_err());
}

#[tokio::test]
async fn channel_frame_round_trips_and_rejects_bad_bounds() {
    let (endpoint, client, server) = quic_pair().await;
    let mut send = client.open_uni().await.unwrap();
    write_channel_frame(&mut send, ChannelFrameKind::DataMessage, b"hello")
        .await
        .unwrap();
    send.finish().unwrap();
    let mut recv = server.accept_uni().await.unwrap();
    assert_eq!(
        read_channel_frame(&mut recv).await.unwrap(),
        (ChannelFrameKind::DataMessage, b"hello".to_vec())
    );
    send_channel_frame(&client, ChannelFrameKind::DeliveryAck, b"ack")
        .await
        .unwrap();
    let mut ack_recv = server.accept_uni().await.unwrap();
    assert_eq!(
        read_channel_frame(&mut ack_recv).await.unwrap(),
        (ChannelFrameKind::DeliveryAck, b"ack".to_vec())
    );
    assert!(
        send_channel_frame(&client, ChannelFrameKind::DeliveryAck, &[])
            .await
            .is_err()
    );
    assert!(send_channel_frame(
        &client,
        ChannelFrameKind::DeliveryAck,
        &vec![0; MAX_CHANNEL_FRAME_BYTES + 1],
    )
    .await
    .is_err());
    endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
}

#[tokio::test]
async fn channel_reader_fails_closed_for_magic_version_kind_and_length() {
    let (endpoint, client, server) = quic_pair().await;
    let cases: [(&[u8], &str); 5] = [
        (b"BAD!\0\0\0\x01\x01\0\0\0\x01x", "magic"),
        (b"SMCH\0\0\0\x03\x01\0\0\0\x01x", "version"),
        (b"SMCH\0\0\0\x01\x09\0\0\0\x01x", "kind"),
        (b"SMCH\0\0\0\x01\x01\0\0\0\0", "length"),
        (b"SMCH\0\0\0\x01\x01\0\x00\x01\x00", "oversized length"),
    ];
    for (bytes, label) in cases {
        let mut send = server.open_uni().await.unwrap();
        send.write_all(bytes).await.unwrap();
        send.finish().unwrap();
        let mut recv = client.accept_uni().await.unwrap();
        assert!(read_channel_frame(&mut recv).await.is_err(), "{label}");
    }
    endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
}
