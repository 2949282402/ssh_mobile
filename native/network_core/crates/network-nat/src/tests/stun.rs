use super::*;

fn response(transaction_id: [u8; 12], value: &[u8]) -> Vec<u8> {
    let mut packet = vec![0u8; 20];
    packet[..2].copy_from_slice(&0x0101u16.to_be_bytes());
    packet[4..8].copy_from_slice(&STUN_MAGIC_COOKIE.to_be_bytes());
    packet[8..20].copy_from_slice(&transaction_id);
    packet.extend_from_slice(&0x0020u16.to_be_bytes());
    packet.extend_from_slice(&(value.len() as u16).to_be_bytes());
    packet.extend_from_slice(value);
    while !packet.len().is_multiple_of(4) {
        packet.push(0);
    }
    let length = (packet.len() - 20) as u16;
    packet[2..4].copy_from_slice(&length.to_be_bytes());
    packet
}

#[test]
fn parses_ipv4_xor_mapped_address_and_rejects_bad_transaction() {
    let transaction_id = [1u8; 12];
    let address = "203.0.113.7:4567".parse::<SocketAddr>().unwrap();
    let mut value = vec![0, 1];
    value.extend_from_slice(&(address.port() ^ (STUN_MAGIC_COOKIE >> 16) as u16).to_be_bytes());
    let ip = match address.ip() {
        IpAddr::V4(ip) => u32::from_be_bytes(ip.octets()),
        IpAddr::V6(_) => unreachable!("test address must be IPv4"),
    };
    value.extend_from_slice(&(ip ^ STUN_MAGIC_COOKIE).to_be_bytes());
    let packet = response(transaction_id, &value);
    assert_eq!(
        parse_xor_mapped_address(&packet, transaction_id),
        Some(address)
    );
    assert!(parse_xor_mapped_address(&packet, [2u8; 12]).is_none());
}

#[test]
fn parses_ipv6_xor_mapped_address() {
    let transaction_id = [3u8; 12];
    let address = "[2001:db8::42]:9876".parse::<SocketAddr>().unwrap();
    let mut value = vec![0, 2];
    value.extend_from_slice(&(address.port() ^ (STUN_MAGIC_COOKIE >> 16) as u16).to_be_bytes());
    let mut xor_key = [0u8; 16];
    xor_key[..4].copy_from_slice(&STUN_MAGIC_COOKIE.to_be_bytes());
    xor_key[4..].copy_from_slice(&transaction_id);
    let ip = match address.ip() {
        IpAddr::V6(ip) => ip.octets(),
        IpAddr::V4(_) => unreachable!("test address must be IPv6"),
    };
    for (byte, key) in ip.iter().zip(xor_key) {
        value.push(*byte ^ key);
    }
    let packet = response(transaction_id, &value);
    assert_eq!(
        parse_xor_mapped_address(&packet, transaction_id),
        Some(address)
    );
}

#[tokio::test]
async fn query_stun_validates_transaction_and_reports_server_reflexive_candidate() {
    let server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let server_address = server.local_addr().unwrap();
    let responder = tokio::spawn(async move {
        let mut request = [0u8; 128];
        let (length, source) = server.recv_from(&mut request).await.unwrap();
        assert_eq!(length, 20);
        let transaction_id: [u8; 12] = request[8..20].try_into().unwrap();
        let mapped = "198.51.100.9:4231".parse::<SocketAddr>().unwrap();
        let mut value = vec![0, 1];
        value.extend_from_slice(&(mapped.port() ^ (STUN_MAGIC_COOKIE >> 16) as u16).to_be_bytes());
        let ip = match mapped.ip() {
            IpAddr::V4(ip) => u32::from_be_bytes(ip.octets()),
            IpAddr::V6(_) => unreachable!("test mapping must be IPv4"),
        };
        value.extend_from_slice(&(ip ^ STUN_MAGIC_COOKIE).to_be_bytes());
        let packet = response(transaction_id, &value);
        server.send_to(&packet, source).await.unwrap();
        mapped
    });

    let candidate = query_stun(&client, server_address).await.unwrap();
    assert_eq!(candidate.kind, CandidateKind::ServerReflexive);
    assert_eq!(candidate.endpoint, responder.await.unwrap());
}

#[tokio::test]
async fn query_stun_rejects_a_response_from_the_expected_ip_but_wrong_port() {
    let expected = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let spoof = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let expected_address = expected.local_addr().unwrap();
    let responder = tokio::spawn(async move {
        let mut request = [0u8; 128];
        let (length, source) = expected.recv_from(&mut request).await.unwrap();
        assert_eq!(length, 20);
        let transaction_id: [u8; 12] = request[8..20].try_into().unwrap();
        let mapped = "198.51.100.9:4232".parse::<SocketAddr>().unwrap();
        let mut value = vec![0, 1];
        value.extend_from_slice(&(mapped.port() ^ (STUN_MAGIC_COOKIE >> 16) as u16).to_be_bytes());
        let ip = match mapped.ip() {
            IpAddr::V4(ip) => u32::from_be_bytes(ip.octets()),
            IpAddr::V6(_) => unreachable!("test mapping must be IPv4"),
        };
        value.extend_from_slice(&(ip ^ STUN_MAGIC_COOKIE).to_be_bytes());
        let packet = response(transaction_id, &value);
        // Send from a different local port, even though the source IP is
        // identical, to prove full SocketAddr validation.
        spoof.send_to(&packet, source).await.unwrap();
    });

    assert!(query_stun(&client, expected_address).await.is_none());
    responder.await.unwrap();
}

#[tokio::test]
async fn query_stun_v2_only_advertises_quic_and_udp_datagram() {
    let server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let server_address = server.local_addr().unwrap();
    let responder = tokio::spawn(async move {
        let mut request = [0u8; 128];
        let (length, source) = server.recv_from(&mut request).await.unwrap();
        assert_eq!(length, 20);
        let transaction_id: [u8; 12] = request[8..20].try_into().unwrap();
        let mapped = "198.51.100.10:4233".parse::<SocketAddr>().unwrap();
        let mut value = vec![0, 1];
        value.extend_from_slice(&(mapped.port() ^ (STUN_MAGIC_COOKIE >> 16) as u16).to_be_bytes());
        let ip = match mapped.ip() {
            IpAddr::V4(ip) => u32::from_be_bytes(ip.octets()),
            IpAddr::V6(_) => unreachable!("test mapping must be IPv4"),
        };
        value.extend_from_slice(&(ip ^ STUN_MAGIC_COOKIE).to_be_bytes());
        server
            .send_to(&response(transaction_id, &value), source)
            .await
            .unwrap();
        mapped
    });

    let candidate = query_stun_v2(&client, server_address, 7).await.unwrap();
    assert_eq!(candidate.generation, 7);
    assert_eq!(candidate.transport_capabilities, STUN_SRFLX_TRANSPORTS);
    assert_eq!(candidate.endpoint, responder.await.unwrap());
    assert!(query_stun_v2(&client, server_address, 0).await.is_none());
}
