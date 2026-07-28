use std::time::{Duration, Instant};
use tokio::net::UdpSocket;
use tokio::time::timeout;
use tracing::debug;
use crate::candidate::Candidate;

pub const PROBE_MAGIC: &[u8; 4] = b"SSH1";

/// Performs authenticated UDP hole punch and measures path RTT.
pub async fn probe_candidate(
    socket: &UdpSocket,
    candidate: &mut Candidate,
    session_id: &str,
) -> bool {
    let mut payload = Vec::new();
    payload.extend_from_slice(PROBE_MAGIC);
    payload.extend_from_slice(session_id.as_bytes());

    let start = Instant::now();
    let mut success_count = 0;
    const NUM_PROBES: u32 = 3;

    for _ in 0..NUM_PROBES {
        if socket.send_to(&payload, candidate.endpoint).await.is_ok() {
            let mut buf = [0u8; 64];
            if let Ok(Ok((len, src))) = timeout(Duration::from_millis(500), socket.recv_from(&mut buf)).await {
                if src == candidate.endpoint && len >= 4 && &buf[0..4] == PROBE_MAGIC {
                    success_count += 1;
                }
            }
        }
    }

    if success_count > 0 {
        candidate.rtt_ms = (start.elapsed().as_millis() / success_count as u128) as u32;
        candidate.loss_rate = 1.0 - (success_count as f32 / NUM_PROBES as f32);
        candidate.last_success_timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        debug!(
            "Probe succeeded to {} (RTT: {}ms, loss: {:.0}%)",
            candidate.endpoint, candidate.rtt_ms, candidate.loss_rate * 100.0
        );
        true
    } else {
        false
    }
}
