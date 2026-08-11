use serde::{Deserialize, Serialize};
use std::net::SocketAddr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CandidateKind {
    Lan,
    PublicIpv6,
    ServerReflexive,
    PortMapped,
    Relay,
}

#[derive(Debug, Clone)]
pub struct Candidate {
    pub candidate_id: String,
    pub endpoint: SocketAddr,
    pub interface_name: String,
    pub kind: CandidateKind,
    pub priority: u32,
    pub generation: u64,
    pub rtt_ms: u32,
    pub jitter_ms: u32,
    pub loss_rate: f32,
    pub last_success_timestamp: u64,
    pub sample_count: u32,
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
            candidate_id: format!("{}@{}", interface_name, endpoint),
            endpoint,
            interface_name,
            kind,
            priority: base_priority,
            generation: 0,
            rtt_ms: 0,
            jitter_ms: 0,
            loss_rate: 0.0,
            last_success_timestamp: 0,
            sample_count: 0,
        }
    }

    pub fn with_generation(mut self, generation: u64) -> Self {
        self.generation = generation;
        self
    }

    pub fn advertisement(&self) -> CandidateAdvertisement {
        CandidateAdvertisement {
            candidate_id: self.candidate_id.clone(),
            endpoint: self.endpoint,
            kind: self.kind,
            priority: self.priority,
            interface: self.interface_name.clone(),
            generation: self.generation,
        }
    }

    pub fn from_advertisement(advertisement: CandidateAdvertisement) -> Result<Self, String> {
        if advertisement.candidate_id.is_empty()
            || advertisement.candidate_id.len() > 128
            || advertisement.interface.is_empty()
            || advertisement.interface.len() > 128
            || advertisement.endpoint.ip().is_unspecified()
            || advertisement.endpoint.port() == 0
        {
            return Err("candidate advertisement contains invalid identity or endpoint".into());
        }
        Ok(Self {
            candidate_id: advertisement.candidate_id,
            endpoint: advertisement.endpoint,
            interface_name: advertisement.interface,
            kind: advertisement.kind,
            priority: advertisement.priority,
            generation: advertisement.generation,
            rtt_ms: 0,
            jitter_ms: 0,
            loss_rate: 0.0,
            last_success_timestamp: 0,
            sample_count: 0,
        })
    }
}

/// Candidate 对外信令字段；质量采样不通过 Relay 暴露，由接收端重新探测。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CandidateAdvertisement {
    pub candidate_id: String,
    pub endpoint: SocketAddr,
    pub kind: CandidateKind,
    pub priority: u32,
    pub interface: String,
    pub generation: u64,
}
