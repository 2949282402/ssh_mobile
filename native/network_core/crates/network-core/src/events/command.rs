//! Command terminal-result event construction.

use super::{protocol_error, unix_timestamp_ms};
use crate::runtime::EventSender;
use crate::runtime_event_lanes::EventSendError;
use network_protocol::{
    network_event, CommandResult, CommandResultState, NetworkError as ProtocolError,
    NetworkErrorCode, NetworkEvent, NETWORK_PROTOCOL_VERSION,
};

/// 发布一个由 public command tracker 消费的终态结果。
///
/// `NetworkRuntime::send_command` is the synchronous Accepted boundary.  The
/// worker must publish exactly one `CommandResult` V2 event after the async
/// operation settles; the legacy `accepted` boolean event is intentionally not
/// emitted here because the native FFI treats either result variant as the
/// terminal correlation point.
pub(crate) async fn emit_command_result(
    event_tx: &EventSender,
    command_id: String,
    command_peer_id: Option<String>,
    result: Result<(), ProtocolError>,
) -> Result<(), EventSendError> {
    let (state, error, error_peer_id) = match result {
        Ok(()) => (CommandResultState::Succeeded, None, None),
        Err(error) => {
            let state = match NetworkErrorCode::try_from(error.code).ok() {
                Some(NetworkErrorCode::Cancelled | NetworkErrorCode::StaleOperation) => {
                    CommandResultState::Cancelled
                }
                _ => CommandResultState::Failed,
            };
            let peer_id = (!error.peer_id.is_empty()).then(|| error.peer_id.clone());
            (state, Some(error), peer_id)
        }
    };
    let peer_id = error_peer_id.or(command_peer_id).unwrap_or_default();
    let event_id = format!("{command_id}/result");
    let event = NetworkEvent {
        event_id: event_id.clone(),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::CommandResultV2(CommandResult {
            command_id: command_id.clone(),
            peer_id: peer_id.clone(),
            state: state as i32,
            error,
        })),
    };
    match event_tx.send_result(event).await {
        Ok(()) => Ok(()),
        Err(EventSendError::TooLarge) => {
            event_tx
                .send_result(NetworkEvent {
                    event_id,
                    timestamp_ms: unix_timestamp_ms(),
                    protocol_version: NETWORK_PROTOCOL_VERSION,
                    payload: Some(network_event::Payload::CommandResultV2(CommandResult {
                        command_id,
                        peer_id,
                        state: CommandResultState::Failed as i32,
                        error: Some(protocol_error(
                            NetworkErrorCode::IoError,
                            "command result exceeded native event limit",
                        )),
                    })),
                })
                .await
        }
        Err(error) => Err(error),
    }
}
