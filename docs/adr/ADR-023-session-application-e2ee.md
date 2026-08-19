> 最新更新时间：2026-08-19

# ADR-023：Session-owned Application E2EE

## Context

Step 3 separated runtime task ownership from the logical Session. The next
boundary must make the application payload independent from the current Route:
the same logical message can be retried over QUIC or Relay without reusing a
Route ciphertext or exposing business bytes to the Relay.

The existing Relay file implementation carried a per-attempt content key and
nonce prefix inside the encrypted offer. That protected Relay chunks, but it
made the crypto state Relay-specific and did not give Delivery retries a
single application crypto owner. Step 4 hardens the Session root with the
forward-secret Noise agreement documented in ADR-028.

## Decision

- `CryptoContext`, `CryptoSuite`, `KeyEpoch`, and bounded
  `ReplayWindow` live in native `network-core` and are keyed by
  `(peer_id, logical SessionId)`.
- `SessionCryptoManager` owns contexts for the App Scope. A transient QUIC ↔
  Relay route change does not remove a context; explicit Session close does.
- Network Protocol V2 application payloads always use ConnectionSession-owned
  E2EE. There is no plaintext fallback and no per-message crypto-mode field;
  a missing Session context fails closed with `E2eeRequired`.
- E2EE installs a Session root only after the authenticated
  `Noise_XX_25519_AESGCM_SHA256` handshake and v3 Root exchange. Fresh
  ephemeral X25519 material provides forward secrecy; the pinned Ed25519
  DeviceIdentity signs the peer, protocol version, capability, Noise static
  key, and logical Session binding. After identity proof, Noise TransportState
  protects a fresh CSPRNG RootSeed, RootConfirm, and final Accept. The root is
  expanded into directional AES-256-GCM keys. See
  [ADR-028](ADR-028-forward-secret-session-e2ee.md) for the threat model,
  identity assumptions, and rejected IK/static alternatives.
- Each E2EE envelope carries a version, suite, key epoch, structured nonce
  prefix/counter, and AEAD ciphertext. AAD binds the logical Session, channel,
  MessageId, sequence, recovery epoch, and delivery policy.
  `MAX_MESSAGES_PER_KEY` and `MAX_BYTES_PER_KEY` trigger key rotation; a
  bounded current/recent epoch window handles reordering.
- `PendingMessage` stores logical plaintext only. Every send and retry invokes
  the current ConnectionSession context and gets a new nonce. Ciphertext is
  never persisted in Delivery recovery state.
- Channel `DataMessage` payloads use the context on QUIC, Relay, TCP, and
  WebSocket. Relay forwards the three Noise handshake plus RootSeed,
  RootConfirm, and Accept ciphertexts only as opaque `crypto_handshake`
  controls and never sees RootSeed plaintext, the root, or business plaintext.
- Relay file offers no longer carry `content_key` or `nonce_prefix`. The
  encrypted offer carries the sender's logical Session key; file chunks use
  the same Session context and AAD binds the transfer, manifest, and chunk
  sequence. Route attempt tokens remain control-plane identifiers only.

## Rejected alternatives

- Keeping a Relay-only `RelayChunkCipher` would preserve a second crypto
  owner and make Route migration semantics ambiguous.
- Caching ciphertext in Delivery would reuse a nonce/envelope after a Route
  change and would bind recovery to a dead Connection.
- Treating the Relay offer's random attempt token as the crypto Session would
  discard keys during reconnect and violate Session/Connection separation.
- Adding a custom unauthenticated DH exchange would duplicate identity
  protocol responsibilities and create a new downgrade surface; the selected
  Noise framework and ADR-028 identity proof are the only Session root path.

## Verification

Native tests cover mandatory E2EE, Noise identity and
forward-secrecy properties, opaque Relay handshake framing, QUIC/TCP/WebSocket
delivery recovery, Relay file chunks, same-context Route migration, 100,000
structured nonces, key rotation, wrong-key and tamper rejection, replay
rejection, nonce reuse rejection, and plaintext retention in Delivery pending
state. `cargo fmt`, workspace Clippy with `-D warnings`, and the full locked
native workspace test suite are required before this Step is committed.
