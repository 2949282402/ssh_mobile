// PathHandshakeV2 transcript and envelope-admission boundary.
//
// This is the versioned application metadata layer carried by the existing
// authenticated Noise exchange (and by `DATA_ENV_CRYPTO` on RelayData). It
// is not a second key exchange, a second Relay security envelope, or a
// replacement for ADR-028's v3 RootSeed/KeyEpoch/structured nonce flow.

use ed25519_dalek::VerifyingKey;
use network_identity::DeviceIdentity;
use sha2::{Digest, Sha256};
use std::sync::Arc;

pub(crate) const PATH_HANDSHAKE_VERSION: u32 = 2;
pub(crate) const NETWORK_DATA_PROTOCOL_VERSION: u32 = 2;

/// Existing RelayData envelope type. PathHandshakeV2 is transported through
/// this envelope; no second Relay authentication envelope is permitted.
pub(crate) const DATA_ENV_CRYPTO: u8 = 0x01;
pub(crate) const DATA_ENV_FILE_OFFER: u8 = 0x02;
pub(crate) const DATA_ENV_FILE_ACCEPT: u8 = 0x03;
pub(crate) const DATA_ENV_FILE_COMPLETE: u8 = 0x04;
pub(crate) const DATA_ENV_FILE_COMPLETE_ACK: u8 = 0x05;
pub(crate) const DATA_ENV_FILE_CANCEL: u8 = 0x06;
pub(crate) const DATA_ENV_FILE_CHUNK: u8 = 0x07;
pub(crate) const DATA_ENV_CHANNEL: u8 = 0x08;
pub(crate) const DATA_ENV_CHANNEL_ACK: u8 = 0x09;
pub(crate) const DATA_ENV_STREAM: u8 = 0x0A;

const FRAME_MAGIC: &[u8; 4] = b"SMPH";
const TRANSCRIPT_DOMAIN: &[u8] = b"ssh-mobile/path-handshake/transcript/v2";
const HELLO_DOMAIN: &[u8] = b"ssh-mobile/path-handshake/hello/v2";
const MAX_FRAME_BYTES: usize = 64 * 1024;
const MAX_PEER_ID_BYTES: usize = 128;
const MAX_PATH_BINDING_BYTES: usize = 256;
const MAX_CONNECTION_PROFILE_BYTES: usize = 256;
const IDENTITY_KEY_BYTES: usize = 32;
const SIGNATURE_BYTES: usize = 64;

pub(crate) fn is_encoded_frame(encoded: &[u8]) -> bool {
    encoded.starts_with(FRAME_MAGIC)
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(u8)]
pub(crate) enum E2eePolicy {
    /// The default and the only policy accepted by Relay paths.
    #[default]
    Required = 0,
    /// Explicit identity-only mode. It is valid only for Direct paths.
    Disabled = 1,
}

impl E2eePolicy {
    fn from_code(code: u8) -> Result<Self, PathHandshakeError> {
        match code {
            0 => Ok(Self::Required),
            1 => Ok(Self::Disabled),
            _ => Err(PathHandshakeError::InvalidFrame),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub(crate) enum PathKind {
    Direct = 1,
    Relay = 2,
}

impl PathKind {
    fn from_code(code: u8) -> Result<Self, PathHandshakeError> {
        match code {
            1 => Ok(Self::Direct),
            2 => Ok(Self::Relay),
            _ => Err(PathHandshakeError::InvalidFrame),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub(crate) enum HandshakeRole {
    Initiator = 1,
    Responder = 2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
enum FrameKind {
    Hello = 1,
    Response = 2,
    Final = 3,
}

impl FrameKind {
    fn from_code(code: u8) -> Result<Self, PathHandshakeError> {
        match code {
            1 => Ok(Self::Hello),
            2 => Ok(Self::Response),
            3 => Ok(Self::Final),
            _ => Err(PathHandshakeError::InvalidFrame),
        }
    }
}

/// Stable errors at the path/security boundary. Callers can use these
/// variants for public error mapping without exposing transport details.
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub(crate) enum PathHandshakeError {
    #[error("PathHandshakeV2 frame is invalid")]
    InvalidFrame,
    #[error("PathHandshakeV2 peer protocol mismatch")]
    PeerProtocolMismatch,
    #[error("PathHandshakeV2 downgrade rejected")]
    DowngradeRejected,
    #[error("PathHandshakeV2 identity is mandatory")]
    IdentityRequired,
    #[error("PathHandshakeV2 peer identity mismatch")]
    PeerIdentityMismatch,
    #[error("PathHandshakeV2 identity proof failed")]
    IdentityProofFailed,
    #[error("PathHandshakeV2 security policy mismatch")]
    SecurityPolicyMismatch,
    #[error("Relay paths require E2EE")]
    RelayRequiresE2ee,
    #[error("PathHandshakeV2 path binding mismatch")]
    PathBindingMismatch,
    #[error("PathHandshakeV2 connection profile mismatch")]
    ConnectionProfileMismatch,
    #[error("PathHandshakeV2 frame is unexpected")]
    UnexpectedFrame,
    #[error("PathHandshakeV2 path is not ready for business envelopes")]
    PathNotReady,
    #[error("RelayData PairReady is required before PathHandshakeV2")]
    PairNotReady,
    #[error("PathHandshakeV2 handshake frame arrived after Ready")]
    UnexpectedHandshakeFrame,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PathHandshakeConfig {
    pub(crate) local_peer_id: String,
    pub(crate) expected_peer_id: String,
    pub(crate) expected_peer_identity_key: [u8; IDENTITY_KEY_BYTES],
    pub(crate) e2ee_policy: E2eePolicy,
    pub(crate) path_kind: PathKind,
    pub(crate) path_binding: Vec<u8>,
    pub(crate) connection_profile: Vec<u8>,
}

impl PathHandshakeConfig {
    pub(crate) fn new(
        local_peer_id: impl Into<String>,
        expected_peer_id: impl Into<String>,
        expected_peer_identity_key: [u8; IDENTITY_KEY_BYTES],
        e2ee_policy: E2eePolicy,
        path_kind: PathKind,
        path_binding: Vec<u8>,
        connection_profile: Vec<u8>,
    ) -> Result<Self, PathHandshakeError> {
        let config = Self {
            local_peer_id: local_peer_id.into(),
            expected_peer_id: expected_peer_id.into(),
            expected_peer_identity_key,
            e2ee_policy,
            path_kind,
            path_binding,
            connection_profile,
        };
        config.validate_common()?;
        Ok(config)
    }

    fn validate_common(&self) -> Result<(), PathHandshakeError> {
        validate_peer_id(&self.local_peer_id)?;
        validate_peer_id(&self.expected_peer_id)?;
        validate_identity_key(&self.expected_peer_identity_key)?;
        validate_bytes(&self.path_binding, MAX_PATH_BINDING_BYTES)?;
        validate_bytes(&self.connection_profile, MAX_CONNECTION_PROFILE_BYTES)?;
        if self.path_kind == PathKind::Relay && self.e2ee_policy == E2eePolicy::Disabled {
            return Err(PathHandshakeError::RelayRequiresE2ee);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PathSecurity {
    E2ee,
    IdentityOnly,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PathHandshakePhase {
    AwaitingHello,
    AwaitingResponse,
    AwaitingFinal,
    Ready,
    Rejected,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PathHandshakeReady {
    pub(crate) peer_id: String,
    pub(crate) path_kind: PathKind,
    pub(crate) security: PathSecurity,
    pub(crate) transcript_hash: [u8; 32],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum EnvelopeKind {
    /// `DATA_ENV_CRYPTO`, the only RelayData envelope admitted before Ready.
    CryptoHandshake,
    ChannelMessage,
    ChannelAck,
    Stream,
    FileOffer,
    FileAccept,
    FileComplete,
    FileCompleteAck,
    FileCancel,
    FileChunk,
}

impl EnvelopeKind {
    pub(crate) fn from_relay_type(value: u8) -> Result<Self, PathHandshakeError> {
        match value {
            DATA_ENV_CRYPTO => Ok(Self::CryptoHandshake),
            DATA_ENV_FILE_OFFER => Ok(Self::FileOffer),
            DATA_ENV_FILE_ACCEPT => Ok(Self::FileAccept),
            DATA_ENV_FILE_COMPLETE => Ok(Self::FileComplete),
            DATA_ENV_FILE_COMPLETE_ACK => Ok(Self::FileCompleteAck),
            DATA_ENV_FILE_CANCEL => Ok(Self::FileCancel),
            DATA_ENV_FILE_CHUNK => Ok(Self::FileChunk),
            DATA_ENV_CHANNEL => Ok(Self::ChannelMessage),
            DATA_ENV_CHANNEL_ACK => Ok(Self::ChannelAck),
            DATA_ENV_STREAM => Ok(Self::Stream),
            _ => Err(PathHandshakeError::InvalidFrame),
        }
    }

    fn is_business(self) -> bool {
        !matches!(self, Self::CryptoHandshake)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PeerIdentity {
    peer_id: String,
    identity_public_key: [u8; IDENTITY_KEY_BYTES],
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct FramePeer {
    identity: PeerIdentity,
    e2ee_policy: E2eePolicy,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Frame {
    kind: FrameKind,
    role: HandshakeRole,
    peer: FramePeer,
    remote: Option<FramePeer>,
    path_kind: PathKind,
    path_binding: Vec<u8>,
    connection_profile: Vec<u8>,
    signature: [u8; SIGNATURE_BYTES],
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Transcript {
    initiator: FramePeer,
    responder: FramePeer,
    path_kind: PathKind,
    path_binding: Vec<u8>,
    connection_profile: Vec<u8>,
    security: PathSecurity,
    hash: [u8; 32],
}

/// A stateful PathHandshakeV2 metadata exchange. The surrounding transport
/// must already be authenticated; Relay instances must also call
/// [`Self::mark_pair_ready`] after the existing RelayData PairReady event.
pub(crate) struct PathHandshake {
    identity: Arc<DeviceIdentity>,
    role: HandshakeRole,
    config: PathHandshakeConfig,
    phase: PathHandshakePhase,
    transport_ready: bool,
    transcript: Option<Transcript>,
}

impl PathHandshake {
    pub(crate) fn new(
        role: HandshakeRole,
        identity: Arc<DeviceIdentity>,
        config: PathHandshakeConfig,
    ) -> Result<Self, PathHandshakeError> {
        config.validate_common()?;
        if identity.device_id != config.local_peer_id {
            return Err(PathHandshakeError::IdentityRequired);
        }
        validate_identity_key(&identity.public_identity_key().to_bytes())?;
        let phase = match role {
            HandshakeRole::Initiator => PathHandshakePhase::AwaitingResponse,
            HandshakeRole::Responder => PathHandshakePhase::AwaitingHello,
        };
        Ok(Self {
            transport_ready: config.path_kind == PathKind::Direct,
            identity,
            role,
            config,
            phase,
            transcript: None,
        })
    }

    pub(crate) fn phase(&self) -> PathHandshakePhase {
        self.phase
    }

    pub(crate) fn is_ready(&self) -> bool {
        self.phase == PathHandshakePhase::Ready
    }

    pub(crate) fn ready(&self) -> Option<PathHandshakeReady> {
        let transcript = self.transcript.as_ref()?;
        self.is_ready().then(|| PathHandshakeReady {
            peer_id: self.config.expected_peer_id.clone(),
            path_kind: self.config.path_kind,
            security: transcript.security,
            transcript_hash: transcript.hash,
        })
    }

    /// PairReady is an existing RelayData lifecycle event, not a new crypto
    /// frame. It opens the DATA_ENV_CRYPTO admission window only.
    pub(crate) fn mark_pair_ready(&mut self) -> Result<(), PathHandshakeError> {
        if self.config.path_kind != PathKind::Relay {
            return Err(PathHandshakeError::UnexpectedFrame);
        }
        if self.phase == PathHandshakePhase::Rejected {
            return Err(PathHandshakeError::PathNotReady);
        }
        self.transport_ready = true;
        Ok(())
    }

    pub(crate) fn start(&mut self) -> Result<Vec<u8>, PathHandshakeError> {
        if !self.transport_ready {
            return Err(PathHandshakeError::PairNotReady);
        }
        if self.role != HandshakeRole::Initiator
            || self.phase != PathHandshakePhase::AwaitingResponse
        {
            return Err(PathHandshakeError::UnexpectedFrame);
        }
        encode_frame(&self.hello_frame()?)
    }

    /// Accept one metadata frame and return the next metadata frame, if any.
    /// The final initiator frame marks the initiator Ready; the responder marks
    /// Ready only after verifying that final signature.
    pub(crate) fn accept(&mut self, encoded: &[u8]) -> Result<Option<Vec<u8>>, PathHandshakeError> {
        if !self.transport_ready {
            return Err(PathHandshakeError::PairNotReady);
        }
        if self.phase == PathHandshakePhase::Rejected {
            return Err(PathHandshakeError::PathNotReady);
        }
        let frame = match decode_frame(encoded) {
            Ok(frame) => frame,
            Err(error) => {
                self.phase = PathHandshakePhase::Rejected;
                return Err(error);
            }
        };
        let result = match (self.role, self.phase, frame.kind) {
            (HandshakeRole::Responder, PathHandshakePhase::AwaitingHello, FrameKind::Hello) => {
                self.accept_hello(frame)
            }
            (
                HandshakeRole::Initiator,
                PathHandshakePhase::AwaitingResponse,
                FrameKind::Response,
            ) => self.accept_response(frame),
            (HandshakeRole::Responder, PathHandshakePhase::AwaitingFinal, FrameKind::Final) => {
                self.accept_final(frame)
            }
            (_, PathHandshakePhase::Ready, _) => Err(PathHandshakeError::UnexpectedFrame),
            _ => Err(PathHandshakeError::UnexpectedFrame),
        };
        if result.is_err() {
            self.phase = PathHandshakePhase::Rejected;
        }
        result
    }

    pub(crate) fn admit_envelope(&self, envelope: EnvelopeKind) -> Result<(), PathHandshakeError> {
        if !self.transport_ready {
            return Err(PathHandshakeError::PairNotReady);
        }
        if envelope == EnvelopeKind::CryptoHandshake {
            return match self.phase {
                PathHandshakePhase::AwaitingHello
                | PathHandshakePhase::AwaitingResponse
                | PathHandshakePhase::AwaitingFinal => Ok(()),
                PathHandshakePhase::Ready => Err(PathHandshakeError::UnexpectedHandshakeFrame),
                PathHandshakePhase::Rejected => Err(PathHandshakeError::PathNotReady),
            };
        }
        if envelope.is_business() && self.phase != PathHandshakePhase::Ready {
            return Err(PathHandshakeError::PathNotReady);
        }
        Ok(())
    }

    fn hello_frame(&self) -> Result<Frame, PathHandshakeError> {
        sign_hello(
            Frame {
                kind: FrameKind::Hello,
                role: HandshakeRole::Initiator,
                peer: self.local_frame_peer(),
                remote: None,
                path_kind: self.config.path_kind,
                path_binding: self.config.path_binding.clone(),
                connection_profile: self.config.connection_profile.clone(),
                signature: [0u8; SIGNATURE_BYTES],
            },
            &self.identity,
        )
    }

    fn accept_hello(&mut self, frame: Frame) -> Result<Option<Vec<u8>>, PathHandshakeError> {
        if frame.role != HandshakeRole::Initiator || frame.remote.is_some() {
            return Err(PathHandshakeError::UnexpectedFrame);
        }
        self.validate_common_frame(&frame)?;
        verify_hello_signature(&frame)?;
        let transcript = self.make_transcript(&frame.peer, &self.local_frame_peer())?;
        let response = sign_full(
            Frame {
                kind: FrameKind::Response,
                role: HandshakeRole::Responder,
                peer: self.local_frame_peer(),
                remote: Some(frame.peer.clone()),
                path_kind: self.config.path_kind,
                path_binding: self.config.path_binding.clone(),
                connection_profile: self.config.connection_profile.clone(),
                signature: [0u8; SIGNATURE_BYTES],
            },
            &transcript,
            &self.identity,
        )?;
        self.transcript = Some(transcript);
        self.phase = PathHandshakePhase::AwaitingFinal;
        Ok(Some(encode_frame(&response)?))
    }

    fn accept_response(&mut self, frame: Frame) -> Result<Option<Vec<u8>>, PathHandshakeError> {
        if frame.role != HandshakeRole::Responder {
            return Err(PathHandshakeError::UnexpectedFrame);
        }
        let remote = frame
            .remote
            .as_ref()
            .ok_or(PathHandshakeError::IdentityRequired)?;
        self.validate_common_frame(&frame)?;
        if remote.identity.peer_id != self.config.local_peer_id
            || remote.identity.identity_public_key != self.identity.public_identity_key().to_bytes()
            || remote.e2ee_policy != self.config.e2ee_policy
        {
            return Err(PathHandshakeError::PeerIdentityMismatch);
        }
        let transcript = self.make_transcript(&self.local_frame_peer(), &frame.peer)?;
        verify_full_signature(&frame, &transcript)?;
        let final_frame = sign_full(
            Frame {
                kind: FrameKind::Final,
                role: HandshakeRole::Initiator,
                peer: self.local_frame_peer(),
                remote: Some(frame.peer.clone()),
                path_kind: self.config.path_kind,
                path_binding: self.config.path_binding.clone(),
                connection_profile: self.config.connection_profile.clone(),
                signature: [0u8; SIGNATURE_BYTES],
            },
            &transcript,
            &self.identity,
        )?;
        self.transcript = Some(transcript);
        self.phase = PathHandshakePhase::Ready;
        Ok(Some(encode_frame(&final_frame)?))
    }

    fn accept_final(&mut self, frame: Frame) -> Result<Option<Vec<u8>>, PathHandshakeError> {
        if frame.role != HandshakeRole::Initiator {
            return Err(PathHandshakeError::UnexpectedFrame);
        }
        let transcript = self
            .transcript
            .as_ref()
            .ok_or(PathHandshakeError::PathNotReady)?;
        let remote = frame
            .remote
            .as_ref()
            .ok_or(PathHandshakeError::IdentityRequired)?;
        if remote.identity.peer_id != self.config.local_peer_id
            || remote.identity.identity_public_key != self.identity.public_identity_key().to_bytes()
            || frame.peer.e2ee_policy != transcript.initiator.e2ee_policy
            || remote.e2ee_policy != transcript.responder.e2ee_policy
        {
            return Err(PathHandshakeError::PeerIdentityMismatch);
        }
        self.validate_common_frame(&frame)?;
        verify_full_signature(&frame, transcript)?;
        self.phase = PathHandshakePhase::Ready;
        Ok(None)
    }

    fn validate_common_frame(&self, frame: &Frame) -> Result<(), PathHandshakeError> {
        if frame.peer.identity.peer_id != self.config.expected_peer_id
            || frame.peer.identity.identity_public_key != self.config.expected_peer_identity_key
        {
            return Err(PathHandshakeError::PeerIdentityMismatch);
        }
        if frame.path_kind != self.config.path_kind
            || frame.path_binding != self.config.path_binding
        {
            return Err(PathHandshakeError::PathBindingMismatch);
        }
        if frame.connection_profile != self.config.connection_profile {
            return Err(PathHandshakeError::ConnectionProfileMismatch);
        }
        negotiate_security(
            self.config.path_kind,
            self.config.e2ee_policy,
            frame.peer.e2ee_policy,
        )?;
        Ok(())
    }

    fn make_transcript(
        &self,
        initiator: &FramePeer,
        responder: &FramePeer,
    ) -> Result<Transcript, PathHandshakeError> {
        let security = negotiate_security(
            self.config.path_kind,
            initiator.e2ee_policy,
            responder.e2ee_policy,
        )?;
        let mut transcript = Transcript {
            initiator: initiator.clone(),
            responder: responder.clone(),
            path_kind: self.config.path_kind,
            path_binding: self.config.path_binding.clone(),
            connection_profile: self.config.connection_profile.clone(),
            security,
            hash: [0u8; 32],
        };
        transcript.hash = digest_transcript(&transcript);
        Ok(transcript)
    }

    fn local_frame_peer(&self) -> FramePeer {
        FramePeer {
            identity: PeerIdentity {
                peer_id: self.config.local_peer_id.clone(),
                identity_public_key: self.identity.public_identity_key().to_bytes(),
            },
            e2ee_policy: self.config.e2ee_policy,
        }
    }
}

fn negotiate_security(
    path_kind: PathKind,
    local: E2eePolicy,
    remote: E2eePolicy,
) -> Result<PathSecurity, PathHandshakeError> {
    if path_kind == PathKind::Relay
        && (local == E2eePolicy::Disabled || remote == E2eePolicy::Disabled)
    {
        return Err(PathHandshakeError::RelayRequiresE2ee);
    }
    if local != remote {
        return Err(PathHandshakeError::SecurityPolicyMismatch);
    }
    Ok(match local {
        E2eePolicy::Required => PathSecurity::E2ee,
        E2eePolicy::Disabled => PathSecurity::IdentityOnly,
    })
}

fn sign_hello(mut frame: Frame, identity: &DeviceIdentity) -> Result<Frame, PathHandshakeError> {
    let bytes = hello_signing_bytes(&frame)?;
    let signature = identity.sign_proof(&bytes);
    if signature.len() != SIGNATURE_BYTES {
        return Err(PathHandshakeError::IdentityProofFailed);
    }
    frame.signature.copy_from_slice(&signature);
    Ok(frame)
}

fn sign_full(
    mut frame: Frame,
    transcript: &Transcript,
    identity: &DeviceIdentity,
) -> Result<Frame, PathHandshakeError> {
    let bytes = full_transcript_bytes(frame.kind, transcript);
    let signature = identity.sign_proof(&bytes);
    if signature.len() != SIGNATURE_BYTES {
        return Err(PathHandshakeError::IdentityProofFailed);
    }
    frame.signature.copy_from_slice(&signature);
    Ok(frame)
}

fn verify_hello_signature(frame: &Frame) -> Result<(), PathHandshakeError> {
    let bytes = hello_signing_bytes(frame)?;
    let key = VerifyingKey::from_bytes(&frame.peer.identity.identity_public_key)
        .map_err(|_| PathHandshakeError::IdentityProofFailed)?;
    if DeviceIdentity::verify_peer_proof(&key, &bytes, &frame.signature) {
        Ok(())
    } else {
        Err(PathHandshakeError::IdentityProofFailed)
    }
}

fn verify_full_signature(frame: &Frame, transcript: &Transcript) -> Result<(), PathHandshakeError> {
    let bytes = full_transcript_bytes(frame.kind, transcript);
    let key = VerifyingKey::from_bytes(&frame.peer.identity.identity_public_key)
        .map_err(|_| PathHandshakeError::IdentityProofFailed)?;
    if DeviceIdentity::verify_peer_proof(&key, &bytes, &frame.signature) {
        Ok(())
    } else {
        Err(PathHandshakeError::IdentityProofFailed)
    }
}

fn digest_transcript(transcript: &Transcript) -> [u8; 32] {
    Sha256::digest(full_transcript_bytes(FrameKind::Final, transcript)).into()
}

fn hello_signing_bytes(frame: &Frame) -> Result<Vec<u8>, PathHandshakeError> {
    if frame.kind != FrameKind::Hello || frame.remote.is_some() {
        return Err(PathHandshakeError::InvalidFrame);
    }
    let mut output = Vec::with_capacity(512);
    output.extend_from_slice(HELLO_DOMAIN);
    output.extend_from_slice(&PATH_HANDSHAKE_VERSION.to_be_bytes());
    output.extend_from_slice(&NETWORK_DATA_PROTOCOL_VERSION.to_be_bytes());
    output.push(frame.kind as u8);
    output.push(frame.role as u8);
    output.push(frame.peer.e2ee_policy as u8);
    output.push(frame.path_kind as u8);
    append_string(&mut output, &frame.peer.identity.peer_id, MAX_PEER_ID_BYTES)?;
    output.extend_from_slice(&frame.peer.identity.identity_public_key);
    append_bytes(&mut output, &frame.path_binding, MAX_PATH_BINDING_BYTES)?;
    append_bytes(
        &mut output,
        &frame.connection_profile,
        MAX_CONNECTION_PROFILE_BYTES,
    )?;
    Ok(output)
}

fn full_transcript_bytes(kind: FrameKind, transcript: &Transcript) -> Vec<u8> {
    let mut output = Vec::with_capacity(512);
    output.extend_from_slice(TRANSCRIPT_DOMAIN);
    output.extend_from_slice(&PATH_HANDSHAKE_VERSION.to_be_bytes());
    output.extend_from_slice(&NETWORK_DATA_PROTOCOL_VERSION.to_be_bytes());
    output.push(kind as u8);
    output.push(transcript.path_kind as u8);
    output.push(transcript.initiator.e2ee_policy as u8);
    output.push(transcript.responder.e2ee_policy as u8);
    append_string_unchecked(&mut output, &transcript.initiator.identity.peer_id);
    output.extend_from_slice(&transcript.initiator.identity.identity_public_key);
    append_string_unchecked(&mut output, &transcript.responder.identity.peer_id);
    output.extend_from_slice(&transcript.responder.identity.identity_public_key);
    append_bytes_unchecked(&mut output, &transcript.path_binding);
    append_bytes_unchecked(&mut output, &transcript.connection_profile);
    output
}

fn encode_frame(frame: &Frame) -> Result<Vec<u8>, PathHandshakeError> {
    validate_peer_id(&frame.peer.identity.peer_id)?;
    validate_identity_key(&frame.peer.identity.identity_public_key)?;
    validate_bytes(&frame.path_binding, MAX_PATH_BINDING_BYTES)?;
    validate_bytes(&frame.connection_profile, MAX_CONNECTION_PROFILE_BYTES)?;
    if matches!(frame.kind, FrameKind::Hello) != frame.remote.is_none() {
        return Err(PathHandshakeError::InvalidFrame);
    }
    let mut output = Vec::with_capacity(512);
    output.extend_from_slice(FRAME_MAGIC);
    output.extend_from_slice(&PATH_HANDSHAKE_VERSION.to_be_bytes());
    output.push(frame.kind as u8);
    output.extend_from_slice(&NETWORK_DATA_PROTOCOL_VERSION.to_be_bytes());
    output.push(frame.role as u8);
    output.push(frame.peer.e2ee_policy as u8);
    output.push(frame.path_kind as u8);
    append_string(&mut output, &frame.peer.identity.peer_id, MAX_PEER_ID_BYTES)?;
    output.extend_from_slice(&frame.peer.identity.identity_public_key);
    match &frame.remote {
        Some(remote) => {
            output.push(1);
            append_string(&mut output, &remote.identity.peer_id, MAX_PEER_ID_BYTES)?;
            output.extend_from_slice(&remote.identity.identity_public_key);
            output.push(remote.e2ee_policy as u8);
        }
        None => output.push(0),
    }
    append_bytes(&mut output, &frame.path_binding, MAX_PATH_BINDING_BYTES)?;
    append_bytes(
        &mut output,
        &frame.connection_profile,
        MAX_CONNECTION_PROFILE_BYTES,
    )?;
    if frame.signature.len() != SIGNATURE_BYTES {
        return Err(PathHandshakeError::IdentityProofFailed);
    }
    output.extend_from_slice(&frame.signature);
    if output.len() > MAX_FRAME_BYTES {
        return Err(PathHandshakeError::InvalidFrame);
    }
    Ok(output)
}

fn decode_frame(encoded: &[u8]) -> Result<Frame, PathHandshakeError> {
    if encoded.len() > MAX_FRAME_BYTES {
        return Err(PathHandshakeError::InvalidFrame);
    }
    let mut cursor = Cursor::new(encoded);
    if cursor.take(4)? != FRAME_MAGIC {
        return Err(PathHandshakeError::InvalidFrame);
    }
    let version = cursor.take_u32()?;
    if version < PATH_HANDSHAKE_VERSION {
        return Err(PathHandshakeError::DowngradeRejected);
    }
    if version != PATH_HANDSHAKE_VERSION {
        return Err(PathHandshakeError::PeerProtocolMismatch);
    }
    let kind = FrameKind::from_code(cursor.take_byte()?)?;
    let network_version = cursor.take_u32()?;
    if network_version < NETWORK_DATA_PROTOCOL_VERSION {
        return Err(PathHandshakeError::DowngradeRejected);
    }
    if network_version != NETWORK_DATA_PROTOCOL_VERSION {
        return Err(PathHandshakeError::PeerProtocolMismatch);
    }
    let role = match cursor.take_byte()? {
        1 => HandshakeRole::Initiator,
        2 => HandshakeRole::Responder,
        _ => return Err(PathHandshakeError::InvalidFrame),
    };
    let e2ee_policy = E2eePolicy::from_code(cursor.take_byte()?)?;
    let path_kind = PathKind::from_code(cursor.take_byte()?)?;
    let peer_id = cursor.take_string(MAX_PEER_ID_BYTES)?;
    let identity_public_key: [u8; IDENTITY_KEY_BYTES] = cursor
        .take(IDENTITY_KEY_BYTES)?
        .try_into()
        .map_err(|_| PathHandshakeError::InvalidFrame)?;
    validate_identity_key(&identity_public_key)?;
    let remote = match cursor.take_byte()? {
        0 => None,
        1 => {
            let remote_id = cursor.take_string(MAX_PEER_ID_BYTES)?;
            let remote_key: [u8; IDENTITY_KEY_BYTES] = cursor
                .take(IDENTITY_KEY_BYTES)?
                .try_into()
                .map_err(|_| PathHandshakeError::InvalidFrame)?;
            validate_identity_key(&remote_key)?;
            let remote_policy = E2eePolicy::from_code(cursor.take_byte()?)?;
            Some(FramePeer {
                identity: PeerIdentity {
                    peer_id: remote_id,
                    identity_public_key: remote_key,
                },
                e2ee_policy: remote_policy,
            })
        }
        _ => return Err(PathHandshakeError::InvalidFrame),
    };
    let path_binding = cursor.take_bytes(MAX_PATH_BINDING_BYTES)?;
    let connection_profile = cursor.take_bytes(MAX_CONNECTION_PROFILE_BYTES)?;
    let signature: [u8; SIGNATURE_BYTES] = cursor
        .take(SIGNATURE_BYTES)?
        .try_into()
        .map_err(|_| PathHandshakeError::InvalidFrame)?;
    if !cursor.done() {
        return Err(PathHandshakeError::InvalidFrame);
    }
    if matches!(kind, FrameKind::Hello) != remote.is_none() {
        return Err(PathHandshakeError::InvalidFrame);
    }
    validate_bytes(path_binding, MAX_PATH_BINDING_BYTES)?;
    validate_bytes(connection_profile, MAX_CONNECTION_PROFILE_BYTES)?;
    Ok(Frame {
        kind,
        role,
        peer: FramePeer {
            identity: PeerIdentity {
                peer_id,
                identity_public_key,
            },
            e2ee_policy,
        },
        remote,
        path_kind,
        path_binding: path_binding.to_vec(),
        connection_profile: connection_profile.to_vec(),
        signature,
    })
}

fn validate_peer_id(peer_id: &str) -> Result<(), PathHandshakeError> {
    if peer_id.is_empty() || peer_id.len() > MAX_PEER_ID_BYTES {
        return Err(PathHandshakeError::IdentityRequired);
    }
    Ok(())
}

fn validate_identity_key(key: &[u8; IDENTITY_KEY_BYTES]) -> Result<(), PathHandshakeError> {
    if key.iter().all(|byte| *byte == 0) {
        return Err(PathHandshakeError::IdentityRequired);
    }
    Ok(())
}

fn validate_bytes(bytes: &[u8], max: usize) -> Result<(), PathHandshakeError> {
    if bytes.is_empty() || bytes.len() > max {
        return Err(PathHandshakeError::InvalidFrame);
    }
    Ok(())
}

fn append_string(output: &mut Vec<u8>, value: &str, max: usize) -> Result<(), PathHandshakeError> {
    if value.is_empty() || value.len() > max || value.len() > u16::MAX as usize {
        return Err(PathHandshakeError::InvalidFrame);
    }
    append_string_unchecked(output, value);
    Ok(())
}

fn append_string_unchecked(output: &mut Vec<u8>, value: &str) {
    output.extend_from_slice(&(value.len() as u16).to_be_bytes());
    output.extend_from_slice(value.as_bytes());
}

fn append_bytes(output: &mut Vec<u8>, value: &[u8], max: usize) -> Result<(), PathHandshakeError> {
    if value.is_empty() || value.len() > max || value.len() > u16::MAX as usize {
        return Err(PathHandshakeError::InvalidFrame);
    }
    append_bytes_unchecked(output, value);
    Ok(())
}

fn append_bytes_unchecked(output: &mut Vec<u8>, value: &[u8]) {
    output.extend_from_slice(&(value.len() as u16).to_be_bytes());
    output.extend_from_slice(value);
}

struct Cursor<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Cursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8], PathHandshakeError> {
        let end = self
            .offset
            .checked_add(length)
            .ok_or(PathHandshakeError::InvalidFrame)?;
        let value = self
            .bytes
            .get(self.offset..end)
            .ok_or(PathHandshakeError::InvalidFrame)?;
        self.offset = end;
        Ok(value)
    }

    fn take_byte(&mut self) -> Result<u8, PathHandshakeError> {
        Ok(self.take(1)?[0])
    }

    fn take_u32(&mut self) -> Result<u32, PathHandshakeError> {
        Ok(u32::from_be_bytes(
            self.take(4)?
                .try_into()
                .map_err(|_| PathHandshakeError::InvalidFrame)?,
        ))
    }

    fn take_string(&mut self, max: usize) -> Result<String, PathHandshakeError> {
        let length = u16::from_be_bytes(
            self.take(2)?
                .try_into()
                .map_err(|_| PathHandshakeError::InvalidFrame)?,
        ) as usize;
        if length == 0 || length > max {
            return Err(PathHandshakeError::IdentityRequired);
        }
        String::from_utf8(self.take(length)?.to_vec()).map_err(|_| PathHandshakeError::InvalidFrame)
    }

    fn take_bytes(&mut self, max: usize) -> Result<&'a [u8], PathHandshakeError> {
        let length = u16::from_be_bytes(
            self.take(2)?
                .try_into()
                .map_err(|_| PathHandshakeError::InvalidFrame)?,
        ) as usize;
        if length == 0 || length > max {
            return Err(PathHandshakeError::InvalidFrame);
        }
        self.take(length)
    }

    fn done(&self) -> bool {
        self.offset == self.bytes.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identities() -> (Arc<DeviceIdentity>, Arc<DeviceIdentity>) {
        (
            Arc::new(DeviceIdentity::from_private_keys(
                "initiator".into(),
                [1u8; 32],
                [2u8; 32],
            )),
            Arc::new(DeviceIdentity::from_private_keys(
                "responder".into(),
                [3u8; 32],
                [4u8; 32],
            )),
        )
    }

    fn config(
        local: &DeviceIdentity,
        remote: &DeviceIdentity,
        policy: E2eePolicy,
        path_kind: PathKind,
        binding: &[u8],
    ) -> PathHandshakeConfig {
        PathHandshakeConfig::new(
            local.device_id.clone(),
            remote.device_id.clone(),
            remote.public_identity_key().to_bytes(),
            policy,
            path_kind,
            binding.to_vec(),
            b"quic/direct/reliable-message".to_vec(),
        )
        .unwrap()
    }

    fn direct_pair(
        initiator_policy: E2eePolicy,
        responder_policy: E2eePolicy,
    ) -> (
        PathHandshake,
        PathHandshake,
        Vec<u8>,
        Arc<DeviceIdentity>,
        Arc<DeviceIdentity>,
    ) {
        let (initiator_identity, responder_identity) = identities();
        let mut initiator = PathHandshake::new(
            HandshakeRole::Initiator,
            Arc::clone(&initiator_identity),
            config(
                &initiator_identity,
                &responder_identity,
                initiator_policy,
                PathKind::Direct,
                b"path-1",
            ),
        )
        .unwrap();
        let responder = PathHandshake::new(
            HandshakeRole::Responder,
            Arc::clone(&responder_identity),
            config(
                &responder_identity,
                &initiator_identity,
                responder_policy,
                PathKind::Direct,
                b"path-1",
            ),
        )
        .unwrap();
        let hello = initiator.start().unwrap();
        (
            initiator,
            responder,
            hello,
            initiator_identity,
            responder_identity,
        )
    }

    #[test]
    fn direct_required_path_binds_identity_versions_policy_and_transcript() {
        let (mut initiator, mut responder, hello, _, _) =
            direct_pair(E2eePolicy::Required, E2eePolicy::Required);
        assert_eq!(initiator.phase(), PathHandshakePhase::AwaitingResponse);
        assert_eq!(
            initiator.admit_envelope(EnvelopeKind::ChannelMessage),
            Err(PathHandshakeError::PathNotReady)
        );
        assert_eq!(
            responder.admit_envelope(EnvelopeKind::CryptoHandshake),
            Ok(())
        );
        let response = responder.accept(&hello).unwrap().unwrap();
        let final_frame = initiator.accept(&response).unwrap().unwrap();
        assert_eq!(initiator.phase(), PathHandshakePhase::Ready);
        assert_eq!(responder.accept(&final_frame).unwrap(), None);
        assert_eq!(responder.phase(), PathHandshakePhase::Ready);
        let ready = initiator.ready().unwrap();
        assert_eq!(ready.security, PathSecurity::E2ee);
        assert_ne!(ready.transcript_hash, [0u8; 32]);
        assert_eq!(
            initiator.admit_envelope(EnvelopeKind::ChannelMessage),
            Ok(())
        );
        assert_eq!(
            initiator.admit_envelope(EnvelopeKind::CryptoHandshake),
            Err(PathHandshakeError::UnexpectedHandshakeFrame)
        );
    }

    #[test]
    fn relay_uses_data_env_crypto_after_pair_ready_and_blocks_business_until_ready() {
        let (initiator_identity, responder_identity) = identities();
        let mut initiator = PathHandshake::new(
            HandshakeRole::Initiator,
            Arc::clone(&initiator_identity),
            config(
                &initiator_identity,
                &responder_identity,
                E2eePolicy::Required,
                PathKind::Relay,
                b"relay-path",
            ),
        )
        .unwrap();
        let mut responder = PathHandshake::new(
            HandshakeRole::Responder,
            Arc::clone(&responder_identity),
            config(
                &responder_identity,
                &initiator_identity,
                E2eePolicy::Required,
                PathKind::Relay,
                b"relay-path",
            ),
        )
        .unwrap();
        assert_eq!(initiator.start(), Err(PathHandshakeError::PairNotReady));
        initiator.mark_pair_ready().unwrap();
        responder.mark_pair_ready().unwrap();
        assert_eq!(
            initiator.admit_envelope(EnvelopeKind::CryptoHandshake),
            Ok(())
        );
        assert_eq!(
            initiator.admit_envelope(EnvelopeKind::FileOffer),
            Err(PathHandshakeError::PathNotReady)
        );
    }

    #[test]
    fn disabled_is_direct_only_and_direct_policy_mismatch_is_not_downgraded() {
        let (initiator_identity, responder_identity) = identities();
        let mut initiator = PathHandshake::new(
            HandshakeRole::Initiator,
            Arc::clone(&initiator_identity),
            config(
                &initiator_identity,
                &responder_identity,
                E2eePolicy::Disabled,
                PathKind::Direct,
                b"identity-only",
            ),
        )
        .unwrap();
        let mut responder = PathHandshake::new(
            HandshakeRole::Responder,
            Arc::clone(&responder_identity),
            config(
                &responder_identity,
                &initiator_identity,
                E2eePolicy::Disabled,
                PathKind::Direct,
                b"identity-only",
            ),
        )
        .unwrap();
        let response = responder
            .accept(&initiator.start().unwrap())
            .unwrap()
            .unwrap();
        let final_frame = initiator.accept(&response).unwrap().unwrap();
        responder.accept(&final_frame).unwrap();
        assert_eq!(
            initiator.ready().unwrap().security,
            PathSecurity::IdentityOnly
        );
        assert_eq!(
            PathHandshakeConfig::new(
                "initiator",
                "responder",
                responder_identity.public_identity_key().to_bytes(),
                E2eePolicy::Disabled,
                PathKind::Relay,
                b"relay".to_vec(),
                b"ws/relay".to_vec(),
            ),
            Err(PathHandshakeError::RelayRequiresE2ee)
        );

        let (_, mut mismatch_responder, hello, _, _) =
            direct_pair(E2eePolicy::Required, E2eePolicy::Disabled);
        assert_eq!(
            mismatch_responder.accept(&hello),
            Err(PathHandshakeError::SecurityPolicyMismatch)
        );
    }

    #[test]
    fn identity_binding_and_version_downgrade_are_stable_failures() {
        let (_, mut responder, mut hello, _, _) =
            direct_pair(E2eePolicy::Required, E2eePolicy::Required);
        hello[4..8].copy_from_slice(&1u32.to_be_bytes());
        assert_eq!(
            responder.accept(&hello),
            Err(PathHandshakeError::DowngradeRejected)
        );

        let (_, mut responder, mut hello, _, _) =
            direct_pair(E2eePolicy::Required, E2eePolicy::Required);
        let peer_id_offset = 4 + 4 + 1 + 4 + 1 + 1 + 1 + 2;
        hello[peer_id_offset] ^= 0x01;
        assert_eq!(
            responder.accept(&hello),
            Err(PathHandshakeError::PeerIdentityMismatch)
        );

        let (_, mut responder, mut hello, _, _) =
            direct_pair(E2eePolicy::Required, E2eePolicy::Required);
        hello[9..13].copy_from_slice(&1u32.to_be_bytes());
        assert_eq!(
            responder.accept(&hello),
            Err(PathHandshakeError::DowngradeRejected)
        );
    }

    #[test]
    fn path_binding_and_profile_are_transcript_bound() {
        let (initiator_identity, responder_identity) = identities();
        let mut initiator = PathHandshake::new(
            HandshakeRole::Initiator,
            Arc::clone(&initiator_identity),
            config(
                &initiator_identity,
                &responder_identity,
                E2eePolicy::Required,
                PathKind::Direct,
                b"path-a",
            ),
        )
        .unwrap();
        let mut responder_config = config(
            &responder_identity,
            &initiator_identity,
            E2eePolicy::Required,
            PathKind::Direct,
            b"path-b",
        );
        responder_config.connection_profile = b"tcp/direct/reliable-message".to_vec();
        let mut responder = PathHandshake::new(
            HandshakeRole::Responder,
            Arc::clone(&responder_identity),
            responder_config,
        )
        .unwrap();
        assert_eq!(
            responder.accept(&initiator.start().unwrap()),
            Err(PathHandshakeError::PathBindingMismatch)
        );
    }

    #[test]
    fn all_relay_business_envelopes_are_blocked_before_ready() {
        let (initiator_identity, responder_identity) = identities();
        let path = PathHandshake::new(
            HandshakeRole::Initiator,
            initiator_identity,
            config(
                &DeviceIdentity::from_private_keys("initiator".into(), [1u8; 32], [2u8; 32]),
                &responder_identity,
                E2eePolicy::Required,
                PathKind::Relay,
                b"relay",
            ),
        )
        .unwrap();
        for kind in [
            DATA_ENV_CHANNEL,
            DATA_ENV_CHANNEL_ACK,
            DATA_ENV_STREAM,
            DATA_ENV_FILE_OFFER,
            DATA_ENV_FILE_ACCEPT,
            DATA_ENV_FILE_COMPLETE,
            DATA_ENV_FILE_COMPLETE_ACK,
            DATA_ENV_FILE_CANCEL,
            DATA_ENV_FILE_CHUNK,
        ] {
            assert_eq!(
                path.admit_envelope(EnvelopeKind::from_relay_type(kind).unwrap()),
                Err(PathHandshakeError::PairNotReady)
            );
        }
    }
}
