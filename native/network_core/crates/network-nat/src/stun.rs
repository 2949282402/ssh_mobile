use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;
use tokio::net::UdpSocket;
use tokio::time::timeout;
use crate::candidate::{Candidate, CandidateKind};

const STUN_MAGIC_COOKIE: u32 = 0x2112A442;
const BINDING_REQUEST_TYPE: u16 = 0x0001;

/// Queries a STUN server over a given UDP socket to discover the server-reflexive endpoint.
pub async fn query_stun(
    socket: &UdpSocket,
    stun_server: SocketAddr,
) -> Option<Candidate> {
    let mut req = [0u8; 20];
    req[0..2].copy_from_slice(&BINDING_REQUEST_TYPE.to_be_bytes());
    req[2..4].copy_from_slice(&0u16.to_be_bytes());
    req[4..8].copy_from_slice(&STUN_MAGIC_COOKIE.to_be_bytes());
    req[8..20].copy_from_slice(&rand::random::<[u8; 12]>());

    if socket.send_to(&req, stun_server).await.is_err() {
        return None;
    }

    let mut buf = [0u8; 512];
    let (len, _) = timeout(Duration::from_secs(3), socket.recv_from(&mut buf))
        .await
        .ok()?
        .ok()?;

    if len < 20 {
        return None;
    }

    // Parse attributes looking for XOR-MAPPED-ADDRESS (0x0020)
    let mut pos = 20;
    while pos + 4 <= len {
        let attr_type = u16::from_be_bytes([buf[pos], buf[pos + 1]]);
        let attr_len = u16::from_be_bytes([buf[pos + 2], buf[pos + 3]]) as usize;
        pos += 4;

        if pos + attr_len > len {
            break;
        }

        if attr_type == 0x0020 && attr_len >= 8 {
            let family = buf[pos + 1];
            let x_port = u16::from_be_bytes([buf[pos + 2], buf[pos + 3]]);
            let port = x_port ^ ((STUN_MAGIC_COOKIE >> 16) as u16);

            if family == 0x01 && attr_len >= 8 {
                let x_ip = u32::from_be_bytes([buf[pos + 4], buf[pos + 5], buf[pos + 6], buf[pos + 7]]);
                let ip_u32 = x_ip ^ STUN_MAGIC_COOKIE;
                let ip = IpAddr::V4(Ipv4Addr::from(ip_u32));
                let endpoint = SocketAddr::new(ip, port);

                return Some(Candidate::new(
                    endpoint,
                    CandidateKind::ServerReflexive,
                    "stun".into(),
                ));
            }
        }

        pos += (attr_len + 3) & !3; // Align to 4-byte boundary
    }

    None
}
