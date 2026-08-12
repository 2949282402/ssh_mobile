use crate::candidate::{Candidate, CandidateKind};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Duration;
use tokio::net::UdpSocket;
use tokio::time::timeout;

const STUN_MAGIC_COOKIE: u32 = 0x2112A442;
const BINDING_REQUEST_TYPE: u16 = 0x0001;

/// Queries a STUN server over a given UDP socket to discover the server-reflexive endpoint.
pub async fn query_stun(socket: &UdpSocket, stun_server: SocketAddr) -> Option<Candidate> {
    let transaction_id = rand::random::<[u8; 12]>();
    let mut req = [0u8; 20];
    req[0..2].copy_from_slice(&BINDING_REQUEST_TYPE.to_be_bytes());
    req[2..4].copy_from_slice(&0u16.to_be_bytes());
    req[4..8].copy_from_slice(&STUN_MAGIC_COOKIE.to_be_bytes());
    req[8..20].copy_from_slice(&transaction_id);

    if socket.send_to(&req, stun_server).await.is_err() {
        return None;
    }

    let mut buf = [0u8; 512];
    let (len, source) = timeout(Duration::from_secs(3), socket.recv_from(&mut buf))
        .await
        .ok()?
        .ok()?;

    if source.ip() != stun_server.ip()
        || len < 20
        || u16::from_be_bytes([buf[0], buf[1]]) != 0x0101
        || u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]) != STUN_MAGIC_COOKIE
        || buf[8..20] != transaction_id
    {
        return None;
    }
    parse_xor_mapped_address(&buf[..len], transaction_id)
        .map(|endpoint| Candidate::new(endpoint, CandidateKind::ServerReflexive, "stun".into()))
}

fn parse_xor_mapped_address(packet: &[u8], transaction_id: [u8; 12]) -> Option<SocketAddr> {
    if packet.len() < 20
        || u32::from_be_bytes([packet[4], packet[5], packet[6], packet[7]]) != STUN_MAGIC_COOKIE
        || packet[8..20] != transaction_id
    {
        return None;
    }
    let mut pos = 20;
    while pos + 4 <= packet.len() {
        let attr_type = u16::from_be_bytes([packet[pos], packet[pos + 1]]);
        let attr_len = u16::from_be_bytes([packet[pos + 2], packet[pos + 3]]) as usize;
        let value_start = pos + 4;
        let value_end = value_start.checked_add(attr_len)?;
        if value_end > packet.len() {
            return None;
        }
        if attr_type == 0x0020 && attr_len >= 8 {
            let family = packet[value_start + 1];
            let x_port = u16::from_be_bytes([packet[value_start + 2], packet[value_start + 3]]);
            let port = x_port ^ ((STUN_MAGIC_COOKIE >> 16) as u16);
            if family == 0x01 && attr_len >= 8 {
                let x_ip = u32::from_be_bytes([
                    packet[value_start + 4],
                    packet[value_start + 5],
                    packet[value_start + 6],
                    packet[value_start + 7],
                ]);
                return Some(SocketAddr::new(
                    IpAddr::V4(Ipv4Addr::from(x_ip ^ STUN_MAGIC_COOKIE)),
                    port,
                ));
            }
            if family == 0x02 && attr_len >= 20 {
                let mut xor_key = [0u8; 16];
                xor_key[..4].copy_from_slice(&STUN_MAGIC_COOKIE.to_be_bytes());
                xor_key[4..].copy_from_slice(&transaction_id);
                let mut address = [0u8; 16];
                for (index, byte) in address.iter_mut().enumerate() {
                    *byte = packet[value_start + 4 + index] ^ xor_key[index];
                }
                return Some(SocketAddr::new(IpAddr::V6(Ipv6Addr::from(address)), port));
            }
        }
        pos = value_end.checked_add((4 - attr_len % 4) % 4)?;
    }
    None
}

#[cfg(test)]
mod tests {
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
            value.extend_from_slice(
                &(mapped.port() ^ (STUN_MAGIC_COOKIE >> 16) as u16).to_be_bytes(),
            );
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
}
