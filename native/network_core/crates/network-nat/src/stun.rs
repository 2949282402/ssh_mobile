use crate::candidate::{Candidate, CandidateKind};
use crate::candidate_v2::{CandidatePayloadV2, CandidateTransport};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Duration;
use tokio::net::UdpSocket;
use tokio::time::timeout;

const STUN_MAGIC_COOKIE: u32 = 0x2112A442;
const BINDING_REQUEST_TYPE: u16 = 0x0001;

/// A server-reflexive mapping comes from the shared UDP socket used by QUIC
/// and datagrams. It is never a TCP or WebSocket candidate.
pub const STUN_SRFLX_TRANSPORTS: [CandidateTransport; 2] =
    [CandidateTransport::Quic, CandidateTransport::UdpDatagram];

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

    if source != stun_server
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

/// Queries STUN and returns the versioned, transport-qualified payload. The
/// caller supplies the non-zero discovery generation because STUN itself has
/// no discovery-version semantics.
pub async fn query_stun_v2(
    socket: &UdpSocket,
    stun_server: SocketAddr,
    generation: u64,
) -> Option<CandidatePayloadV2> {
    if generation == 0 {
        return None;
    }
    let candidate = query_stun(socket, stun_server)
        .await?
        .with_generation(generation);
    let payload = CandidatePayloadV2::from_candidate(&candidate, STUN_SRFLX_TRANSPORTS.to_vec());
    payload.validate().ok().map(|_| payload)
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
#[path = "tests/stun.rs"]
mod tests;
