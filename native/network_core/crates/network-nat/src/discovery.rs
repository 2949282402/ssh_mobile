use crate::candidate::{Candidate, CandidateKind};
use local_ip_address::list_afinet_netifas;
use std::collections::HashSet;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use tracing::info;

/// Enumerates concrete local interface addresses for the UDP port that QUIC
/// will bind. Unspecified and loopback addresses are never advertised.
pub async fn discover_candidates(port: u16) -> Vec<Candidate> {
    let mut candidates = Vec::new();
    let mut seen = HashSet::new();

    if let Ok(interfaces) = list_afinet_netifas() {
        for (interface_name, ip) in interfaces {
            if !is_advertisable(ip) || !seen.insert(ip) {
                continue;
            }
            let kind = match ip {
                IpAddr::V4(_) => CandidateKind::Lan,
                IpAddr::V6(_) => CandidateKind::PublicIpv6,
            };
            candidates.push(Candidate::new(
                SocketAddr::new(ip, port),
                kind,
                interface_name,
            ));
        }
    }

    info!("Discovered {} local candidates", candidates.len());
    candidates
}

fn is_advertisable(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => is_advertisable_v4(ip),
        IpAddr::V6(ip) => is_global_unicast_v6(ip),
    }
}

fn is_advertisable_v4(ip: Ipv4Addr) -> bool {
    !ip.is_unspecified()
        && !ip.is_loopback()
        && !ip.is_link_local()
        && !ip.is_multicast()
        && !ip.is_broadcast()
}

fn is_global_unicast_v6(ip: Ipv6Addr) -> bool {
    !ip.is_loopback()
        && !ip.is_unspecified()
        && !ip.is_multicast()
        && (ip.segments()[0] & 0xe000) == 0x2000
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn never_advertises_unspecified_or_loopback_addresses() {
        assert!(!is_advertisable("0.0.0.0".parse().unwrap()));
        assert!(!is_advertisable("127.0.0.1".parse().unwrap()));
        assert!(!is_advertisable("::".parse().unwrap()));
        assert!(!is_advertisable("::1".parse().unwrap()));
        assert!(is_advertisable("192.168.1.20".parse().unwrap()));
    }
}
