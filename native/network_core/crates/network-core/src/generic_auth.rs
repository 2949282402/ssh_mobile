//! Application authentication for non-QUIC Session routes.
//!
//! TCP and WebSocket establish a socket, not a trusted peer. This module keeps
//! their admission rule equivalent to the QUIC application handshake: both
//! sides prove the pinned Ed25519 identity and sign the logical Session
//! binding before the route can be attached to `SessionManager`.

use ed25519_dalek::VerifyingKey;
use network_identity::DeviceIdentity;
use network_protocol::NETWORK_PROTOCOL_VERSION;
use std::collections::HashMap;
use std::io::{Error, ErrorKind};
use tokio::sync::RwLock;

use crate::connection::GenericConnection;

const AUTH_MAGIC: &[u8; 4] = b"SMGA";
const INITIATOR_FRAME: u8 = 1;
const RESPONDER_FRAME: u8 = 2;
const MAX_DEVICE_ID_BYTES: usize = 128;
const MAX_SESSION_BINDING_BYTES: usize = 128;
const NONCE_BYTES: usize = 32;
const SIGNATURE_BYTES: usize = 64;
const PUBLIC_KEY_BYTES: usize = 32;
const INITIATOR_DOMAIN: &[u8] = b"ssh-mobile/generic-auth/initiator/v1";
const RESPONDER_DOMAIN: &[u8] = b"ssh-mobile/generic-auth/responder/v1";

pub(crate) struct AuthenticatedPeer {
    pub(crate) peer_id: String,
    pub(crate) session_binding: String,
}

pub(crate) async fn authenticate_initiator(
    connection: &mut GenericConnection,
    local_identity: &DeviceIdentity,
    expected_peer_id: &str,
    expected_peer_public_key: [u8; 32],
    session_binding: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    validate_binding(session_binding)?;
    let local_public_key = local_identity.public_identity_key().to_bytes();
    let initiator_nonce = rand::random::<[u8; NONCE_BYTES]>();
    let initiator_payload = authentication_payload(
        INITIATOR_DOMAIN,
        &local_identity.device_id,
        &local_public_key,
        session_binding,
        &[&initiator_nonce],
    );
    let initiator_signature = local_identity.sign_proof(&initiator_payload);
    connection
        .send(&encode_auth_frame(
            INITIATOR_FRAME,
            &local_identity.device_id,
            &local_public_key,
            session_binding,
            &initiator_nonce,
            &initiator_signature,
        )?)
        .await?;

    let response = decode_auth_frame(&connection.recv().await?)?;
    if response.kind != RESPONDER_FRAME {
        return Err(Error::new(ErrorKind::InvalidData, "unexpected generic auth response").into());
    }
    validate_peer_frame(
        &response,
        expected_peer_id,
        &expected_peer_public_key,
        RESPONDER_DOMAIN,
        &[&initiator_nonce, &response.nonce],
    )?;
    Ok(())
}

pub(crate) async fn authenticate_responder(
    connection: &mut GenericConnection,
    local_identity: &DeviceIdentity,
    trusted_peer_keys: &RwLock<HashMap<String, [u8; 32]>>,
) -> Result<AuthenticatedPeer, Box<dyn std::error::Error + Send + Sync>> {
    let request = decode_auth_frame(&connection.recv().await?)?;
    if request.kind != INITIATOR_FRAME {
        return Err(Error::new(ErrorKind::InvalidData, "unexpected generic auth request").into());
    }
    let expected_key = trusted_peer_keys
        .read()
        .await
        .get(&request.device_id)
        .copied()
        .ok_or_else(|| Error::new(ErrorKind::PermissionDenied, "untrusted generic peer"))?;
    validate_peer_frame(
        &request,
        &request.device_id,
        &expected_key,
        INITIATOR_DOMAIN,
        &[&request.nonce],
    )?;

    let local_public_key = local_identity.public_identity_key().to_bytes();
    let responder_nonce = rand::random::<[u8; NONCE_BYTES]>();
    let responder_payload = authentication_payload(
        RESPONDER_DOMAIN,
        &local_identity.device_id,
        &local_public_key,
        &request.session_binding,
        &[&request.nonce, &responder_nonce],
    );
    let responder_signature = local_identity.sign_proof(&responder_payload);
    connection
        .send(&encode_auth_frame(
            RESPONDER_FRAME,
            &local_identity.device_id,
            &local_public_key,
            &request.session_binding,
            &responder_nonce,
            &responder_signature,
        )?)
        .await?;
    Ok(AuthenticatedPeer {
        peer_id: request.device_id,
        session_binding: request.session_binding,
    })
}

struct AuthFrame {
    kind: u8,
    device_id: String,
    public_key: [u8; PUBLIC_KEY_BYTES],
    session_binding: String,
    nonce: [u8; NONCE_BYTES],
    signature: [u8; SIGNATURE_BYTES],
}

fn encode_auth_frame(
    kind: u8,
    device_id: &str,
    public_key: &[u8; PUBLIC_KEY_BYTES],
    session_binding: &str,
    nonce: &[u8; NONCE_BYTES],
    signature: &[u8],
) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    if !matches!(kind, INITIATOR_FRAME | RESPONDER_FRAME)
        || device_id.is_empty()
        || device_id.len() > MAX_DEVICE_ID_BYTES
        || signature.len() != SIGNATURE_BYTES
    {
        return Err(Error::new(ErrorKind::InvalidInput, "invalid generic auth frame").into());
    }
    validate_binding(session_binding)?;
    let mut frame = Vec::with_capacity(
        4 + 4
            + 1
            + 2
            + device_id.len()
            + PUBLIC_KEY_BYTES
            + 2
            + session_binding.len()
            + NONCE_BYTES
            + SIGNATURE_BYTES,
    );
    frame.extend_from_slice(AUTH_MAGIC);
    frame.extend_from_slice(&NETWORK_PROTOCOL_VERSION.to_be_bytes());
    frame.push(kind);
    frame.extend_from_slice(&(device_id.len() as u16).to_be_bytes());
    frame.extend_from_slice(device_id.as_bytes());
    frame.extend_from_slice(public_key);
    frame.extend_from_slice(&(session_binding.len() as u16).to_be_bytes());
    frame.extend_from_slice(session_binding.as_bytes());
    frame.extend_from_slice(nonce);
    frame.extend_from_slice(signature);
    Ok(frame)
}

fn decode_auth_frame(frame: &[u8]) -> Result<AuthFrame, Box<dyn std::error::Error + Send + Sync>> {
    let mut offset = 0;
    if frame.len() < 4 + 4 + 1 + 2 || &frame[..4] != AUTH_MAGIC {
        return Err(Error::new(ErrorKind::InvalidData, "invalid generic auth magic").into());
    }
    offset += 4;
    if read_u32(frame, &mut offset)? != NETWORK_PROTOCOL_VERSION {
        return Err(Error::new(ErrorKind::InvalidData, "unsupported generic auth version").into());
    }
    let kind = read_byte(frame, &mut offset)?;
    let device_id_len = read_u16(frame, &mut offset)? as usize;
    if device_id_len == 0 || device_id_len > MAX_DEVICE_ID_BYTES {
        return Err(Error::new(ErrorKind::InvalidData, "invalid generic device ID length").into());
    }
    let device_id = String::from_utf8(read_exact(frame, &mut offset, device_id_len)?.to_vec())
        .map_err(|_| Error::new(ErrorKind::InvalidData, "generic device ID is not UTF-8"))?;
    let public_key: [u8; PUBLIC_KEY_BYTES] = read_exact(frame, &mut offset, PUBLIC_KEY_BYTES)?
        .try_into()
        .expect("public key length");
    let binding_len = read_u16(frame, &mut offset)? as usize;
    if binding_len == 0 || binding_len > MAX_SESSION_BINDING_BYTES {
        return Err(Error::new(
            ErrorKind::InvalidData,
            "invalid generic Session binding length",
        )
        .into());
    }
    let session_binding = String::from_utf8(read_exact(frame, &mut offset, binding_len)?.to_vec())
        .map_err(|_| {
            Error::new(
                ErrorKind::InvalidData,
                "generic Session binding is not UTF-8",
            )
        })?;
    validate_binding(&session_binding)?;
    let nonce: [u8; NONCE_BYTES] = read_exact(frame, &mut offset, NONCE_BYTES)?
        .try_into()
        .expect("nonce length");
    let signature: [u8; SIGNATURE_BYTES] = read_exact(frame, &mut offset, SIGNATURE_BYTES)?
        .try_into()
        .expect("signature length");
    if offset != frame.len() {
        return Err(Error::new(ErrorKind::InvalidData, "trailing generic auth bytes").into());
    }
    Ok(AuthFrame {
        kind,
        device_id,
        public_key,
        session_binding,
        nonce,
        signature,
    })
}

fn validate_peer_frame(
    frame: &AuthFrame,
    expected_device_id: &str,
    expected_public_key: &[u8; PUBLIC_KEY_BYTES],
    domain: &[u8],
    nonces: &[&[u8]],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if frame.device_id != expected_device_id || &frame.public_key != expected_public_key {
        return Err(Error::new(
            ErrorKind::PermissionDenied,
            "unexpected generic peer identity",
        )
        .into());
    }
    let peer_key = VerifyingKey::from_bytes(expected_public_key)
        .map_err(|_| Error::new(ErrorKind::InvalidData, "invalid peer Ed25519 key"))?;
    let payload = authentication_payload(
        domain,
        &frame.device_id,
        &frame.public_key,
        &frame.session_binding,
        nonces,
    );
    if !DeviceIdentity::verify_peer_proof(&peer_key, &payload, &frame.signature) {
        return Err(Error::new(ErrorKind::PermissionDenied, "invalid generic peer proof").into());
    }
    Ok(())
}

fn authentication_payload(
    domain: &[u8],
    device_id: &str,
    public_key: &[u8; PUBLIC_KEY_BYTES],
    session_binding: &str,
    nonces: &[&[u8]],
) -> Vec<u8> {
    let mut payload = Vec::with_capacity(
        domain.len()
            + 4
            + 2
            + device_id.len()
            + PUBLIC_KEY_BYTES
            + 2
            + session_binding.len()
            + NONCE_BYTES * nonces.len(),
    );
    payload.extend_from_slice(domain);
    payload.extend_from_slice(&NETWORK_PROTOCOL_VERSION.to_be_bytes());
    payload.extend_from_slice(&(device_id.len() as u16).to_be_bytes());
    payload.extend_from_slice(device_id.as_bytes());
    payload.extend_from_slice(public_key);
    payload.extend_from_slice(&(session_binding.len() as u16).to_be_bytes());
    payload.extend_from_slice(session_binding.as_bytes());
    for nonce in nonces {
        payload.extend_from_slice(nonce);
    }
    payload
}

fn validate_binding(binding: &str) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if binding.is_empty()
        || binding.len() > MAX_SESSION_BINDING_BYTES
        || !binding.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(Error::new(ErrorKind::InvalidInput, "invalid generic Session binding").into());
    }
    Ok(())
}

fn read_byte(
    frame: &[u8],
    offset: &mut usize,
) -> Result<u8, Box<dyn std::error::Error + Send + Sync>> {
    let value = *frame
        .get(*offset)
        .ok_or_else(|| Error::new(ErrorKind::UnexpectedEof, "truncated generic auth frame"))?;
    *offset += 1;
    Ok(value)
}

fn read_u16(
    frame: &[u8],
    offset: &mut usize,
) -> Result<u16, Box<dyn std::error::Error + Send + Sync>> {
    Ok(u16::from_be_bytes(
        read_exact(frame, offset, 2)?
            .try_into()
            .expect("u16 length"),
    ))
}

fn read_u32(
    frame: &[u8],
    offset: &mut usize,
) -> Result<u32, Box<dyn std::error::Error + Send + Sync>> {
    Ok(u32::from_be_bytes(
        read_exact(frame, offset, 4)?
            .try_into()
            .expect("u32 length"),
    ))
}

fn read_exact<'a>(
    frame: &'a [u8],
    offset: &mut usize,
    length: usize,
) -> Result<&'a [u8], Box<dyn std::error::Error + Send + Sync>> {
    let end = offset
        .checked_add(length)
        .ok_or_else(|| Error::new(ErrorKind::InvalidData, "generic auth frame length overflow"))?;
    let bytes = frame
        .get(*offset..end)
        .ok_or_else(|| Error::new(ErrorKind::UnexpectedEof, "truncated generic auth frame"))?;
    *offset = end;
    Ok(bytes)
}
