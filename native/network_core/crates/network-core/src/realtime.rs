//! WebRTC realtime Session integration.
//!
//! Realtime media is deliberately a sibling of the ordinary Data Route. This
//! module owns only the native WebRTC peer and signaling revision; keyboard,
//! clipboard, files, Delivery, and Relay recovery remain on their existing
//! QUIC/Relay paths.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use network_protocol::{
    RealtimeSessionState, RealtimeSignalKind, SendRealtimeSignalCommand,
    StartRealtimeSessionCommand, StopRealtimeSessionCommand,
};
use network_relay::RelayClient;
use network_webrtc::{
    DescriptionType, IceCandidate, SessionDescription, WebRtcConfig, WebRtcPeer,
    MAX_ICE_CANDIDATE_BYTES, MAX_SDP_BYTES,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use crate::events::{
    emit_realtime_signal, emit_realtime_state, protocol_error, protocol_error_with_peer,
};
use crate::runtime::RuntimeState;

const REALTIME_SIGNAL_VERSION: u32 = 1;
const MAX_REALTIME_SIGNAL_PAYLOAD_BYTES: usize = MAX_SDP_BYTES;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RealtimeSignalEnvelope {
    v: u32,
    revision: u64,
    payload: String,
}

struct RealtimeSession {
    peer_id: String,
    peer: WebRtcPeer,
    revision: u64,
    /// Highest signaling revision authored by the remote peer and accepted
    /// by this Session. It is separate from the local WebRTC state revision:
    /// offer/answer state machines advance those counters independently.
    remote_revision: u64,
    /// Revision of the active ICE generation. The answer advances the
    /// signaling state revision, but trickled candidates still belong to the
    /// offer's ICE generation.
    ice_revision: u64,
    seen_candidates: HashSet<Vec<u8>>,
}

#[derive(Default)]
pub(crate) struct RealtimeManager {
    sessions: HashMap<String, RealtimeSession>,
}

impl RealtimeManager {
    /// Close every WebRTC peer before the runtime supervisor joins its tasks.
    pub(crate) fn close_all(&mut self) {
        for (_, mut session) in self.sessions.drain() {
            let _ = session.peer.close();
        }
    }
}

struct OutboundSignal {
    realtime_id: String,
    peer_id: String,
    kind: RealtimeSignalKind,
    revision: u64,
    payload: Vec<u8>,
}

struct SignalOutcome {
    peer_id: String,
    revision: u64,
    state: RealtimeSessionState,
    outbound: Option<OutboundSignal>,
}

pub(crate) async fn start_session(
    state: Arc<RuntimeState>,
    command: StartRealtimeSessionCommand,
) -> Result<(), network_protocol::NetworkError> {
    validate_realtime_id(&command.realtime_id)?;
    validate_peer(&state, &command.peer_id).await?;
    let relay = usable_relay(&state).await?;

    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).map_err(|error| {
        realtime_error(
            network_protocol::NetworkErrorCode::IoError,
            error.to_string(),
            "start_realtime",
            &command.peer_id,
        )
    })?;
    peer.create_data_channel("ssh-mobile-realtime", Default::default())
        .map_err(|error| {
            realtime_error(
                network_protocol::NetworkErrorCode::IoError,
                error.to_string(),
                "create_webrtc_data_channel",
                &command.peer_id,
            )
        })?;
    let offer = peer.create_offer().map_err(|error| {
        realtime_error(
            network_protocol::NetworkErrorCode::IoError,
            error.to_string(),
            "create_webrtc_offer",
            &command.peer_id,
        )
    })?;
    let revision = peer.signaling_revision();
    let realtime_id = command.realtime_id;
    let peer_id = command.peer_id;
    let mut sessions = state.realtime.lock().await;
    if sessions.sessions.contains_key(&realtime_id) {
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "realtime session already exists",
            "start_realtime",
            &peer_id,
        ));
    }
    sessions.sessions.insert(
        realtime_id.clone(),
        RealtimeSession {
            peer_id: peer_id.clone(),
            peer,
            revision,
            remote_revision: 0,
            ice_revision: revision,
            seen_candidates: HashSet::new(),
        },
    );
    drop(sessions);

    let outbound = OutboundSignal {
        realtime_id: realtime_id.clone(),
        peer_id: peer_id.clone(),
        kind: RealtimeSignalKind::WebRtcOffer,
        revision,
        payload: offer.sdp.into_bytes(),
    };
    if let Err(error) = send_signal(&relay, &outbound).await {
        state.realtime.lock().await.sessions.remove(&realtime_id);
        emit_realtime_state(
            &state.event_tx,
            &realtime_id,
            &peer_id,
            RealtimeSessionState::Failed as i32,
            revision,
            Some(error.clone()),
        );
        return Err(error);
    }
    emit_realtime_state(
        &state.event_tx,
        &realtime_id,
        &peer_id,
        RealtimeSessionState::Negotiating as i32,
        revision,
        None,
    );
    emit_realtime_signal(
        &state.event_tx,
        &realtime_id,
        &peer_id,
        RealtimeSignalKind::WebRtcOffer as i32,
        revision,
        outbound.payload,
    );
    Ok(())
}

pub(crate) async fn stop_session(
    state: &RuntimeState,
    command: StopRealtimeSessionCommand,
) -> Result<(), network_protocol::NetworkError> {
    validate_realtime_id(&command.realtime_id)?;
    let session = state
        .realtime
        .lock()
        .await
        .sessions
        .remove(&command.realtime_id);
    let Some(mut session) = session else {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "realtime session does not exist",
        ));
    };
    let close_revision = session.revision.saturating_add(1);
    let _ = session.peer.close();
    if let Some(relay) = state.relay.read().await.clone() {
        let outbound = OutboundSignal {
            realtime_id: command.realtime_id.clone(),
            peer_id: session.peer_id.clone(),
            kind: RealtimeSignalKind::WebRtcClose,
            revision: close_revision,
            payload: b"close".to_vec(),
        };
        if relay.is_usable().await {
            let _ = send_signal(&relay, &outbound).await;
        }
    }
    emit_realtime_state(
        &state.event_tx,
        &command.realtime_id,
        &session.peer_id,
        RealtimeSessionState::Closed as i32,
        close_revision,
        None,
    );
    Ok(())
}

pub(crate) async fn send_signal_command(
    state: &RuntimeState,
    command: SendRealtimeSignalCommand,
) -> Result<(), network_protocol::NetworkError> {
    validate_realtime_id(&command.realtime_id)?;
    validate_peer(state, &command.peer_id).await?;
    let kind = RealtimeSignalKind::try_from(command.kind).map_err(|_| {
        realtime_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "invalid WebRTC signal kind",
            "send_realtime_signal",
            &command.peer_id,
        )
    })?;
    validate_signal(kind, command.revision, &command.payload)?;
    let relay = usable_relay(state).await?;
    let (session_peer_id, session_revision, ice_revision) = {
        let sessions = state.realtime.lock().await;
        let Some(session) = sessions.sessions.get(&command.realtime_id) else {
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "realtime session does not exist",
                "send_realtime_signal",
                &command.peer_id,
            ));
        };
        (
            session.peer_id.clone(),
            session.revision,
            session.ice_revision,
        )
    };
    let revision_is_valid = if kind == RealtimeSignalKind::IceCandidate {
        command.revision == ice_revision
    } else {
        command.revision > session_revision
    };
    if session_peer_id != command.peer_id || !revision_is_valid {
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "stale or mismatched realtime signaling revision",
            "send_realtime_signal",
            &command.peer_id,
        ));
    }
    let outbound = OutboundSignal {
        realtime_id: command.realtime_id.clone(),
        peer_id: command.peer_id.clone(),
        kind,
        revision: command.revision,
        payload: command.payload,
    };
    send_signal(&relay, &outbound).await?;
    emit_realtime_signal(
        &state.event_tx,
        &outbound.realtime_id,
        &outbound.peer_id,
        outbound.kind as i32,
        outbound.revision,
        outbound.payload,
    );
    Ok(())
}

pub(crate) async fn handle_relay_signal(
    state: &RuntimeState,
    relay: &RelayClient,
    kind: &str,
    realtime_id: &str,
    peer_id: &str,
    payload: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    validate_realtime_id(realtime_id).map_err(boxed_protocol_error)?;
    validate_peer(state, peer_id)
        .await
        .map_err(boxed_protocol_error)?;
    let kind = signal_kind_from_control(kind)
        .ok_or_else(|| boxed_message("invalid WebRTC control type"))?;
    let envelope = decode_envelope(payload)?;
    validate_signal(kind, envelope.revision, &envelope.payload_bytes())
        .map_err(boxed_protocol_error)?;

    let outcome = {
        let mut manager = state.realtime.lock().await;
        apply_signal(
            &mut manager,
            realtime_id,
            peer_id,
            kind,
            envelope.revision,
            envelope.payload_bytes(),
        )?
    };

    emit_realtime_signal(
        &state.event_tx,
        realtime_id,
        peer_id,
        kind as i32,
        envelope.revision,
        envelope.payload_bytes(),
    );
    emit_realtime_state(
        &state.event_tx,
        realtime_id,
        &outcome.peer_id,
        outcome.state as i32,
        outcome.revision,
        None,
    );
    if let Some(outbound) = outcome.outbound {
        send_signal(relay, &outbound)
            .await
            .map_err(boxed_protocol_error)?;
        emit_realtime_signal(
            &state.event_tx,
            &outbound.realtime_id,
            &outbound.peer_id,
            outbound.kind as i32,
            outbound.revision,
            outbound.payload,
        );
    }
    Ok(())
}

fn apply_signal(
    manager: &mut RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    kind: RealtimeSignalKind,
    revision: u64,
    payload: Vec<u8>,
) -> Result<SignalOutcome, Box<dyn std::error::Error + Send + Sync>> {
    if kind == RealtimeSignalKind::WebRtcClose {
        let Some(session) = manager.sessions.get(realtime_id) else {
            return Err(boxed_message("realtime session does not exist"));
        };
        if session.peer_id != peer_id {
            return Err(boxed_message("realtime signal peer does not match session"));
        }
        if revision <= session.remote_revision {
            return Err(boxed_message("stale realtime signaling revision"));
        }
        let Some(mut session) = manager.sessions.remove(realtime_id) else {
            return Err(boxed_message("realtime session does not exist"));
        };
        let _ = session.peer.close();
        return Ok(SignalOutcome {
            peer_id: peer_id.to_string(),
            revision,
            state: RealtimeSessionState::Closed,
            outbound: None,
        });
    }

    if let Some(session) = manager.sessions.get(realtime_id) {
        if session.peer_id != peer_id {
            return Err(boxed_message("realtime signal peer does not match session"));
        }
        match kind {
            RealtimeSignalKind::IceCandidate => {
                if revision != session.ice_revision {
                    return Err(boxed_message("stale realtime ICE generation"));
                }
                if session.seen_candidates.contains(&payload) {
                    return Err(boxed_message("replayed realtime ICE candidate"));
                }
            }
            _ if revision <= session.remote_revision => {
                return Err(boxed_message("stale realtime signaling revision"));
            }
            _ => {}
        }
    }

    match kind {
        RealtimeSignalKind::WebRtcOffer => {
            let existing = manager.sessions.remove(realtime_id);
            let had_existing = existing.is_some();
            let mut session = existing.unwrap_or_else(|| RealtimeSession {
                peer_id: peer_id.to_string(),
                peer: WebRtcPeer::new(WebRtcConfig::default())
                    .expect("validated default WebRTC configuration"),
                revision: 0,
                remote_revision: 0,
                ice_revision: 0,
                seen_candidates: HashSet::new(),
            });
            let description = match String::from_utf8(payload)
                .map_err(|error| boxed_message(error.to_string()))
                .and_then(|sdp| {
                    SessionDescription::new(DescriptionType::Offer, sdp)
                        .map_err(|error| boxed_message(error.to_string()))
                }) {
                Ok(description) => description,
                Err(error) => {
                    if had_existing {
                        manager.sessions.insert(realtime_id.to_string(), session);
                    }
                    return Err(error);
                }
            };
            if let Err(error) = session.peer.accept_remote_offer(description) {
                if had_existing {
                    manager.sessions.insert(realtime_id.to_string(), session);
                }
                return Err(boxed_message(error.to_string()));
            }
            let answer = match session.peer.create_answer() {
                Ok(answer) => answer,
                Err(error) => {
                    if had_existing {
                        manager.sessions.insert(realtime_id.to_string(), session);
                    }
                    return Err(boxed_message(error.to_string()));
                }
            };
            let answer_revision = session.peer.signaling_revision().max(revision);
            session.revision = answer_revision;
            session.remote_revision = revision;
            session.ice_revision = revision;
            session.seen_candidates.clear();
            let peer_id = session.peer_id.clone();
            manager.sessions.insert(realtime_id.to_string(), session);
            Ok(SignalOutcome {
                peer_id: peer_id.clone(),
                revision: answer_revision,
                state: RealtimeSessionState::Negotiating,
                outbound: Some(OutboundSignal {
                    realtime_id: realtime_id.to_string(),
                    peer_id,
                    kind: RealtimeSignalKind::WebRtcAnswer,
                    revision: answer_revision,
                    payload: answer.sdp.into_bytes(),
                }),
            })
        }
        RealtimeSignalKind::WebRtcAnswer => {
            let session = manager
                .sessions
                .get_mut(realtime_id)
                .ok_or_else(|| boxed_message("realtime session does not exist"))?;
            session.peer.accept_remote_answer(SessionDescription::new(
                DescriptionType::Answer,
                String::from_utf8(payload)?,
            )?)?;
            session.revision = session.peer.signaling_revision().max(revision);
            session.remote_revision = revision;
            Ok(SignalOutcome {
                peer_id: session.peer_id.clone(),
                revision: session.revision,
                state: RealtimeSessionState::Connected,
                outbound: None,
            })
        }
        RealtimeSignalKind::IceCandidate => {
            let session = manager
                .sessions
                .get_mut(realtime_id)
                .ok_or_else(|| boxed_message("realtime session does not exist"))?;
            session.peer.add_remote_ice_candidate(IceCandidate::new(
                String::from_utf8(payload.clone())?,
                None,
                None,
                None,
            )?)?;
            session.seen_candidates.insert(payload);
            Ok(SignalOutcome {
                peer_id: session.peer_id.clone(),
                revision: session.revision,
                state: RealtimeSessionState::Negotiating,
                outbound: None,
            })
        }
        RealtimeSignalKind::IceRestart => {
            let session = manager
                .sessions
                .get_mut(realtime_id)
                .ok_or_else(|| boxed_message("realtime session does not exist"))?;
            session.peer.restart_ice()?;
            let offer = session.peer.create_offer()?;
            session.revision = session.peer.signaling_revision().max(revision);
            session.remote_revision = revision;
            session.ice_revision = session.revision;
            session.seen_candidates.clear();
            Ok(SignalOutcome {
                peer_id: session.peer_id.clone(),
                revision: session.revision,
                state: RealtimeSessionState::Restarting,
                outbound: Some(OutboundSignal {
                    realtime_id: realtime_id.to_string(),
                    peer_id: session.peer_id.clone(),
                    kind: RealtimeSignalKind::WebRtcOffer,
                    revision: session.revision,
                    payload: offer.sdp.into_bytes(),
                }),
            })
        }
        RealtimeSignalKind::Unspecified | RealtimeSignalKind::WebRtcClose => {
            Err(boxed_message("unsupported WebRTC signal kind"))
        }
    }
}

async fn usable_relay(
    state: &RuntimeState,
) -> Result<Arc<RelayClient>, network_protocol::NetworkError> {
    let relay = state.relay.read().await.clone().ok_or_else(|| {
        protocol_error(
            network_protocol::NetworkErrorCode::RelayError,
            "Relay signaling route is unavailable",
        )
    })?;
    if !relay.is_usable().await {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::RelayError,
            "Relay signaling route is disconnected",
        ));
    }
    Ok(relay)
}

async fn validate_peer(
    state: &RuntimeState,
    peer_id: &str,
) -> Result<(), network_protocol::NetworkError> {
    if peer_id.is_empty() || peer_id.len() > 128 || !state.peers.read().await.contains_key(peer_id)
    {
        return Err(protocol_error_with_peer(
            network_protocol::NetworkErrorCode::NoRoute,
            "realtime peer is not registered",
            "realtime",
            peer_id,
        ));
    }
    Ok(())
}

fn validate_realtime_id(id: &str) -> Result<(), network_protocol::NetworkError> {
    if id.len() != 32
        || id != id.to_ascii_lowercase()
        || hex::decode(id).map_or(true, |bytes| bytes.len() != 16)
    {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "realtime_id must be 32 lowercase hexadecimal characters",
        ));
    }
    Ok(())
}

fn validate_signal(
    kind: RealtimeSignalKind,
    revision: u64,
    payload: &[u8],
) -> Result<(), network_protocol::NetworkError> {
    if revision == 0 || payload.len() > MAX_REALTIME_SIGNAL_PAYLOAD_BYTES {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "WebRTC signal revision or payload is outside bounds",
        ));
    }
    if kind == RealtimeSignalKind::IceCandidate && payload.len() > MAX_ICE_CANDIDATE_BYTES {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "ICE candidate payload is outside bounds",
        ));
    }
    if !matches!(
        kind,
        RealtimeSignalKind::WebRtcClose
            | RealtimeSignalKind::IceRestart
            | RealtimeSignalKind::IceCandidate
    ) && payload.is_empty()
    {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "WebRTC signal payload must not be empty",
        ));
    }
    Ok(())
}

async fn send_signal(
    relay: &RelayClient,
    signal: &OutboundSignal,
) -> Result<(), network_protocol::NetworkError> {
    let payload = encode_envelope(signal.revision, &signal.payload).map_err(|error| {
        realtime_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            error.to_string(),
            "encode_realtime_signal",
            &signal.peer_id,
        )
    })?;
    relay
        .send_webrtc_signal(
            control_type(signal.kind),
            &signal.realtime_id,
            &signal.peer_id,
            &payload,
        )
        .await
        .map_err(|error| {
            realtime_error(
                network_protocol::NetworkErrorCode::RelayError,
                error.to_string(),
                "send_realtime_signal",
                &signal.peer_id,
            )
        })
}

fn encode_envelope(revision: u64, payload: &[u8]) -> Result<Vec<u8>, serde_json::Error> {
    serde_json::to_vec(&RealtimeSignalEnvelope {
        v: REALTIME_SIGNAL_VERSION,
        revision,
        payload: URL_SAFE_NO_PAD.encode(payload),
    })
}

fn decode_envelope(
    payload: &str,
) -> Result<DecodedEnvelope, Box<dyn std::error::Error + Send + Sync>> {
    let bytes = URL_SAFE_NO_PAD.decode(payload)?;
    let envelope: RealtimeSignalEnvelope = serde_json::from_slice(&bytes)?;
    if envelope.v != REALTIME_SIGNAL_VERSION {
        return Err(boxed_message("unsupported WebRTC signal version"));
    }
    let payload = URL_SAFE_NO_PAD.decode(envelope.payload)?;
    Ok(DecodedEnvelope {
        revision: envelope.revision,
        payload,
    })
}

struct DecodedEnvelope {
    revision: u64,
    payload: Vec<u8>,
}

impl DecodedEnvelope {
    fn payload_bytes(&self) -> Vec<u8> {
        self.payload.clone()
    }
}

fn control_type(kind: RealtimeSignalKind) -> &'static str {
    match kind {
        RealtimeSignalKind::WebRtcOffer => "webrtc_offer",
        RealtimeSignalKind::WebRtcAnswer => "webrtc_answer",
        RealtimeSignalKind::IceCandidate => "webrtc_ice_candidate",
        RealtimeSignalKind::IceRestart => "webrtc_ice_restart",
        RealtimeSignalKind::WebRtcClose => "webrtc_close",
        RealtimeSignalKind::Unspecified => "webrtc_unknown",
    }
}

fn signal_kind_from_control(kind: &str) -> Option<RealtimeSignalKind> {
    Some(match kind {
        "webrtc_offer" => RealtimeSignalKind::WebRtcOffer,
        "webrtc_answer" => RealtimeSignalKind::WebRtcAnswer,
        "webrtc_ice_candidate" => RealtimeSignalKind::IceCandidate,
        "webrtc_ice_restart" => RealtimeSignalKind::IceRestart,
        "webrtc_close" => RealtimeSignalKind::WebRtcClose,
        _ => return None,
    })
}

fn realtime_error(
    code: network_protocol::NetworkErrorCode,
    message: impl Into<String>,
    operation: &str,
    peer_id: &str,
) -> network_protocol::NetworkError {
    protocol_error_with_peer(code, message, operation, peer_id)
}

fn boxed_protocol_error(
    error: network_protocol::NetworkError,
) -> Box<dyn std::error::Error + Send + Sync> {
    boxed_message(error.message)
}

fn boxed_message(message: impl Into<String>) -> Box<dyn std::error::Error + Send + Sync> {
    std::io::Error::new(std::io::ErrorKind::InvalidData, message.into()).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signaling_envelope_round_trips_revision_and_binary_payload() {
        let encoded = encode_envelope(3, b"sdp-bytes").expect("encode");
        let outer = URL_SAFE_NO_PAD.encode(encoded);
        let decoded = decode_envelope(&outer).expect("decode");
        assert_eq!(decoded.revision, 3);
        assert_eq!(decoded.payload, b"sdp-bytes");
    }

    #[test]
    fn signal_control_names_cover_the_complete_v1_set() {
        for (kind, expected) in [
            (RealtimeSignalKind::WebRtcOffer, "webrtc_offer"),
            (RealtimeSignalKind::WebRtcAnswer, "webrtc_answer"),
            (RealtimeSignalKind::IceCandidate, "webrtc_ice_candidate"),
            (RealtimeSignalKind::IceRestart, "webrtc_ice_restart"),
            (RealtimeSignalKind::WebRtcClose, "webrtc_close"),
        ] {
            assert_eq!(signal_kind_from_control(expected), Some(kind));
            assert_eq!(control_type(kind), expected);
        }
    }

    #[test]
    fn offer_answer_and_stale_revision_are_session_bound() {
        let realtime_id = "00112233445566778899aabbccddeeff";
        let mut caller = WebRtcPeer::new(WebRtcConfig::default()).expect("caller");
        caller
            .create_data_channel("ssh-mobile-realtime", Default::default())
            .expect("data channel");
        let offer = caller.create_offer().expect("offer");
        let caller_revision = caller.signaling_revision();

        let mut responder_manager = RealtimeManager::default();
        let answer = apply_signal(
            &mut responder_manager,
            realtime_id,
            "peer-a",
            RealtimeSignalKind::WebRtcOffer,
            caller_revision,
            offer.sdp.into_bytes(),
        )
        .expect("answer");
        assert_eq!(answer.state, RealtimeSessionState::Negotiating);
        let answer = answer.outbound.expect("answer signal");

        let mut caller_manager = RealtimeManager::default();
        caller_manager.sessions.insert(
            realtime_id.into(),
            RealtimeSession {
                peer_id: "peer-b".into(),
                peer: caller,
                revision: caller_revision,
                remote_revision: 0,
                ice_revision: caller_revision,
                seen_candidates: HashSet::new(),
            },
        );
        let connected = apply_signal(
            &mut caller_manager,
            realtime_id,
            "peer-b",
            RealtimeSignalKind::WebRtcAnswer,
            answer.revision,
            answer.payload,
        )
        .expect("connected");
        assert_eq!(connected.state, RealtimeSessionState::Connected);

        assert!(apply_signal(
            &mut caller_manager,
            realtime_id,
            "peer-b",
            RealtimeSignalKind::WebRtcOffer,
            connected.revision,
            b"invalid-sdp".to_vec(),
        )
        .is_err());
        assert!(caller_manager.sessions.contains_key(realtime_id));
    }

    #[test]
    fn ice_candidates_follow_the_active_generation_and_deduplicate_replays() {
        let realtime_id = "00112233445566778899aabbccddeeff";
        let mut caller = WebRtcPeer::new(WebRtcConfig::default()).expect("caller");
        caller
            .create_data_channel("ssh-mobile-realtime", Default::default())
            .expect("data channel");
        let offer = caller.create_offer().expect("offer");
        let offer_revision = caller.signaling_revision();

        let mut responder_manager = RealtimeManager::default();
        let answer = apply_signal(
            &mut responder_manager,
            realtime_id,
            "peer-a",
            RealtimeSignalKind::WebRtcOffer,
            offer_revision,
            offer.sdp.into_bytes(),
        )
        .expect("answer")
        .outbound
        .expect("answer signal");
        let candidate = b"candidate:1 1 udp 2130706431 192.168.1.100 54321 typ host".to_vec();

        let accepted = apply_signal(
            &mut responder_manager,
            realtime_id,
            "peer-a",
            RealtimeSignalKind::IceCandidate,
            offer_revision,
            candidate.clone(),
        )
        .expect("candidate");
        assert_eq!(accepted.state, RealtimeSessionState::Negotiating);
        assert_eq!(accepted.revision, answer.revision);
        assert!(apply_signal(
            &mut responder_manager,
            realtime_id,
            "peer-a",
            RealtimeSignalKind::IceCandidate,
            offer_revision,
            candidate.clone(),
        )
        .is_err());
        assert!(apply_signal(
            &mut responder_manager,
            realtime_id,
            "peer-a",
            RealtimeSignalKind::IceCandidate,
            answer.revision,
            b"candidate:2 1 udp 2130706431 192.0.2.1 54322 typ host".to_vec(),
        )
        .is_err());
    }

    #[test]
    fn ice_restart_emits_a_new_offer_and_close_rejects_stale_revisions() {
        let realtime_id = "00112233445566778899aabbccddeeff";
        let mut caller = WebRtcPeer::new(WebRtcConfig::default()).expect("caller");
        caller
            .create_data_channel("ssh-mobile-realtime", Default::default())
            .expect("data channel");
        let offer = caller.create_offer().expect("offer");
        let offer_revision = caller.signaling_revision();
        let mut manager = RealtimeManager::default();
        let answer = apply_signal(
            &mut manager,
            realtime_id,
            "peer-a",
            RealtimeSignalKind::WebRtcOffer,
            offer_revision,
            offer.sdp.into_bytes(),
        )
        .expect("answer")
        .outbound
        .expect("answer signal");

        let restart = apply_signal(
            &mut manager,
            realtime_id,
            "peer-a",
            RealtimeSignalKind::IceRestart,
            answer.revision + 1,
            b"restart".to_vec(),
        )
        .expect("restart");
        assert_eq!(restart.state, RealtimeSessionState::Restarting);
        let restart_offer = restart.outbound.expect("restart offer");
        assert_eq!(restart_offer.kind, RealtimeSignalKind::WebRtcOffer);
        assert!(restart_offer.revision > answer.revision);

        assert!(apply_signal(
            &mut manager,
            realtime_id,
            "peer-a",
            RealtimeSignalKind::WebRtcClose,
            answer.revision,
            b"close".to_vec(),
        )
        .is_err());
        assert!(manager.sessions.contains_key(realtime_id));
        let closed = apply_signal(
            &mut manager,
            realtime_id,
            "peer-a",
            RealtimeSignalKind::WebRtcClose,
            restart_offer.revision,
            b"close".to_vec(),
        )
        .expect("close");
        assert_eq!(closed.state, RealtimeSessionState::Closed);
        assert!(!manager.sessions.contains_key(realtime_id));
    }

    #[test]
    fn signaling_bounds_reject_oversized_messages_before_peer_mutation() {
        assert!(validate_signal(
            RealtimeSignalKind::WebRtcOffer,
            1,
            &vec![b'x'; MAX_SDP_BYTES + 1],
        )
        .is_err());
        assert!(validate_signal(
            RealtimeSignalKind::IceCandidate,
            1,
            &vec![b'x'; MAX_ICE_CANDIDATE_BYTES + 1],
        )
        .is_err());
    }
}
