use crate::candidate::Candidate;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::io::{Error, ErrorKind};
use std::time::{Duration, Instant};
use tokio::net::UdpSocket;
use tokio::time::timeout;
use tracing::debug;

pub const PROBE_MAGIC: &[u8; 4] = b"SSH1";
const PROBE_REQUEST: u8 = 1;
const PROBE_RESPONSE: u8 = 2;
const PROBE_NONCE_BYTES: usize = 16;
const PROBE_TAG_BYTES: usize = 32;
const MAX_SESSION_ID_BYTES: usize = 128;

type HmacSha256 = Hmac<Sha256>;

/// Sends authenticated probes and accepts only a response carrying the same
/// random nonce and a valid session-key HMAC.
pub async fn probe_candidate(
    socket: &UdpSocket,
    candidate: &mut Candidate,
    session_id: &str,
    session_key: &[u8],
) -> bool {
    if validate_probe_inputs(session_id, session_key).is_err() {
        return false;
    }

    let start = Instant::now();
    let mut success_count = 0;
    const NUM_PROBES: u32 = 3;

    for _ in 0..NUM_PROBES {
        let nonce = rand::random::<[u8; PROBE_NONCE_BYTES]>();
        let payload = build_probe(PROBE_REQUEST, &nonce, session_id, session_key);
        if socket.send_to(&payload, candidate.endpoint).await.is_ok() {
            let mut buf = [0u8; 256];
            if let Ok(Ok((len, src))) =
                timeout(Duration::from_millis(500), socket.recv_from(&mut buf)).await
            {
                if src == candidate.endpoint
                    && verify_probe(&buf[..len], PROBE_RESPONSE, &nonce, session_id, session_key)
                {
                    success_count += 1;
                }
            }
        }
    }

    if success_count == 0 {
        return false;
    }

    candidate.rtt_ms = (start.elapsed().as_millis() / success_count as u128) as u32;
    candidate.loss_rate = 1.0 - (success_count as f32 / NUM_PROBES as f32);
    candidate.last_success_timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    debug!(
        "Authenticated probe succeeded to {} (RTT: {}ms, loss: {:.0}%)",
        candidate.endpoint,
        candidate.rtt_ms,
        candidate.loss_rate * 100.0
    );
    true
}

/// Validates one probe request and returns the authenticated response bytes.
/// Callers keep ownership of socket receive demultiplexing.
pub fn respond_to_probe(
    request: &[u8],
    session_id: &str,
    session_key: &[u8],
) -> Result<Vec<u8>, Error> {
    validate_probe_inputs(session_id, session_key)?;
    let nonce = extract_nonce(request, PROBE_REQUEST, session_id, session_key)
        .ok_or_else(|| Error::new(ErrorKind::PermissionDenied, "invalid probe authentication"))?;
    Ok(build_probe(PROBE_RESPONSE, &nonce, session_id, session_key))
}

fn validate_probe_inputs(session_id: &str, session_key: &[u8]) -> Result<(), Error> {
    if session_id.is_empty() || session_id.len() > MAX_SESSION_ID_BYTES {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "invalid probe session ID",
        ));
    }
    if session_key.len() < 32 {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "probe session key must contain at least 32 bytes",
        ));
    }
    Ok(())
}

fn build_probe(kind: u8, nonce: &[u8; PROBE_NONCE_BYTES], session_id: &str, key: &[u8]) -> Vec<u8> {
    let mut packet =
        Vec::with_capacity(4 + 1 + PROBE_NONCE_BYTES + 2 + session_id.len() + PROBE_TAG_BYTES);
    packet.extend_from_slice(PROBE_MAGIC);
    packet.push(kind);
    packet.extend_from_slice(nonce);
    packet.extend_from_slice(&(session_id.len() as u16).to_be_bytes());
    packet.extend_from_slice(session_id.as_bytes());
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key size");
    mac.update(&packet);
    packet.extend_from_slice(&mac.finalize().into_bytes());
    packet
}

fn verify_probe(
    packet: &[u8],
    expected_kind: u8,
    expected_nonce: &[u8; PROBE_NONCE_BYTES],
    session_id: &str,
    key: &[u8],
) -> bool {
    extract_nonce(packet, expected_kind, session_id, key).as_ref() == Some(expected_nonce)
}

fn extract_nonce(
    packet: &[u8],
    expected_kind: u8,
    session_id: &str,
    key: &[u8],
) -> Option<[u8; PROBE_NONCE_BYTES]> {
    let fixed_length = 4 + 1 + PROBE_NONCE_BYTES + 2;
    if packet.len() < fixed_length + PROBE_TAG_BYTES
        || &packet[..4] != PROBE_MAGIC
        || packet[4] != expected_kind
    {
        return None;
    }
    let session_length =
        u16::from_be_bytes([packet[5 + PROBE_NONCE_BYTES], packet[6 + PROBE_NONCE_BYTES]]) as usize;
    let signed_length = fixed_length + session_length;
    if session_length != session_id.len() || packet.len() != signed_length + PROBE_TAG_BYTES {
        return None;
    }
    if &packet[fixed_length..signed_length] != session_id.as_bytes() {
        return None;
    }
    let mut mac = HmacSha256::new_from_slice(key).ok()?;
    mac.update(&packet[..signed_length]);
    mac.verify_slice(&packet[signed_length..]).ok()?;

    let mut nonce = [0u8; PROBE_NONCE_BYTES];
    nonce.copy_from_slice(&packet[5..5 + PROBE_NONCE_BYTES]);
    Some(nonce)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_tampered_and_reflected_probe_packets() {
        let key = [9u8; 32];
        let nonce = [3u8; PROBE_NONCE_BYTES];
        let request = build_probe(PROBE_REQUEST, &nonce, "session-a", &key);
        assert!(!verify_probe(
            &request,
            PROBE_RESPONSE,
            &nonce,
            "session-a",
            &key
        ));

        let mut response = respond_to_probe(&request, "session-a", &key).unwrap();
        assert!(verify_probe(
            &response,
            PROBE_RESPONSE,
            &nonce,
            "session-a",
            &key
        ));
        response[5] ^= 1;
        assert!(!verify_probe(
            &response,
            PROBE_RESPONSE,
            &nonce,
            "session-a",
            &key
        ));
    }
}
