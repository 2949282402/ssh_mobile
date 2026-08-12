> 最新更新时间：2026-08-12

# ADR-028：Forward-secret Session E2EE Key Agreement

## Status

Accepted for native network v1 Step 4.

## Context

`CryptoContext` is Session-owned and must survive QUIC, Relay, TCP, and
WebSocket route changes. The previous production derivation used the paired
long-lived X25519 DeviceIdentity keys directly as the Session root input. A
future compromise of those keys could therefore expose recorded historical
Session traffic. Random GCM nonces also left uniqueness dependent on a
probabilistic bound rather than an explicit Session counter.

The threat model includes a passive recorder that later obtains a long-lived
DeviceIdentity key, an active peer presenting the wrong pinned identity, a
malicious or compromised Relay, replayed Delivery ciphertext, and route
fallback attempts that try to silently disable E2EE. The Relay is an opaque
forwarder; it is not trusted with Session plaintext or Noise state.

## Identity and Session assumptions

- Each configured `PeerId` is pinned to an Ed25519 `DeviceIdentity` public key
  in the native trusted-peer registry. The transport identity check and the
  application proof must resolve to the same peer.
- The logical Session binding is the native wire `SessionId` of the handshake
  initiator. The responder aliases that binding to its local SessionId only
  after the authenticated transcript completes; a Relay attempt token is not
  a crypto key selector.
- Protocol version, the `e2ee/noise-xx-aes256gcm-v2` capability, peer/device
  identity, and Session binding are signed or transcript-bound before a root
  is installed. A failed proof never creates a Connected Session or a crypto
  context.
- Runtime restart creates a new logical Session and therefore a new ephemeral
  Noise transcript/root. Old counters are never restored into a new root.

## Decision

- Use the mature Noise Protocol Framework implementation (`snow`) with
  `Noise_XX_25519_AESGCM_SHA256`. Each Session handshake generates a fresh
  ephemeral X25519 Noise static key. The long-lived Ed25519 identity signs the
  role, device ID, identity public key, Noise static public key, protocol
  version, capability, and Session binding inside the encrypted Noise
  payloads.
- Use the same application handshake on the authenticated QUIC stream, the
  authenticated generic TCP/WebSocket stream, and three bounded opaque Relay
  control messages. Route selection may change the carrier, but it does not
  replace an existing Session crypto context. `SessionCryptoManager` aliases
  the new route binding to the already-installed context and removes all
  aliases on explicit Session close.
- Derive a direction-independent Session root from the Noise handshake hash
  and Session binding. Expand separate initiator-to-responder and
  responder-to-initiator AES-256-GCM traffic keys. The static DeviceIdentity
  keys are authentication material only; they are not traffic roots.
- Build every production application nonce as
  `prefix(epoch, direction) || counter`, with a four-byte HKDF-derived prefix
  and an eight-byte big-endian monotonic counter. Rotate before either
  `MAX_MESSAGES_PER_KEY` or `MAX_BYTES_PER_KEY` is exceeded. Receivers accept
  the current epoch and a bounded recent window, while epoch jumps and prefix
  mismatches are rejected.
- Keep E2EE as the protobuf default. `CryptoMode::None` remains an explicit
  caller opt-out only; a requested E2EE payload with no installed context
  returns `E2eeRequired`, and no route fallback changes that mode.
- Keep authenticated Delivery replay handling: AEAD-authenticated duplicate
  ciphertext may reach Delivery's `DuplicateInFlight`/`DuplicateProcessed`
  logic, while unauthenticated or best-effort replay is rejected by the
  crypto window.

## Why Noise XX

Noise XX was selected because this Session boundary must authenticate pinned
long-lived identities while still allowing both peers to contribute fresh
ephemeral DH material without assuming that the remote static Noise key is
already provisioned. The existing Ed25519 registry supplies the application
identity binding, and the Noise transcript supplies authenticated forward
secret key agreement.

Noise IK was evaluated but rejected for this Step: it assumes a pre-known
remote Noise static key, while the repository currently pins Ed25519 device
identity keys rather than long-lived Noise static keys and must avoid creating
a second static-key lifecycle. A custom X25519-plus-signature exchange was
also rejected because it would duplicate a mature handshake framework and
make message-state, transcript, and downgrade review harder. Reusing the old
static X25519 derivation was rejected because it provides no forward secrecy.

## Consequences

Session creation now has a bounded application handshake after transport
authentication. Wrong identity, unsupported capability, transcript mismatch,
or handshake timeout prevents route admission. Relay gains only an opaque
`crypto_handshake` control type and does not parse the Noise payload.

The existing encrypted Relay offer metadata may still use its separate
ephemeral X25519 envelope for pre-session transfer approval. That envelope is
not the Session traffic root and does not weaken this decision.

Key rotation is local to the Session crypto owner; route migration does not
reset counters or silently rederive business state. Explicit Session close
removes the root and all binding aliases.

## Verification

- Noise identity proof, wrong-pinned-identity rejection, Relay opaque frame
  exchange, and repeated-session root separation are covered in
  `crypto_handshake` tests.
- `CryptoContext` tests cover 100,000 structured nonces, epoch rotation and
  recent-epoch acceptance, old-epoch rejection, wrong key/tamper/replay,
  Delivery duplicate compatibility, and missing-root downgrade rejection.
- Native route tests cover authenticated TCP/WebSocket admission and
  TCP-to-QUIC migration with SessionId and crypto state preservation.
- Required final commands are `cargo fmt --all -- --check`,
  `cargo clippy --workspace --all-targets --locked -- -D warnings`, and
  `cargo test --workspace --locked` from `native/network_core`.
