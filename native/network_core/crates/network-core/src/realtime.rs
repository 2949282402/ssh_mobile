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
use network_relay::v2::{
    RealtimeSignal as V2RealtimeSignal, RealtimeSignalKind as V2RealtimeSignalKind,
};
use network_webrtc::{
    run_realtime_io, DescriptionType, IceCandidate, IceServerConfig, RealtimeIoDriver,
    RealtimeIoDriverHandle, RealtimeIoEvent, SessionDescription, WebRtcConfig, WebRtcError,
    WebRtcPeer, MAX_ICE_CANDIDATE_BYTES, MAX_SDP_BYTES,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use tokio::sync::mpsc::unbounded_channel;

use crate::events::{
    emit_realtime_signal, emit_realtime_snapshot, emit_realtime_state, protocol_error,
    protocol_error_with_peer,
};
use crate::runtime::RuntimeState;
use crate::session::SessionId;

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
    /// §22：PeerConnection/SDP/ICE 状态绑定在创建它的 ConnectionSession 上，
    /// ConnectionSession 销毁（transport 丢失）即一并销毁 RealtimeSession；
    /// 恢复必须走新的 Resolve → Connection → 重新 signaling → 新 PeerConnection。
    /// `None` 表示创建时该 peer 尚无 ConnectionSession（例如 responder 首个信令
    /// 早于数据连接建立）。
    connection_session_id: Option<SessionId>,
    /// Signaling uses this only for sessions created by the pure state-machine
    /// tests. Runtime sessions keep the peer inside `RealtimeIoDriver` and
    /// access it through `driver` so the socket and sans-I/O peer share one
    /// owner.
    peer: Option<WebRtcPeer>,
    driver: Option<RealtimeIoDriverHandle>,
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
            let _ = with_session_peer(&mut session, WebRtcPeer::close);
        }
    }

    /// §22：ConnectionSession 销毁（transport 丢失）时关闭绑定在该 ConnectionSession
    /// 上的所有 RealtimeSession——移除注册、销毁 WebRTC peer。返回 `(realtime_id,
    /// peer_id, close_revision)`，供调用方取消 supervised I/O 任务并发出 Closed 事件。
    fn close_for_connection_session(
        &mut self,
        peer_id: &str,
        session_id: SessionId,
    ) -> Vec<(String, String, u64)> {
        let mut closed = Vec::new();
        let matching = self
            .sessions
            .iter()
            .filter(|(_, session)| {
                session.peer_id == peer_id && session.connection_session_id == Some(session_id)
            })
            .map(|(realtime_id, _)| realtime_id.clone())
            .collect::<Vec<_>>();
        for realtime_id in matching {
            let Some(mut session) = self.sessions.remove(&realtime_id) else {
                continue;
            };
            let close_revision = session.revision.saturating_add(1);
            let _ = with_session_peer(&mut session, WebRtcPeer::close);
            closed.push((realtime_id, session.peer_id, close_revision));
        }
        closed
    }
}

struct OutboundSignal {
    realtime_id: String,
    peer_id: String,
    kind: RealtimeSignalKind,
    revision: u64,
    payload: Vec<u8>,
}

/// 一条已解码的入站 WebRTC 信令。v1 信封（revision 内嵌）与 v2 控制面帧
/// （revision 独立字段）在进入状态机前都归一化为该三元组。
struct InboundSignal {
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

    let mut driver = create_io_driver(&state, runtime_webrtc_config())
        .await
        .map_err(|error| {
            realtime_error(
                network_protocol::NetworkErrorCode::IoError,
                error.to_string(),
                "start_realtime",
                &command.peer_id,
            )
        })?;
    driver
        .peer_mut()
        .create_data_channel("ssh-mobile-realtime", Default::default())
        .map_err(|error| {
            realtime_error(
                network_protocol::NetworkErrorCode::IoError,
                error.to_string(),
                "create_webrtc_data_channel",
                &command.peer_id,
            )
        })?;
    let offer = driver.peer_mut().create_offer().map_err(|error| {
        realtime_error(
            network_protocol::NetworkErrorCode::IoError,
            error.to_string(),
            "create_webrtc_offer",
            &command.peer_id,
        )
    })?;
    let revision = driver.peer_mut().signaling_revision();
    let driver = driver.into_handle();
    let realtime_id = command.realtime_id;
    let peer_id = command.peer_id;
    // §22：PeerConnection 绑定在创建它的 ConnectionSession 上（transport 丢失时
    // 随 ConnectionSession 一并销毁）。创建时若尚无数据连接，绑定为 None。
    let connection_session_id = state.sessions.current_session_id(&peer_id).await;
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
            connection_session_id,
            peer: None,
            driver: Some(driver.clone()),
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
    if let Err(error) = send_signal(&state, &outbound).await {
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
    if state
        .task_supervisor
        .spawn_session(
            realtime_task_key(&realtime_id),
            "realtime-io",
            run_realtime_session_io(state.clone(), realtime_id.clone(), peer_id.clone(), driver),
        )
        .is_none()
    {
        state.realtime.lock().await.sessions.remove(&realtime_id);
        return Err(realtime_error(
            network_protocol::NetworkErrorCode::Cancelled,
            "runtime task supervisor is stopping",
            "start_realtime",
            &peer_id,
        ));
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
    state
        .task_supervisor
        .cancel_session(&realtime_task_key(&command.realtime_id))
        .await;
    let _ = with_session_peer(&mut session, WebRtcPeer::close);
    let outbound = OutboundSignal {
        realtime_id: command.realtime_id.clone(),
        peer_id: session.peer_id.clone(),
        kind: RealtimeSignalKind::WebRtcClose,
        revision: close_revision,
        payload: b"close".to_vec(),
    };
    if let Err(error) = send_signal(state, &outbound).await {
        tracing::debug!(error = %error.message, "failed to send WebRTC close signal");
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
    send_signal(state, &outbound).await?;
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

/// v1 Relay 数据面信令入口（deprecated，Step 11 迁移到 v2 控制面）。
/// 解码 v1 base64 信封（revision 内嵌），再进入与 v2 共享的协商核心。
pub(crate) async fn handle_relay_signal(
    state: &Arc<RuntimeState>,
    kind: &str,
    realtime_id: &str,
    peer_id: &str,
    payload: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let kind = signal_kind_from_control(kind)
        .ok_or_else(|| boxed_message("invalid WebRTC control type"))?;
    let envelope = decode_envelope(payload)?;
    handle_realtime_signal(
        state,
        kind,
        realtime_id,
        peer_id,
        envelope.revision,
        envelope.payload_bytes(),
    )
    .await
}

/// v2 控制面信令入口（§17/§22：WebRTC signaling 经 Relay Control Plane）。
/// `RealtimeSignal` 帧携带独立 `revision` 与原始 payload（无 v1 信封）。
pub(crate) async fn handle_v2_realtime_signal(
    state: &Arc<RuntimeState>,
    signal: &V2RealtimeSignal,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let kind = RealtimeSignalKind::try_from(signal.kind)
        .map_err(|_| boxed_message("invalid v2 WebRTC signal kind"))?;
    handle_realtime_signal(
        state,
        kind,
        &signal.realtime_id,
        &signal.target_device_id,
        signal.revision,
        signal.payload.clone(),
    )
    .await
}

/// WebRTC signaling 协商核心：v1 / v2 两条入站路径共用。
///
/// 入站 Offer 在没有 RealtimeSession 时会创建一个新的 responder 会话；该会话按
/// §22 绑定到发起方当前 ConnectionSession（`connection_session_id`），transport 丢失
/// 时随 ConnectionSession 一并销毁。`outcome.outbound`（Answer / restart Offer / ICE）
/// 经 v2 控制面回发。
async fn handle_realtime_signal(
    state: &Arc<RuntimeState>,
    kind: RealtimeSignalKind,
    realtime_id: &str,
    peer_id: &str,
    revision: u64,
    payload: Vec<u8>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    validate_realtime_id(realtime_id).map_err(boxed_protocol_error)?;
    validate_peer(state, peer_id)
        .await
        .map_err(boxed_protocol_error)?;
    validate_signal(kind, revision, &payload).map_err(boxed_protocol_error)?;

    let pending_driver = if kind == RealtimeSignalKind::WebRtcOffer
        && !state
            .realtime
            .lock()
            .await
            .sessions
            .contains_key(realtime_id)
    {
        Some(
            create_io_driver(state, runtime_webrtc_config())
                .await
                .map_err(|error| boxed_message(error.to_string()))?
                .into_handle(),
        )
    } else {
        None
    };
    // §22：responder 新建会话时绑定当前 ConnectionSession；后续 transport 丢失据此
    // 关闭 RealtimeSession。
    let connection_session_id = state.sessions.current_session_id(peer_id).await;

    let pending_driver_for_spawn = pending_driver.clone();
    let outcome = {
        let mut manager = state.realtime.lock().await;
        apply_signal_with_driver(
            &mut manager,
            realtime_id,
            peer_id,
            InboundSignal {
                kind,
                revision,
                payload: payload.clone(),
            },
            pending_driver,
            connection_session_id,
        )?
    };

    let driver_to_spawn = if let Some(pending_driver) = pending_driver_for_spawn {
        let sessions = state.realtime.lock().await;
        sessions.sessions.get(realtime_id).and_then(|session| {
            session
                .driver
                .as_ref()
                .filter(|driver| Arc::ptr_eq(driver, &pending_driver))
                .cloned()
        })
    } else {
        None
    };
    let mut spawned_io = false;
    if let Some(driver) = driver_to_spawn {
        if state
            .task_supervisor
            .spawn_session(
                realtime_task_key(realtime_id),
                "realtime-io",
                run_realtime_session_io(
                    Arc::clone(state),
                    realtime_id.to_owned(),
                    peer_id.to_owned(),
                    driver,
                ),
            )
            .is_none()
        {
            let removed = state.realtime.lock().await.sessions.remove(realtime_id);
            if let Some(mut removed) = removed {
                let _ = with_session_peer(&mut removed, WebRtcPeer::close);
            }
            return Err(boxed_message("runtime task supervisor is stopping"));
        }
        spawned_io = true;
    }

    if outcome.state == RealtimeSessionState::Closed {
        state
            .task_supervisor
            .cancel_session(&realtime_task_key(realtime_id))
            .await;
    }

    emit_realtime_signal(
        &state.event_tx,
        realtime_id,
        peer_id,
        kind as i32,
        revision,
        payload,
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
        if let Err(error) = send_signal(state, &outbound).await {
            if spawned_io {
                state
                    .task_supervisor
                    .cancel_session(&realtime_task_key(realtime_id))
                    .await;
                remove_realtime_session(state, realtime_id, peer_id).await;
            }
            return Err(boxed_protocol_error(error));
        }
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

#[cfg(test)]
fn apply_signal(
    manager: &mut RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    kind: RealtimeSignalKind,
    revision: u64,
    payload: Vec<u8>,
) -> Result<SignalOutcome, Box<dyn std::error::Error + Send + Sync>> {
    apply_signal_with_driver(
        manager,
        realtime_id,
        peer_id,
        InboundSignal {
            kind,
            revision,
            payload,
        },
        None,
        None,
    )
}

fn apply_signal_with_driver(
    manager: &mut RealtimeManager,
    realtime_id: &str,
    peer_id: &str,
    signal: InboundSignal,
    pending_driver: Option<RealtimeIoDriverHandle>,
    connection_session_id: Option<SessionId>,
) -> Result<SignalOutcome, Box<dyn std::error::Error + Send + Sync>> {
    let InboundSignal {
        kind,
        revision,
        payload,
    } = signal;
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
        let _ = with_session_peer(&mut session, WebRtcPeer::close);
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
            let mut session = match existing {
                Some(session) => session,
                None => match pending_driver {
                    Some(driver) => RealtimeSession {
                        peer_id: peer_id.to_string(),
                        connection_session_id,
                        peer: None,
                        driver: Some(driver),
                        revision: 0,
                        remote_revision: 0,
                        ice_revision: 0,
                        seen_candidates: HashSet::new(),
                    },
                    None => RealtimeSession {
                        peer_id: peer_id.to_string(),
                        connection_session_id,
                        peer: Some(
                            WebRtcPeer::new(WebRtcConfig::default())
                                .expect("validated default WebRTC configuration"),
                        ),
                        driver: None,
                        revision: 0,
                        remote_revision: 0,
                        ice_revision: 0,
                        seen_candidates: HashSet::new(),
                    },
                },
            };
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
            if let Err(error) =
                with_session_peer(&mut session, |peer| peer.accept_remote_offer(description))
            {
                if had_existing {
                    manager.sessions.insert(realtime_id.to_string(), session);
                }
                return Err(boxed_message(error.to_string()));
            }
            let answer = match with_session_peer(&mut session, WebRtcPeer::create_answer) {
                Ok(answer) => answer,
                Err(error) => {
                    if had_existing {
                        manager.sessions.insert(realtime_id.to_string(), session);
                    }
                    return Err(boxed_message(error.to_string()));
                }
            };
            let answer_revision = with_session_peer(&mut session, |peer| {
                Ok::<_, WebRtcError>(peer.signaling_revision())
            })
            .map_err(|error| boxed_message(error.to_string()))?
            .max(revision);
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
            let description =
                SessionDescription::new(DescriptionType::Answer, String::from_utf8(payload)?)?;
            with_session_peer(&mut *session, |peer| peer.accept_remote_answer(description))?;
            session.revision = with_session_peer(&mut *session, |peer| {
                Ok::<_, WebRtcError>(peer.signaling_revision())
            })?
            .max(revision);
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
            let candidate =
                IceCandidate::new(String::from_utf8(payload.clone())?, None, None, None)?;
            with_session_peer(&mut *session, |peer| {
                peer.add_remote_ice_candidate(candidate)
            })?;
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
            with_session_peer(&mut *session, WebRtcPeer::restart_ice)?;
            let offer = with_session_peer(&mut *session, WebRtcPeer::create_offer)?;
            session.revision = with_session_peer(&mut *session, |peer| {
                Ok::<_, WebRtcError>(peer.signaling_revision())
            })?
            .max(revision);
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

fn with_session_peer<T>(
    session: &mut RealtimeSession,
    operation: impl FnOnce(&mut WebRtcPeer) -> Result<T, WebRtcError>,
) -> Result<T, WebRtcError> {
    if let Some(driver) = session.driver.as_ref() {
        let mut driver = driver
            .lock()
            .map_err(|_| WebRtcError::Io("realtime I/O driver mutex was poisoned".to_owned()))?;
        return operation(driver.peer_mut());
    }
    if let Some(peer) = session.peer.as_mut() {
        return operation(peer);
    }
    Err(WebRtcError::Io(
        "realtime session has no WebRTC peer owner".to_owned(),
    ))
}

fn runtime_webrtc_config() -> WebRtcConfig {
    let mut config = WebRtcConfig::default();
    let turn_urls = std::env::var("SSH_MOBILE_TURN_SERVERS")
        .ok()
        .or_else(|| std::env::var("SSH_MOBILE_TURN_URL").ok())
        .unwrap_or_default();
    if !turn_urls.trim().is_empty() {
        let username = std::env::var("SSH_MOBILE_TURN_USERNAME").unwrap_or_default();
        let credential = std::env::var("SSH_MOBILE_TURN_CREDENTIAL").unwrap_or_default();
        config.ice_servers = turn_urls
            .split(',')
            .map(str::trim)
            .filter(|url| !url.is_empty())
            .map(|url| IceServerConfig::turn(url, &username, &credential))
            .collect();
        config.relay_only = matches!(
            std::env::var("SSH_MOBILE_TURN_RELAY_ONLY").ok().as_deref(),
            Some("1" | "true" | "TRUE" | "yes" | "YES")
        );
    }
    config
}

async fn create_io_driver(
    state: &RuntimeState,
    config: WebRtcConfig,
) -> Result<RealtimeIoDriver, WebRtcError> {
    let bind_ip = state
        .endpoint
        .read()
        .await
        .as_ref()
        .and_then(|endpoint| endpoint.local_addr().ok().map(|address| address.ip()))
        .unwrap_or(IpAddr::V4(Ipv4Addr::LOCALHOST));
    let bind_addr = SocketAddr::new(bind_ip, 0);
    let advertised_ip = (!bind_ip.is_unspecified()).then_some(bind_ip);
    let peer = WebRtcPeer::new(config)?;
    RealtimeIoDriver::bind_with_advertised_ip(peer, bind_addr, advertised_ip).await
}

fn realtime_task_key(realtime_id: &str) -> String {
    format!("realtime:{realtime_id}")
}

async fn run_realtime_session_io(
    state: Arc<RuntimeState>,
    realtime_id: String,
    peer_id: String,
    driver: RealtimeIoDriverHandle,
) {
    let (event_tx, mut event_rx) = unbounded_channel();
    let io = run_realtime_io(driver, event_tx);
    tokio::pin!(io);
    loop {
        tokio::select! {
            result = &mut io => {
                if let Err(error) = result {
                    let revision = session_revision(&state, &realtime_id).await;
                    emit_realtime_state(
                        &state.event_tx,
                        &realtime_id,
                        &peer_id,
                        RealtimeSessionState::Failed as i32,
                        revision,
                        Some(realtime_error(
                            network_protocol::NetworkErrorCode::IoError,
                            error.to_string(),
                            "realtime_io",
                            &peer_id,
                        )),
                    );
                }
                remove_realtime_session(&state, &realtime_id, &peer_id).await;
                break;
            }
            event = event_rx.recv() => {
                let Some(event) = event else { break; };
                if handle_io_event(&state, &realtime_id, &peer_id, event).await {
                    remove_realtime_session(&state, &realtime_id, &peer_id).await;
                    break;
                }
            }
        }
    }
}

async fn handle_io_event(
    state: &RuntimeState,
    realtime_id: &str,
    peer_id: &str,
    event: RealtimeIoEvent,
) -> bool {
    match event {
        RealtimeIoEvent::LocalIceCandidate(candidate) => {
            forward_local_candidate(state, realtime_id, peer_id, candidate).await;
            false
        }
        RealtimeIoEvent::PeerConnected => {
            let revision = session_revision(state, realtime_id).await;
            emit_realtime_state(
                &state.event_tx,
                realtime_id,
                peer_id,
                RealtimeSessionState::Connected as i32,
                revision,
                None,
            );
            // Session 稳定后发布完整快照；订阅方在 delta 状态之后看到一致快照。
            emit_realtime_snapshot(
                &state.event_tx,
                realtime_id,
                peer_id,
                RealtimeSessionState::Connected as i32,
                revision,
                None,
            );
            false
        }
        RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed => {
            emit_realtime_state(
                &state.event_tx,
                realtime_id,
                peer_id,
                RealtimeSessionState::Failed as i32,
                session_revision(state, realtime_id).await,
                Some(realtime_error(
                    network_protocol::NetworkErrorCode::IoError,
                    "WebRTC peer connection failed",
                    "realtime_io",
                    peer_id,
                )),
            );
            true
        }
        RealtimeIoEvent::PeerDisconnected => {
            emit_realtime_state(
                &state.event_tx,
                realtime_id,
                peer_id,
                RealtimeSessionState::Negotiating as i32,
                session_revision(state, realtime_id).await,
                None,
            );
            false
        }
        RealtimeIoEvent::DataChannelMessage {
            channel_id,
            is_string,
            payload,
        } => {
            tracing::debug!(
                realtime_id,
                peer_id,
                channel_id,
                is_string,
                payload_bytes = payload.len(),
                "WebRTC data channel payload received by native realtime owner"
            );
            false
        }
        RealtimeIoEvent::IceConnected
        | RealtimeIoEvent::DataChannelOpened(_)
        | RealtimeIoEvent::DataChannelClosed(_) => false,
    }
}

async fn remove_realtime_session(state: &RuntimeState, realtime_id: &str, peer_id: &str) {
    let removed = {
        let mut sessions = state.realtime.lock().await;
        let should_remove = sessions
            .sessions
            .get(realtime_id)
            .is_some_and(|session| session.peer_id == peer_id);
        should_remove
            .then(|| sessions.sessions.remove(realtime_id))
            .flatten()
    };
    if let Some(mut session) = removed {
        let _ = with_session_peer(&mut session, WebRtcPeer::close);
    }
}

/// §22：ConnectionSession 销毁（transport 丢失 / 显式断开 / 被新连接替换）时关闭
/// 绑定在它上面的所有 RealtimeSession。旧 RealtimeSession 发出 `Closed` 事件并被移除；
/// 用户/feature 可重新请求，manager 会经新的 Resolve → Connection → signaling 建立
/// 全新的 PeerConnection——绝不透明恢复旧 PeerConnection 对象。
pub(crate) async fn close_realtime_sessions_for_session(
    state: &RuntimeState,
    peer_id: &str,
    session_id: SessionId,
) {
    let closed = {
        let mut manager = state.realtime.lock().await;
        manager.close_for_connection_session(peer_id, session_id)
    };
    for (realtime_id, session_peer_id, close_revision) in closed {
        state
            .task_supervisor
            .cancel_session(&realtime_task_key(&realtime_id))
            .await;
        emit_realtime_state(
            &state.event_tx,
            &realtime_id,
            &session_peer_id,
            RealtimeSessionState::Closed as i32,
            close_revision,
            None,
        );
    }
}

async fn session_revision(state: &RuntimeState, realtime_id: &str) -> u64 {
    state
        .realtime
        .lock()
        .await
        .sessions
        .get(realtime_id)
        .map(|session| session.revision)
        .unwrap_or_default()
}

async fn forward_local_candidate(
    state: &RuntimeState,
    realtime_id: &str,
    peer_id: &str,
    candidate: IceCandidate,
) {
    let (session_peer_id, revision) = {
        let sessions = state.realtime.lock().await;
        let Some(session) = sessions.sessions.get(realtime_id) else {
            return;
        };
        (session.peer_id.clone(), session.ice_revision)
    };
    if session_peer_id != peer_id {
        return;
    }
    let payload = candidate.candidate.into_bytes();
    let outbound = OutboundSignal {
        realtime_id: realtime_id.to_owned(),
        peer_id: peer_id.to_owned(),
        kind: RealtimeSignalKind::IceCandidate,
        revision,
        payload,
    };
    if let Err(error) = send_signal(state, &outbound).await {
        tracing::debug!(peer_id, error = %error.message, "failed to forward WebRTC ICE candidate");
        return;
    }
    emit_realtime_signal(
        &state.event_tx,
        realtime_id,
        peer_id,
        RealtimeSignalKind::IceCandidate as i32,
        revision,
        outbound.payload,
    );
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

/// §22：WebRTC 信令经 v2 Relay Control Plane 路由（`signal_webrtc`），与媒体面
/// (P2P/TURN) 分离。v2 控制面不可用时回退到 v1 Relay 数据面控制帧（deprecated，
/// Step 11 删除），保证控制 socket 重连窗口内信令仍可达。
async fn send_signal(
    state: &RuntimeState,
    signal: &OutboundSignal,
) -> Result<(), network_protocol::NetworkError> {
    if let Some(control) = state.relay_control.read().await.clone() {
        if control.is_usable().await {
            let kind = to_v2_signal_kind(signal.kind);
            let result = control
                .signal_webrtc(
                    &signal.realtime_id,
                    &signal.peer_id,
                    kind,
                    signal.revision,
                    &signal.payload,
                )
                .await;
            if let Err(error) = result {
                tracing::debug!(
                    peer_id = %signal.peer_id,
                    error = %error,
                    "v2 control plane WebRTC signaling failed"
                );
            } else {
                return Ok(());
            }
        }
    }
    send_signal_v1(state, signal).await
}

async fn send_signal_v1(
    state: &RuntimeState,
    signal: &OutboundSignal,
) -> Result<(), network_protocol::NetworkError> {
    let Some(relay) = state.relay.read().await.clone() else {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::RelayError,
            "Relay signaling route is unavailable",
        ));
    };
    if !relay.is_usable().await {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::RelayError,
            "Relay signaling route is disconnected",
        ));
    }
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

/// network-protocol 的 WebRTC 信号类型 → v2 控制面 wire 类型（值一一对应）。
fn to_v2_signal_kind(kind: RealtimeSignalKind) -> V2RealtimeSignalKind {
    match kind {
        RealtimeSignalKind::WebRtcOffer => V2RealtimeSignalKind::Offer,
        RealtimeSignalKind::WebRtcAnswer => V2RealtimeSignalKind::Answer,
        RealtimeSignalKind::IceCandidate => V2RealtimeSignalKind::IceCandidate,
        RealtimeSignalKind::IceRestart => V2RealtimeSignalKind::IceRestart,
        RealtimeSignalKind::WebRtcClose => V2RealtimeSignalKind::Close,
        RealtimeSignalKind::Unspecified => V2RealtimeSignalKind::Unspecified,
    }
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
    use network_protocol::{network_event, NetworkErrorCode};
    use network_relay::v2::{DiscoveryAck, DiscoverySnapshot, ResolvePeerResponse};
    use network_relay::RelayError;
    use network_webrtc::{DataChannelReliability, SignalingState};
    use std::future::Future;
    use std::pin::Pin;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Mutex;
    use std::time::Duration;

    use crate::discovery::DiscoveryControlPlane;
    use crate::runtime::PeerConfig;
    use crate::session::ConnectDecision;

    #[tokio::test]
    async fn realtime_snapshot_carries_authoritative_state_and_revision_after_connected() {
        let (event_tx, mut event_rx) = unbounded_channel();
        let state = RuntimeState::new(event_tx, Arc::new(std::sync::atomic::AtomicU16::new(0)));
        let realtime_id = "00112233445566778899aabbccddeeff";
        {
            let mut manager = state.realtime.lock().await;
            manager.sessions.insert(
                realtime_id.into(),
                RealtimeSession {
                    peer_id: "peer-a".into(),
                    connection_session_id: None,
                    peer: None,
                    driver: None,
                    revision: 7,
                    remote_revision: 2,
                    ice_revision: 3,
                    seen_candidates: HashSet::new(),
                },
            );
        }
        let finished = handle_io_event(
            &state,
            realtime_id,
            "peer-a",
            RealtimeIoEvent::PeerConnected,
        )
        .await;
        assert!(!finished);
        let mut state_events = Vec::new();
        let mut snapshots = Vec::new();
        while let Ok(event) = event_rx.try_recv() {
            match event.payload {
                Some(network_event::Payload::RealtimeState(delta)) => state_events.push(delta),
                Some(network_event::Payload::RealtimeSnapshot(snapshot)) => {
                    snapshots.push(snapshot)
                }
                _ => {}
            }
        }
        assert_eq!(state_events.len(), 1);
        assert_eq!(
            state_events[0].state,
            RealtimeSessionState::Connected as i32
        );
        assert_eq!(snapshots.len(), 1);
        assert_eq!(snapshots[0].realtime_id, realtime_id);
        assert_eq!(snapshots[0].peer_id, "peer-a");
        assert_eq!(snapshots[0].state, RealtimeSessionState::Connected as i32);
        assert_eq!(snapshots[0].revision, 7);
        assert!(snapshots[0].error.is_none());
    }

    #[test]
    fn signaling_envelope_round_trips_revision_and_binary_payload() {
        let encoded = encode_envelope(3, b"sdp-bytes").expect("encode");
        let outer = URL_SAFE_NO_PAD.encode(encoded);
        let decoded = decode_envelope(&outer).expect("decode");
        assert_eq!(decoded.revision, 3);
        assert_eq!(decoded.payload, b"sdp-bytes");
    }

    #[tokio::test]
    async fn task_supervisor_drives_two_runtime_realtime_data_channels() {
        let caller = RealtimeIoDriver::bind(
            WebRtcPeer::new(WebRtcConfig::default()).expect("caller peer"),
            "127.0.0.1:0".parse().unwrap(),
        )
        .await
        .expect("caller driver")
        .into_handle();
        let responder = RealtimeIoDriver::bind(
            WebRtcPeer::new(WebRtcConfig::default()).expect("responder peer"),
            "127.0.0.1:0".parse().unwrap(),
        )
        .await
        .expect("responder driver")
        .into_handle();

        let channel_id = caller
            .lock()
            .unwrap()
            .peer_mut()
            .create_data_channel("runtime-e2e", DataChannelReliability::default())
            .expect("data channel");
        let offer = caller.lock().unwrap().peer_mut().create_offer().unwrap();
        let answer = {
            let mut responder_driver = responder.lock().unwrap();
            responder_driver
                .peer_mut()
                .accept_remote_offer(offer)
                .unwrap();
            responder_driver.peer_mut().create_answer().unwrap()
        };
        caller
            .lock()
            .unwrap()
            .peer_mut()
            .accept_remote_answer(answer)
            .unwrap();

        let supervisor = crate::task_supervisor::RuntimeTaskSupervisor::new();
        let (caller_tx, mut caller_rx) = unbounded_channel();
        let (responder_tx, mut responder_rx) = unbounded_channel();
        let caller_task_handle = Arc::clone(&caller);
        let responder_task_handle = Arc::clone(&responder);
        assert!(supervisor
            .spawn_session("realtime:caller", "webrtc-io", async move {
                let _ = run_realtime_io(caller_task_handle, caller_tx).await;
            },)
            .is_some());
        assert!(supervisor
            .spawn_session("realtime:responder", "webrtc-io", async move {
                let _ = run_realtime_io(responder_task_handle, responder_tx).await;
            },)
            .is_some());

        let mut caller_open = false;
        let mut responder_open = false;
        let open_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while !(caller_open && responder_open) {
            tokio::select! {
                Some(event) = caller_rx.recv() => {
                    caller_open |= matches!(event, RealtimeIoEvent::DataChannelOpened(_));
                    assert!(!matches!(event, RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed));
                }
                Some(event) = responder_rx.recv() => {
                    responder_open |= matches!(event, RealtimeIoEvent::DataChannelOpened(_));
                    assert!(!matches!(event, RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed));
                }
                _ = tokio::time::sleep_until(open_deadline) => panic!("supervised data channel did not open"),
            }
        }
        caller
            .lock()
            .unwrap()
            .peer_mut()
            .send_data(channel_id, b"runtime-frame")
            .unwrap();
        let payload_deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        let payload = loop {
            tokio::select! {
                Some(event) = responder_rx.recv() => {
                    if let RealtimeIoEvent::DataChannelMessage { payload, .. } = event {
                        break payload;
                    }
                }
                Some(_event) = caller_rx.recv() => {}
                _ = tokio::time::sleep_until(payload_deadline) => panic!("supervised data channel payload not received"),
            }
        };
        assert_eq!(payload, b"runtime-frame");

        supervisor.cancel_session("realtime:caller").await;
        supervisor.cancel_session("realtime:responder").await;
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
                connection_session_id: None,
                peer: Some(caller),
                driver: None,
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

    // -----------------------------------------------------------------------
    // §22 / §40 Recovery：ConnectionSession 丢失 → RealtimeSession Closed →
    // 重新建立 → 全新 PeerConnection（绝不透明恢复旧 PeerConnection 对象）。
    // -----------------------------------------------------------------------

    /// 全新 PeerConnection 首个 Offer 的 signaling revision（`WebRtcPeer::create_offer`
    /// 把计数器从 0 推进到 1；fresh session 从该起点重启计数，绝不继承旧会话的 revision）。
    const FRESH_OFFER_REVISION: u64 = 1;

    #[tokio::test]
    async fn transport_loss_closes_realtime_session_and_reestablish_uses_a_fresh_peer() {
        let realtime_id = "00112233445566778899aabbccddeeff";
        let s1 = SessionId::from_bytes([1u8; 16]);
        let s2 = SessionId::from_bytes([2u8; 16]);

        // 第一代：responder 从 offer 建立，绑定 ConnectionSession S1，持有 driver1。
        let mut caller = WebRtcPeer::new(WebRtcConfig::default()).expect("caller");
        caller
            .create_data_channel("ssh-mobile-realtime", Default::default())
            .expect("data channel");
        let offer = caller.create_offer().expect("offer");
        let offer_sdp = offer.sdp.clone();
        let offer_revision = caller.signaling_revision();
        let driver1 = RealtimeIoDriver::bind(
            WebRtcPeer::new(WebRtcConfig::default()).expect("responder peer"),
            "127.0.0.1:0".parse().unwrap(),
        )
        .await
        .expect("responder driver")
        .into_handle();

        let mut manager = RealtimeManager::default();
        let first = apply_signal_with_driver(
            &mut manager,
            realtime_id,
            "peer-a",
            InboundSignal {
                kind: RealtimeSignalKind::WebRtcOffer,
                revision: offer_revision,
                payload: offer.sdp.into_bytes(),
            },
            Some(driver1.clone()),
            Some(s1),
        )
        .expect("first answer");
        assert_eq!(first.state, RealtimeSessionState::Negotiating);
        assert_eq!(
            manager.sessions[realtime_id].connection_session_id,
            Some(s1)
        );

        // transport 丢失（ConnectionSession S1 销毁）→ RealtimeSession Closed。
        let closed = manager.close_for_connection_session("peer-a", s1);
        assert_eq!(closed.len(), 1);
        assert_eq!(closed[0].0, realtime_id);
        assert_eq!(closed[0].1, "peer-a");
        assert_eq!(closed[0].2, first.revision + 1);
        assert!(!manager.sessions.contains_key(realtime_id));
        // 旧 PeerConnection 对象被销毁，其 DTLS/ICE 状态不可复用。
        assert!(matches!(
            driver1.lock().unwrap().peer_mut().signaling_state(),
            SignalingState::Closed
        ));

        // 第二代：新的 Resolve → Connection S2 → 重新 signaling → 全新 PeerConnection。
        let mut caller2 = WebRtcPeer::new(WebRtcConfig::default()).expect("caller 2");
        caller2
            .create_data_channel("ssh-mobile-realtime", Default::default())
            .expect("data channel");
        let offer2 = caller2.create_offer().expect("offer 2");
        let offer2_sdp = offer2.sdp.clone();
        let offer2_revision = caller2.signaling_revision();
        let driver2 = RealtimeIoDriver::bind(
            WebRtcPeer::new(WebRtcConfig::default()).expect("responder peer 2"),
            "127.0.0.1:0".parse().unwrap(),
        )
        .await
        .expect("responder driver 2")
        .into_handle();
        let second = apply_signal_with_driver(
            &mut manager,
            realtime_id,
            "peer-a",
            InboundSignal {
                kind: RealtimeSignalKind::WebRtcOffer,
                revision: offer2_revision,
                payload: offer2.sdp.into_bytes(),
            },
            Some(driver2.clone()),
            Some(s2),
        )
        .expect("second answer");
        assert_eq!(second.state, RealtimeSessionState::Negotiating);
        assert_eq!(
            manager.sessions[realtime_id].connection_session_id,
            Some(s2)
        );
        // 新会话是全新 PeerConnection（对象不复用、SDP 是新 DTLS/ICE 状态），
        // 且计数从该会话自己的起点重启。
        assert!(
            !Arc::ptr_eq(&driver1, &driver2),
            "new PeerConnection must be a fresh object, never the old one"
        );
        assert_ne!(
            offer_sdp, offer2_sdp,
            "new offer must carry fresh DTLS/ICE state"
        );
        assert_eq!(manager.sessions[realtime_id].revision, second.revision);
    }

    #[test]
    fn close_for_connection_session_only_affects_bound_realtime_sessions() {
        let realtime_id = "00112233445566778899aabbccddeeff";
        let other_realtime_id = "ffeeddccbbaa99887766554433221100";
        let s1 = SessionId::from_bytes([1u8; 16]);
        let s2 = SessionId::from_bytes([2u8; 16]);
        let mut manager = RealtimeManager::default();
        let insert = |manager: &mut RealtimeManager,
                      id: &str,
                      peer_id: &str,
                      connection_session_id: Option<SessionId>| {
            manager.sessions.insert(
                id.to_string(),
                RealtimeSession {
                    peer_id: peer_id.to_string(),
                    connection_session_id,
                    peer: Some(
                        WebRtcPeer::new(WebRtcConfig::default())
                            .expect("validated default WebRTC configuration"),
                    ),
                    driver: None,
                    revision: 1,
                    remote_revision: 0,
                    ice_revision: 1,
                    seen_candidates: HashSet::new(),
                },
            );
        };
        // 目标：peer-a 绑定 S1 → 应被关闭。
        insert(&mut manager, realtime_id, "peer-a", Some(s1));
        // peer-a 绑定 S2 → 不受影响。
        insert(&mut manager, other_realtime_id, "peer-a", Some(s2));
        // peer-b 绑定 S1 → 不同 peer，不受影响。
        insert(
            &mut manager,
            "01010101010101010101010101010101",
            "peer-b",
            Some(s1),
        );
        // peer-a 未绑定 ConnectionSession → 不受影响。
        insert(
            &mut manager,
            "02020202020202020202020202020202",
            "peer-a",
            None,
        );

        let closed = manager.close_for_connection_session("peer-a", s1);
        assert_eq!(closed.len(), 1);
        assert_eq!(closed[0].0, realtime_id);
        assert!(!manager.sessions.contains_key(realtime_id));
        assert!(manager.sessions.contains_key(other_realtime_id));
        assert!(manager
            .sessions
            .contains_key("01010101010101010101010101010101"));
        assert!(manager
            .sessions
            .contains_key("02020202020202020202020202020202"));
    }

    /// 记录 v2 控制面 WebRTC 信令的 mock（可配置发送失败模拟信令丢失）。
    #[derive(Clone)]
    struct SignalCall {
        realtime_id: String,
        target_device_id: String,
        kind: V2RealtimeSignalKind,
        revision: u64,
        payload: Vec<u8>,
    }

    struct RecordingControl {
        signals: Mutex<Vec<SignalCall>>,
        fail_signals: AtomicBool,
    }

    impl RecordingControl {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                signals: Mutex::new(Vec::new()),
                fail_signals: AtomicBool::new(false),
            })
        }

        fn signal_calls(&self) -> Vec<SignalCall> {
            self.signals.lock().unwrap().clone()
        }
    }

    impl DiscoveryControlPlane for RecordingControl {
        fn publish_discovery(
            &self,
            _request_id: u64,
            _snapshot: DiscoverySnapshot,
        ) -> Pin<Box<dyn Future<Output = Result<DiscoveryAck, RelayError>> + Send + '_>> {
            Box::pin(async move { Err(RelayError::NotConnected) })
        }

        fn resolve_peer(
            &self,
            _target_device_id: &str,
        ) -> Pin<Box<dyn Future<Output = Result<ResolvePeerResponse, RelayError>> + Send + '_>>
        {
            Box::pin(async move { Err(RelayError::NotConnected) })
        }

        fn is_usable(&self) -> Pin<Box<dyn Future<Output = bool> + Send + '_>> {
            Box::pin(async move { true })
        }

        fn signal_webrtc(
            &self,
            realtime_id: &str,
            target_device_id: &str,
            kind: V2RealtimeSignalKind,
            revision: u64,
            payload: &[u8],
        ) -> Pin<Box<dyn Future<Output = Result<(), RelayError>> + Send + '_>> {
            let fail = self.fail_signals.load(Ordering::Acquire);
            let call = SignalCall {
                realtime_id: realtime_id.to_string(),
                target_device_id: target_device_id.to_string(),
                kind,
                revision,
                payload: payload.to_vec(),
            };
            Box::pin(async move {
                if fail {
                    Err(RelayError::NotConnected)
                } else {
                    self.signals.lock().unwrap().push(call);
                    Ok(())
                }
            })
        }
    }

    async fn realtime_test_state() -> (
        Arc<RuntimeState>,
        tokio::sync::mpsc::UnboundedReceiver<network_protocol::NetworkEvent>,
    ) {
        let (event_tx, event_rx) = unbounded_channel();
        (
            Arc::new(RuntimeState::new(
                event_tx,
                Arc::new(std::sync::atomic::AtomicU16::new(0)),
            )),
            event_rx,
        )
    }

    async fn register_realtime_peer(state: &RuntimeState, peer_id: &str) {
        state.peers.write().await.insert(
            peer_id.to_string(),
            PeerConfig {
                endpoint: None,
                identity_public_key: [7u8; 32],
                e2e_public_key: [8u8; 32],
            },
        );
    }

    #[tokio::test]
    async fn signaling_flows_over_v2_control_plane_and_transport_loss_then_reestablishes() {
        let (state, mut event_rx) = realtime_test_state().await;
        let control = RecordingControl::new();
        *state.relay_control.write().await = Some(control.clone());
        register_realtime_peer(&state, "peer-a").await;
        let s1 = match state.sessions.begin_connect("peer-a").await {
            ConnectDecision::Started(session_id) => session_id,
            decision => panic!("unexpected Session decision: {decision:?}"),
        };
        let realtime_id = "00112233445566778899aabbccddeeff";

        // 首次建立：Offer 经 v2 控制面发出（signal_webrtc），并绑定 ConnectionSession S1。
        start_session(
            state.clone(),
            StartRealtimeSessionCommand {
                realtime_id: realtime_id.into(),
                peer_id: "peer-a".into(),
            },
        )
        .await
        .expect("first realtime session");
        let first_calls = control.signal_calls();
        assert_eq!(first_calls.len(), 1);
        assert_eq!(first_calls[0].kind, V2RealtimeSignalKind::Offer);
        assert_eq!(first_calls[0].realtime_id, realtime_id);
        assert_eq!(first_calls[0].target_device_id, "peer-a");
        // 全新 PeerConnection 的计数从该会话自己的起点重启（create_offer → revision 1）。
        assert_eq!(first_calls[0].revision, FRESH_OFFER_REVISION);
        let driver1 = state.realtime.lock().await.sessions[realtime_id]
            .driver
            .clone()
            .expect("first driver");

        // transport 丢失：ConnectionSession 销毁 → RealtimeSession Closed（§22）。
        state.cancel_session_tasks("peer-a", s1).await;
        assert!(
            !state
                .realtime
                .lock()
                .await
                .sessions
                .contains_key(realtime_id),
            "transport loss must tear down the realtime session"
        );
        let mut closed_seen = false;
        while let Ok(event) = event_rx.try_recv() {
            if let Some(network_event::Payload::RealtimeState(state_event)) = event.payload {
                if state_event.realtime_id == realtime_id
                    && state_event.state == RealtimeSessionState::Closed as i32
                {
                    closed_seen = true;
                }
            }
        }
        assert!(
            closed_seen,
            "transport loss must emit RealtimeSessionState::Closed"
        );

        // 新 ConnectionSession（用户重新 Resolve → Connection，§22）。
        let _ = state.sessions.close("peer-a").await;
        let s2 = match state.sessions.begin_connect("peer-a").await {
            ConnectDecision::Started(session_id) => session_id,
            decision => panic!("unexpected Session decision: {decision:?}"),
        };
        assert_ne!(s1, s2);

        // 重新请求：新 PeerConnection + 信令经新鲜连接重发。
        start_session(
            state.clone(),
            StartRealtimeSessionCommand {
                realtime_id: realtime_id.into(),
                peer_id: "peer-a".into(),
            },
        )
        .await
        .expect("re-established realtime session");
        let driver2 = state.realtime.lock().await.sessions[realtime_id]
            .driver
            .clone()
            .expect("second driver");
        assert!(
            !Arc::ptr_eq(&driver1, &driver2),
            "new PeerConnection must not reuse the old object"
        );

        let all_calls = control.signal_calls();
        assert_eq!(
            all_calls.len(),
            2,
            "re-establishment resends the offer over the fresh connection"
        );
        assert_eq!(all_calls[1].kind, V2RealtimeSignalKind::Offer);
        assert_eq!(
            all_calls[1].revision, FRESH_OFFER_REVISION,
            "new session restarts its counters"
        );
        assert_ne!(
            all_calls[0].payload, all_calls[1].payload,
            "fresh offer carries new DTLS/ICE state"
        );
    }

    #[tokio::test]
    async fn signaling_lost_mid_negotiation_closes_cleanly_and_re_request_succeeds() {
        let (state, _event_rx) = realtime_test_state().await;
        let control = RecordingControl::new();
        control.fail_signals.store(true, Ordering::Release);
        *state.relay_control.write().await = Some(control.clone());
        register_realtime_peer(&state, "peer-a").await;
        let realtime_id = "00112233445566778899aabbccddeeff";

        // 信令在协商中途丢失（控制面发送失败）→ start_session 干净失败并清理会话。
        let error = start_session(
            state.clone(),
            StartRealtimeSessionCommand {
                realtime_id: realtime_id.into(),
                peer_id: "peer-a".into(),
            },
        )
        .await
        .expect_err("signaling loss must fail start_session");
        assert_eq!(error.code, NetworkErrorCode::RelayError as i32);
        assert!(
            !state
                .realtime
                .lock()
                .await
                .sessions
                .contains_key(realtime_id),
            "failed session must be torn down"
        );

        // 信令路径恢复后重新请求 → 成功，Offer 经 v2 控制面发出。
        control.fail_signals.store(false, Ordering::Release);
        start_session(
            state.clone(),
            StartRealtimeSessionCommand {
                realtime_id: realtime_id.into(),
                peer_id: "peer-a".into(),
            },
        )
        .await
        .expect("re-request after signaling recovery");
        let calls = control.signal_calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].kind, V2RealtimeSignalKind::Offer);
        assert!(state
            .realtime
            .lock()
            .await
            .sessions
            .contains_key(realtime_id));
    }
}
