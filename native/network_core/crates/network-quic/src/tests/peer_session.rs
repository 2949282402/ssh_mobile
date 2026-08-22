use super::*;

use crate::endpoint::QuicEndpointManager;
use network_nat::PathManager;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::sync::RwLock;

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
fn rejects_a_valid_signature_from_the_wrong_identity() {
    let expected = DeviceIdentity::generate("expected".into());
    let attacker = DeviceIdentity::generate("expected".into());
    let nonce = [7u8; NONCE_BYTES];
    let channel_binding = [9u8; CHANNEL_BINDING_BYTES];
    let attacker_key = attacker.public_identity_key().to_bytes();
    let payload = authentication_payload(
        INITIATOR_DOMAIN,
        "expected",
        &attacker_key,
        &channel_binding,
        &[&nonce],
    );
    let frame = AuthFrame {
        device_id: "expected".into(),
        public_key: attacker_key,
        nonce,
        signature: attacker
            .sign_proof(&payload)
            .try_into()
            .expect("signature size"),
    };

    assert!(validate_peer_frame(
        &frame,
        "expected",
        &expected.public_identity_key().to_bytes(),
        INITIATOR_DOMAIN,
        &channel_binding,
        &[&nonce],
    )
    .is_err());
}

#[test]
fn rejects_a_valid_signature_bound_to_another_quic_session() {
    let identity = DeviceIdentity::generate("expected".into());
    let nonce = [7u8; NONCE_BYTES];
    let signed_binding = [9u8; CHANNEL_BINDING_BYTES];
    let other_binding = [10u8; CHANNEL_BINDING_BYTES];
    let public_key = identity.public_identity_key().to_bytes();
    let payload = authentication_payload(
        INITIATOR_DOMAIN,
        "expected",
        &public_key,
        &signed_binding,
        &[&nonce],
    );
    let frame = AuthFrame {
        device_id: "expected".into(),
        public_key,
        nonce,
        signature: identity
            .sign_proof(&payload)
            .try_into()
            .expect("signature size"),
    };

    assert!(validate_peer_frame(
        &frame,
        "expected",
        &public_key,
        INITIATOR_DOMAIN,
        &signed_binding,
        &[&nonce],
    )
    .is_ok());
    assert!(validate_peer_frame(
        &frame,
        "expected",
        &public_key,
        INITIATOR_DOMAIN,
        &other_binding,
        &[&nonce],
    )
    .is_err());
}

#[tokio::test]
async fn initiator_and_responder_complete_the_authenticated_handshake() {
    let (endpoint, client_connection, server_connection) = quic_pair().await;
    let client_identity = DeviceIdentity::generate("client".into());
    let server_identity = DeviceIdentity::generate("server".into());
    let client = QuicPeerSession::new(client_connection, "server".into());
    let server = QuicPeerSession::new(server_connection, "client".into());

    let (client_result, server_result) = tokio::join!(
        client.perform_handshake(
            &client_identity,
            server_identity.public_identity_key().to_bytes()
        ),
        server.accept_handshake(
            &server_identity,
            client_identity.public_identity_key().to_bytes()
        ),
    );
    client_result.expect("initiator handshake");
    server_result.expect("responder handshake");
    assert!(client.is_authenticated());
    assert!(server.is_authenticated());
    endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
}

#[tokio::test]
async fn trusted_accept_rejects_a_device_missing_from_the_registry() {
    let (endpoint, client_connection, server_connection) = quic_pair().await;
    let client_identity = DeviceIdentity::generate("client".into());
    let server_identity = DeviceIdentity::generate("server".into());
    let client = QuicPeerSession::new(client_connection, "server".into());
    let trusted = RwLock::new(HashMap::new());

    let (client_result, server_result) = tokio::join!(
        client.perform_handshake(
            &client_identity,
            server_identity.public_identity_key().to_bytes()
        ),
        QuicPeerSession::accept_trusted(server_connection, &server_identity, &trusted),
    );
    assert!(client_result.is_err());
    let error = match server_result {
        Err(error) => error,
        Ok(_) => panic!("unknown peer must be rejected"),
    };
    assert!(error.to_string().contains("untrusted QUIC peer"));
    assert!(!client.is_authenticated());
    endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
}

#[tokio::test]
async fn trusted_accept_authenticates_a_registered_device() {
    let (endpoint, client_connection, server_connection) = quic_pair().await;
    let client_identity = DeviceIdentity::generate("client".into());
    let server_identity = DeviceIdentity::generate("server".into());
    let client = QuicPeerSession::new(client_connection, "server".into());
    let mut keys = HashMap::new();
    keys.insert(
        client_identity.device_id.clone(),
        client_identity.public_identity_key().to_bytes(),
    );
    let trusted = RwLock::new(keys);

    let (client_result, server_result) = tokio::join!(
        client.perform_handshake(
            &client_identity,
            server_identity.public_identity_key().to_bytes()
        ),
        QuicPeerSession::accept_trusted(server_connection, &server_identity, &trusted),
    );
    client_result.expect("initiator handshake");
    let trusted_session = server_result.expect("trusted handshake");
    assert!(trusted_session.is_authenticated());
    assert_eq!(trusted_session.peer_device_id, "client");
    endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
}

#[tokio::test]
async fn auth_frame_codec_rejects_invalid_metadata_and_versions() {
    let (endpoint, client, server) = quic_pair().await;

    let mut send = client.open_bi().await.unwrap().0;
    let nonce = [1_u8; NONCE_BYTES];
    let key = [2_u8; 32];
    assert!(
        write_auth_frame(&mut send, "", &key, &nonce, &[0; SIGNATURE_BYTES])
            .await
            .is_err()
    );
    drop(send);

    let mut send = server.open_uni().await.unwrap();
    send.write_u32(NETWORK_PROTOCOL_VERSION + 1).await.unwrap();
    send.finish().unwrap();
    let mut recv = client.accept_uni().await.unwrap();
    assert!(read_auth_frame(&mut recv).await.is_err());

    let mut send = server.open_uni().await.unwrap();
    send.write_u32(NETWORK_PROTOCOL_VERSION).await.unwrap();
    send.write_u16(0).await.unwrap();
    send.finish().unwrap();
    let mut recv = client.accept_uni().await.unwrap();
    assert!(read_auth_frame(&mut recv).await.is_err());

    let mut send = server.open_uni().await.unwrap();
    send.write_u32(NETWORK_PROTOCOL_VERSION).await.unwrap();
    send.write_u16(1).await.unwrap();
    send.write_u8(0xff).await.unwrap();
    send.finish().unwrap();
    let mut recv = client.accept_uni().await.unwrap();
    assert!(read_auth_frame(&mut recv).await.is_err());

    endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
}

#[test]
fn authentication_payload_is_domain_and_nonce_bound() {
    let key = [4_u8; 32];
    let binding = [5_u8; CHANNEL_BINDING_BYTES];
    let nonce_a = [6_u8; NONCE_BYTES];
    let nonce_b = [7_u8; NONCE_BYTES];
    let first = authentication_payload(INITIATOR_DOMAIN, "device", &key, &binding, &[&nonce_a]);
    let second = authentication_payload(
        RESPONDER_DOMAIN,
        "device",
        &key,
        &binding,
        &[&nonce_a, &nonce_b],
    );
    assert_ne!(first, second);
    assert!(second.len() > first.len());
}
