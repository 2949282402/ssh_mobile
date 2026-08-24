use super::*;
use ed25519_dalek::{Signature, Verifier};

#[test]
fn authenticated_requests_bind_unix_seconds_path_and_nonce() {
    let signing_key = SigningKey::from_bytes(&[7u8; 32]);
    let mut nonces = Vec::new();
    for path in ["/v2/control", "/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d"] {
        let relay_url =
            Url::parse(&format!("wss://relay.example.test{path}")).expect("parse Relay test URL");
        let before = unix_timestamp_seconds().expect("timestamp before request");
        let request = authenticated_ws_request(&relay_url, "credential", &signing_key)
            .expect("build authenticated request");
        let after = unix_timestamp_seconds().expect("timestamp after request");

        let timestamp_header = request
            .headers()
            .get("X-Relay-Timestamp")
            .expect("timestamp header")
            .to_str()
            .expect("timestamp ASCII");
        let timestamp = timestamp_header
            .parse::<i64>()
            .expect("timestamp is an integer");
        assert!(timestamp > 0);
        assert_eq!(timestamp_header, timestamp.to_string());
        assert!((before..=after).contains(&timestamp));

        let nonce = request
            .headers()
            .get("X-Relay-Nonce")
            .expect("nonce header")
            .to_str()
            .expect("nonce ASCII");
        assert_eq!(
            URL_SAFE_NO_PAD.decode(nonce).expect("decode nonce").len(),
            32
        );
        nonces.push(nonce.to_string());
        let signature_bytes = URL_SAFE_NO_PAD
            .decode(
                request
                    .headers()
                    .get("X-Relay-Signature")
                    .expect("signature header")
                    .to_str()
                    .expect("signature ASCII"),
            )
            .expect("decode signature");
        let signature = Signature::from_slice(&signature_bytes).expect("Ed25519 signature");
        let transcript = authenticated_proof_transcript(path, timestamp, nonce);
        assert_eq!(transcript, format!("GET\n{path}\n{timestamp}\n{nonce}"));
        signing_key
            .verifying_key()
            .verify(transcript.as_bytes(), &signature)
            .expect("current transcript verifies");

        let retired_transcript = format!("GET\n{path}\n{nonce}");
        assert!(signing_key
            .verifying_key()
            .verify(retired_transcript.as_bytes(), &signature)
            .is_err());
        assert!(signing_key
            .verifying_key()
            .verify(format!("{transcript}\n").as_bytes(), &signature)
            .is_err());
    }
    assert_ne!(nonces[0], nonces[1]);
}
