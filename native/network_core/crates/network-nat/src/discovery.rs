use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use tracing::info;
use crate::candidate::{Candidate, CandidateKind};

/// Enumerates local network interfaces and discovers candidate endpoints.
pub async fn discover_candidates(port: u16) -> Vec<Candidate> {
    let mut candidates = Vec::new();

    // Local IPv4 candidates
    if let Ok(socket) = tokio::net::UdpSocket::bind("0.0.0.0:0").await {
        if let Ok(local_addr) = socket.local_addr() {
            let addr = SocketAddr::new(local_addr.ip(), port);
            candidates.push(Candidate::new(addr, CandidateKind::Lan, "default_v4".into()));
        }
    }

    // Global IPv6 candidates
    if let Ok(socket) = tokio::net::UdpSocket::bind("[::]:0").await {
        if let Ok(local_addr) = socket.local_addr() {
            if let IpAddr::V6(ip6) = local_addr.ip() {
                if is_global_unicast_v6(&ip6) {
                    let addr = SocketAddr::new(IpAddr::V6(ip6), port);
                    candidates.push(Candidate::new(
                        addr,
                        CandidateKind::PublicIpv6,
                        "default_v6".into(),
                    ));
                }
            }
        }
    }

    info!("Discovered {} local candidates", candidates.len());
    candidates
}

fn is_global_unicast_v6(ip: &Ipv6Addr) -> bool {
    !ip.is_loopback() && !ip.is_unspecified() && (ip.segments()[0] & 0xe000) == 0x2000
}
