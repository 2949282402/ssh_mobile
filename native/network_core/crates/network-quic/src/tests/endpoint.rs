use super::*;
use network_nat::PathManager;

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
