// PathHandshakeV2 metadata owned by the existing Noise application handshake.
//
// This module deliberately contains no wire handshake. PathHandshakeV2 is an
// evolution of the existing Noise transcript: its metadata is carried in the
// encrypted Noise application payloads and is therefore authenticated by the
// existing Noise state. A Relay only forwards the existing `DATA_ENV_CRYPTO`
// envelope; it never gets a second security protocol.

use sha2::{Digest, Sha256};

pub(crate) const PATH_HANDSHAKE_VERSION: u32 = 2;
pub(crate) const NETWORK_DATA_PROTOCOL_VERSION: u32 = 2;

const TRANSCRIPT_DOMAIN: &[u8] = b"ssh-mobile/path-handshake/transcript/v2";
const MAX_PEER_ID_BYTES: usize = 128;
const MAX_PATH_BINDING_BYTES: usize = 256;
const MAX_CONNECTION_PROFILE_BYTES: usize = 256;
const IDENTITY_KEY_BYTES: usize = 32;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(u8)]
pub(crate) enum E2eePolicy {
    #[default]
    Required = 0,
    Disabled = 1,
}

impl E2eePolicy {
    pub(crate) fn from_code(code: u8) -> Result<Self, PathHandshakeError> {
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
    pub(crate) fn from_code(code: u8) -> Result<Self, PathHandshakeError> {
        match code {
            1 => Ok(Self::Direct),
            2 => Ok(Self::Relay),
            _ => Err(PathHandshakeError::InvalidFrame),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub(crate) enum PathHandshakeError {
    #[error("PathHandshakeV2 metadata is invalid")]
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
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PathHandshakeMetadata {
    pub(crate) path_handshake_version: u32,
    pub(crate) network_data_protocol_version: u32,
    pub(crate) e2ee_policy: E2eePolicy,
    pub(crate) path_kind: PathKind,
    pub(crate) path_binding: Vec<u8>,
    pub(crate) connection_profile: Vec<u8>,
}

impl PathHandshakeMetadata {
    pub(crate) fn new(
        e2ee_policy: E2eePolicy,
        path_kind: PathKind,
        path_binding: Vec<u8>,
        connection_profile: Vec<u8>,
    ) -> Result<Self, PathHandshakeError> {
        validate_bytes(&path_binding, MAX_PATH_BINDING_BYTES)?;
        validate_bytes(&connection_profile, MAX_CONNECTION_PROFILE_BYTES)?;
        if path_kind == PathKind::Relay && e2ee_policy == E2eePolicy::Disabled {
            return Err(PathHandshakeError::RelayRequiresE2ee);
        }
        Ok(Self {
            path_handshake_version: PATH_HANDSHAKE_VERSION,
            network_data_protocol_version: NETWORK_DATA_PROTOCOL_VERSION,
            e2ee_policy,
            path_kind,
            path_binding,
            connection_profile,
        })
    }

    pub(crate) fn encode(&self, output: &mut Vec<u8>) -> Result<(), PathHandshakeError> {
        if self.path_handshake_version != PATH_HANDSHAKE_VERSION
            || self.network_data_protocol_version != NETWORK_DATA_PROTOCOL_VERSION
        {
            return Err(PathHandshakeError::PeerProtocolMismatch);
        }
        output.extend_from_slice(&self.path_handshake_version.to_be_bytes());
        output.extend_from_slice(&self.network_data_protocol_version.to_be_bytes());
        output.push(self.e2ee_policy as u8);
        output.push(self.path_kind as u8);
        append_bytes(output, &self.path_binding, MAX_PATH_BINDING_BYTES)?;
        append_bytes(
            output,
            &self.connection_profile,
            MAX_CONNECTION_PROFILE_BYTES,
        )?;
        Ok(())
    }

    pub(crate) fn decode(cursor: &mut impl MetadataCursor) -> Result<Self, PathHandshakeError> {
        let path_handshake_version = cursor.take_u32()?;
        if path_handshake_version < PATH_HANDSHAKE_VERSION {
            return Err(PathHandshakeError::DowngradeRejected);
        }
        if path_handshake_version != PATH_HANDSHAKE_VERSION {
            return Err(PathHandshakeError::PeerProtocolMismatch);
        }
        let network_data_protocol_version = cursor.take_u32()?;
        if network_data_protocol_version < NETWORK_DATA_PROTOCOL_VERSION {
            return Err(PathHandshakeError::DowngradeRejected);
        }
        if network_data_protocol_version != NETWORK_DATA_PROTOCOL_VERSION {
            return Err(PathHandshakeError::PeerProtocolMismatch);
        }
        let e2ee_policy = E2eePolicy::from_code(cursor.take_byte()?)?;
        let path_kind = PathKind::from_code(cursor.take_byte()?)?;
        let path_binding = cursor.take_bytes(MAX_PATH_BINDING_BYTES)?.to_vec();
        let connection_profile = cursor.take_bytes(MAX_CONNECTION_PROFILE_BYTES)?.to_vec();
        let metadata = Self {
            path_handshake_version,
            network_data_protocol_version,
            e2ee_policy,
            path_kind,
            path_binding,
            connection_profile,
        };
        if metadata.path_kind == PathKind::Relay && metadata.e2ee_policy == E2eePolicy::Disabled {
            return Err(PathHandshakeError::RelayRequiresE2ee);
        }
        Ok(metadata)
    }

    pub(crate) fn transcript_bytes(
        &self,
        initiator_id: &str,
        initiator_key: &[u8; IDENTITY_KEY_BYTES],
        responder_id: &str,
        responder_key: &[u8; IDENTITY_KEY_BYTES],
        responder_policy: E2eePolicy,
    ) -> Result<Vec<u8>, PathHandshakeError> {
        validate_peer_id(initiator_id)?;
        validate_peer_id(responder_id)?;
        validate_identity_key(initiator_key)?;
        validate_identity_key(responder_key)?;
        if self.path_kind == PathKind::Relay
            && (self.e2ee_policy == E2eePolicy::Disabled
                || responder_policy == E2eePolicy::Disabled)
        {
            return Err(PathHandshakeError::RelayRequiresE2ee);
        }
        if self.e2ee_policy != responder_policy {
            return Err(PathHandshakeError::SecurityPolicyMismatch);
        }
        let mut output = Vec::with_capacity(512);
        output.extend_from_slice(TRANSCRIPT_DOMAIN);
        self.encode(&mut output)?;
        output.push(responder_policy as u8);
        append_string(&mut output, initiator_id, MAX_PEER_ID_BYTES)?;
        output.extend_from_slice(initiator_key);
        append_string(&mut output, responder_id, MAX_PEER_ID_BYTES)?;
        output.extend_from_slice(responder_key);
        Ok(output)
    }

    pub(crate) fn transcript_hash(
        &self,
        initiator_id: &str,
        initiator_key: &[u8; IDENTITY_KEY_BYTES],
        responder_id: &str,
        responder_key: &[u8; IDENTITY_KEY_BYTES],
        responder_policy: E2eePolicy,
    ) -> Result<[u8; 32], PathHandshakeError> {
        Ok(Sha256::digest(self.transcript_bytes(
            initiator_id,
            initiator_key,
            responder_id,
            responder_key,
            responder_policy,
        )?)
        .into())
    }
}

pub(crate) trait MetadataCursor {
    fn take_byte(&mut self) -> Result<u8, PathHandshakeError>;
    fn take_u32(&mut self) -> Result<u32, PathHandshakeError>;
    fn take_bytes(&mut self, max: usize) -> Result<&[u8], PathHandshakeError>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PathSecurity {
    E2ee,
    IdentityOnly,
}

pub(crate) fn negotiate_security(
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
    output.extend_from_slice(&(value.len() as u16).to_be_bytes());
    output.extend_from_slice(value.as_bytes());
    Ok(())
}

fn append_bytes(output: &mut Vec<u8>, value: &[u8], max: usize) -> Result<(), PathHandshakeError> {
    if value.is_empty() || value.len() > max || value.len() > u16::MAX as usize {
        return Err(PathHandshakeError::InvalidFrame);
    }
    output.extend_from_slice(&(value.len() as u16).to_be_bytes());
    output.extend_from_slice(value);
    Ok(())
}

#[cfg(test)]
mod tests {
    use network_identity::DeviceIdentity;
    use super::*;

    fn identity(id: &str, seed: u8) -> DeviceIdentity {
        DeviceIdentity::from_private_keys(id.into(), [seed; 32], [seed.wrapping_add(1); 32])
    }

    #[test]
    fn metadata_transcript_binds_versions_identities_policy_binding_and_profile() {
        let initiator = identity("initiator", 1);
        let responder = identity("responder", 3);
        let metadata = PathHandshakeMetadata::new(
            E2eePolicy::Required,
            PathKind::Direct,
            b"session-binding".to_vec(),
            b"direct/quic/v2".to_vec(),
        )
        .unwrap();
        let first = metadata
            .transcript_hash(
                &initiator.device_id,
                &initiator.public_identity_key().to_bytes(),
                &responder.device_id,
                &responder.public_identity_key().to_bytes(),
                E2eePolicy::Required,
            )
            .unwrap();
        let disabled = PathHandshakeMetadata::new(
            E2eePolicy::Disabled,
            PathKind::Direct,
            b"session-binding".to_vec(),
            b"direct/quic/v2".to_vec(),
        )
        .unwrap();
        assert_ne!(
            first,
            disabled
                .transcript_hash(
                    &initiator.device_id,
                    &initiator.public_identity_key().to_bytes(),
                    &responder.device_id,
                    &responder.public_identity_key().to_bytes(),
                    E2eePolicy::Disabled,
                )
                .unwrap()
        );
        for changed in [
            PathHandshakeMetadata::new(
                E2eePolicy::Required,
                PathKind::Direct,
                b"other-binding".to_vec(),
                b"direct/quic/v2".to_vec(),
            )
            .unwrap(),
            PathHandshakeMetadata::new(
                E2eePolicy::Required,
                PathKind::Direct,
                b"session-binding".to_vec(),
                b"direct/tcp/v2".to_vec(),
            )
            .unwrap(),
        ] {
            assert_ne!(
                first,
                changed
                    .transcript_hash(
                        &initiator.device_id,
                        &initiator.public_identity_key().to_bytes(),
                        &responder.device_id,
                        &responder.public_identity_key().to_bytes(),
                        E2eePolicy::Required,
                    )
                    .unwrap()
            );
        }
        assert_ne!(
            first,
            metadata
                .transcript_hash(
                    &responder.device_id,
                    &responder.public_identity_key().to_bytes(),
                    &initiator.device_id,
                    &initiator.public_identity_key().to_bytes(),
                    E2eePolicy::Required,
                )
                .unwrap()
        );
    }

    #[test]
    fn policy_rules_are_fail_closed() {
        assert_eq!(
            negotiate_security(PathKind::Direct, E2eePolicy::Required, E2eePolicy::Disabled),
            Err(PathHandshakeError::SecurityPolicyMismatch)
        );
        assert_eq!(
            negotiate_security(PathKind::Relay, E2eePolicy::Disabled, E2eePolicy::Disabled),
            Err(PathHandshakeError::RelayRequiresE2ee)
        );
        assert_eq!(
            PathHandshakeMetadata::new(
                E2eePolicy::Disabled,
                PathKind::Relay,
                b"binding".to_vec(),
                b"relay-data/v2".to_vec(),
            ),
            Err(PathHandshakeError::RelayRequiresE2ee)
        );
    }
}
