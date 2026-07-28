use std::net::SocketAddr;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CandidateKind {
    Lan,
    PublicIpv6,
    ServerReflexive,
    PortMapped,
    Relay,
}

#[derive(Debug, Clone)]
pub struct Candidate {
    pub endpoint: SocketAddr,
    pub interface_name: String,
    pub kind: CandidateKind,
    pub priority: u32,
    pub rtt_ms: u32,
    pub loss_rate: f32,
    pub last_success_timestamp: u64,
}

impl Candidate {
    pub fn new(endpoint: SocketAddr, kind: CandidateKind, interface_name: String) -> Self {
        let base_priority = match kind {
            CandidateKind::Lan => 100,
            CandidateKind::PublicIpv6 => 80,
            CandidateKind::PortMapped => 60,
            CandidateKind::ServerReflexive => 40,
            CandidateKind::Relay => 10,
        };

        Self {
            endpoint,
            interface_name,
            kind,
            priority: base_priority,
            rtt_ms: 0,
            loss_rate: 0.0,
            last_success_timestamp: 0,
        }
    }
}
