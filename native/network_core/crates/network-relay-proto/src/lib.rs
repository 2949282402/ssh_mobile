//! Relay control / data plane v2 wire codec.
//!
//! This crate implements the frozen relay.v2 wire contract
//! (`protocol/proto/relay/v2/relay_v2.proto`). Message types are generated at
//! build time by prost-build (vendored protoc) and re-exported from the
//! [`relay_v2`] module.
//!
//! Framing (both routes):
//!
//! ```text
//! WS Binary payload == [4-byte big-endian length][protobuf RelayFrame]
//! or                == [4-byte big-endian length][protobuf RelayDataFrame]
//! ```
//!
//! Exactly one message per WS frame; `length` MUST equal `frame.len() - 4`.
//! [`decode_control`] enforces the prefix/length invariant, the version field
//! (must be 2) and the max control frame size before returning a [`RelayFrame`].
//! [`decode_data`] does the same for the reservation-scoped data plane.

use std::fmt;

use prost::Message;

pub mod relay_v2 {
    include!(concat!(env!("OUT_DIR"), "/relay.v2.rs"));
}

pub use relay_v2::*;

// ---------------------------------------------------------------------------
// Centralized constants — MUST mirror the .proto header comment and
// protocol/relay_v2_testdata/manifest.json ("constants").
// ---------------------------------------------------------------------------

/// The relay.v2 wire version carried in every frame's `version` field.
pub const RELAY_V2_VERSION: u32 = 2;

/// Number of bytes in the big-endian length prefix that precedes the protobuf
/// body of every frame.
pub const FRAME_LENGTH_PREFIX_BYTES: usize = 4;

/// Maximum accepted control-plane frame size: `4 + 512 * 1024` bytes.
pub const MAX_RELAY_FRAME_BYTES: usize = 4 + 512 * 1024;

/// Maximum accepted relay-data frame size: `4 + 512 * 1024` bytes.
pub const MAX_RELAY_DATA_FRAME_BYTES: usize = 4 + 512 * 1024;

/// Maximum `device_id` byte length.
pub const MAX_DEVICE_ID_BYTES: usize = 128;

/// Maximum `attempt_id` byte length.
pub const MAX_ATTEMPT_ID_BYTES: usize = 128;

/// Maximum `realtime_id` byte length.
pub const MAX_REALTIME_ID_BYTES: usize = 128;

/// Maximum `RealtimeSignal.payload` byte length.
pub const MAX_REALTIME_SIGNAL_PAYLOAD_BYTES: usize = 256 * 1024;

/// Maximum number of discovery candidates in a snapshot.
pub const MAX_DISCOVERY_CANDIDATES: usize = 64;

/// Maximum byte length of a single opaque discovery candidate blob.
pub const MAX_DISCOVERY_CANDIDATE_BYTES: usize = 4096;

/// Maximum number of transport capabilities in a snapshot.
pub const MAX_DISCOVERY_CAPABILITIES: usize = 64;

/// Reservation id is 16 random bytes, hex-encoded to 32 chars on the wire.
pub const RESERVATION_ID_BYTES: usize = 16;

/// Hex character length of a wire reservation id.
pub const RESERVATION_ID_HEX_CHARS: usize = 32;

/// Local relay connect credential length in bytes.
pub const RESERVATION_TOKEN_BYTES: usize = 32;

/// Server heartbeat interval in seconds (server-confirmed in `Ready`).
pub const HEARTBEAT_INTERVAL_S: u32 = 20;

/// Presence lease TTL in seconds (server-confirmed in `Ready`).
pub const PRESENCE_TTL_S: u32 = 60;

/// Missed heartbeats before the server closes the control connection
/// (`60s TTL / 20s interval`).
pub const SERVER_HEARTBEAT_MISSES_BEFORE_CLOSE: u32 = 2;

/// Default reservation lifetime in seconds; the server clamps to [15, 120].
pub const RESERVATION_LIFETIME_S_DEFAULT: u32 = 60;

/// Grace period in seconds after `expires_at_ms` before the relay closes a
/// reservation data connection.
pub const RESERVATION_EXPIRY_GRACE_S: u32 = 5;

/// Retry hint for a `RESOLVE_STATUS_NOT_READY` resolution, in milliseconds.
pub const RESOLVE_RETRY_HINT_NOT_READY_MS: u32 = 2000;

/// Retry hint for a `RESOLVE_STATUS_UNKNOWN` resolution, in milliseconds.
pub const RESOLVE_RETRY_HINT_UNKNOWN_MS: u32 = 5000;

/// Fixed direct-connect window in milliseconds (not carried on the wire).
pub const DIRECT_CONNECT_WINDOW_MS: u32 = 4000;

// ---------------------------------------------------------------------------
// Frame errors
// ---------------------------------------------------------------------------

/// Framing / validation error raised while decoding a control or data frame.
///
/// Length/size/version violations are HARD errors per the contract. Unknown
/// oneof (or field) tags are skipped by proto3 decoding and do not produce an
/// error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameError {
    /// Fewer than [`FRAME_LENGTH_PREFIX_BYTES`] bytes available.
    TooShort,
    /// The 4-byte big-endian length prefix disagrees with the actual payload
    /// length (`frame.len() - 4`).
    LengthMismatch {
        /// Value carried in the 4-byte prefix.
        prefix: u32,
        /// Actual protobuf body length.
        actual: usize,
    },
    /// Frame exceeds the route's maximum size.
    TooLarge {
        /// Route maximum (including the 4-byte prefix).
        max: usize,
        /// Actual frame length.
        actual: usize,
    },
    /// `version` field is not [`RELAY_V2_VERSION`].
    InvalidVersion {
        /// Version read from the frame.
        version: u32,
        /// The only accepted version.
        expected: u32,
    },
    /// Protobuf body failed to decode.
    Decode(String),
}

impl fmt::Display for FrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FrameError::TooShort => write!(
                f,
                "frame too short: fewer than {FRAME_LENGTH_PREFIX_BYTES} bytes for the length prefix"
            ),
            FrameError::LengthMismatch { prefix, actual } => write!(
                f,
                "length prefix {prefix} does not match payload length {actual}"
            ),
            FrameError::TooLarge { max, actual } => {
                write!(f, "frame exceeds max {max} bytes (got {actual})")
            }
            FrameError::InvalidVersion { version, expected } => write!(
                f,
                "invalid frame version {version}, expected {expected}"
            ),
            FrameError::Decode(err) => write!(f, "protobuf decode failed: {err}"),
        }
    }
}

impl std::error::Error for FrameError {}

// ---------------------------------------------------------------------------
// Framing helpers
// ---------------------------------------------------------------------------

/// Encode a protobuf message as a full wire frame:
/// `[4-byte big-endian length][protobuf body]`.
pub fn encode_frame(msg: &impl Message) -> Vec<u8> {
    let body = msg.encode_to_vec();
    let mut out = Vec::with_capacity(FRAME_LENGTH_PREFIX_BYTES + body.len());
    out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    out.extend_from_slice(&body);
    out
}

/// Validate the framing invariants and return the protobuf body (the bytes
/// after the 4-byte length prefix).
fn strip_frame(frame: &[u8], max: usize) -> Result<&[u8], FrameError> {
    if frame.len() < FRAME_LENGTH_PREFIX_BYTES {
        return Err(FrameError::TooShort);
    }
    if frame.len() > max {
        return Err(FrameError::TooLarge {
            max,
            actual: frame.len(),
        });
    }
    let mut prefix_bytes = [0u8; FRAME_LENGTH_PREFIX_BYTES];
    prefix_bytes.copy_from_slice(&frame[..FRAME_LENGTH_PREFIX_BYTES]);
    let prefix = u32::from_be_bytes(prefix_bytes);
    let actual = frame.len() - FRAME_LENGTH_PREFIX_BYTES;
    if prefix as usize != actual {
        return Err(FrameError::LengthMismatch { prefix, actual });
    }
    Ok(&frame[FRAME_LENGTH_PREFIX_BYTES..])
}

/// Decode a control-plane frame (route: `GET /v2/control`).
///
/// Applies, in order: length-prefix presence, max frame size, prefix/payload
/// length equality, protobuf decode, and the version check. Unknown fields
/// (including unknown oneof tags) are skipped by proto3 and do not error.
pub fn decode_control(frame: &[u8]) -> Result<RelayFrame, FrameError> {
    let body = strip_frame(frame, MAX_RELAY_FRAME_BYTES)?;
    let decoded = RelayFrame::decode(body).map_err(|e| FrameError::Decode(e.to_string()))?;
    if decoded.version != RELAY_V2_VERSION {
        return Err(FrameError::InvalidVersion {
            version: decoded.version,
            expected: RELAY_V2_VERSION,
        });
    }
    Ok(decoded)
}

/// Decode a relay-data frame (route: `GET /v2/relay/{reservation_id}`).
///
/// Same framing invariants as [`decode_control`], bounded by
/// [`MAX_RELAY_DATA_FRAME_BYTES`].
pub fn decode_data(frame: &[u8]) -> Result<RelayDataFrame, FrameError> {
    let body = strip_frame(frame, MAX_RELAY_DATA_FRAME_BYTES)?;
    let decoded = RelayDataFrame::decode(body).map_err(|e| FrameError::Decode(e.to_string()))?;
    if decoded.version != RELAY_V2_VERSION {
        return Err(FrameError::InvalidVersion {
            version: decoded.version,
            expected: RELAY_V2_VERSION,
        });
    }
    Ok(decoded)
}

#[cfg(test)]
#[path = "tests/mod.rs"]
mod tests;
