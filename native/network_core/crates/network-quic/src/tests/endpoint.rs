use super::*;
use network_nat::PathManager;
use rustls::client::danger::ServerCertVerifier;
use rustls::internal::msgs::codec::Codec;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};

#[tokio::test]
async fn from_bound_socket_keeps_the_bound_udp_port() {
    let socket = std::net::UdpSocket::bind("127.0.0.1:0").expect("bind UDP socket");
    let bound_address = socket.local_addr().expect("read bound address");
    let manager = QuicEndpointManager::from_bound_socket(socket, Arc::new(PathManager::new()))
        .expect("create QUIC endpoint");

    assert_eq!(manager.endpoint.local_addr().unwrap(), bound_address);
    manager
        .endpoint
        .close(quinn::VarInt::from_u32(0), b"test complete");
}

#[test]
fn quic_candidate_capabilities_do_not_claim_stream_transports() {
    assert_eq!(
        QUIC_CANDIDATE_TRANSPORTS,
        [CandidateTransport::Quic, CandidateTransport::UdpDatagram]
    );
    assert!(!QUIC_CANDIDATE_TRANSPORTS.contains(&CandidateTransport::Tcp));
    assert!(!QUIC_CANDIDATE_TRANSPORTS.contains(&CandidateTransport::Websocket));
}

#[test]
fn application_identity_verifier_keeps_tls12_signature_validation_explicit() {
    let verifier = ApplicationIdentityVerifier::new();
    assert!(!verifier.supported_verify_schemes().is_empty());
    let certificate =
        rcgen::generate_simple_self_signed(vec!["ssh-mobile".into()]).expect("certificate");
    let certificate = CertificateDer::from(certificate.cert.der().to_vec());
    let server_name = ServerName::try_from("ssh-mobile").expect("server name");
    assert!(verifier
        .verify_server_cert(&certificate, &[], &server_name, &[], UnixTime::now(),)
        .is_ok());

    let mut encoded = Vec::new();
    rustls::SignatureScheme::ECDSA_NISTP256_SHA256.encode(&mut encoded);
    0_u16.encode(&mut encoded);
    let signature =
        rustls::DigitallySignedStruct::read_bytes(&encoded).expect("encoded TLS signature");
    assert!(verifier
        .verify_tls12_signature(b"handshake", &certificate, &signature)
        .is_err());
}
