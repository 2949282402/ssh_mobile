> 最新更新时间：2026-08-12

# ADR-023：Session-owned Application E2EE

## Context

Step 3 separated runtime task ownership from the logical Session. The next
boundary must make the application payload independent from the current Route:
the same logical message can be retried over QUIC or Relay without reusing a
Route ciphertext or exposing business bytes to the Relay.

The existing Relay file implementation carried a per-attempt content key and
nonce prefix inside the encrypted offer. That protected Relay chunks, but it
made the crypto state Relay-specific and did not give Delivery retries a
single application crypto owner.

## Decision

- `CryptoContext`, `CryptoMode`, `CryptoSuite`, `KeyEpoch`, and bounded
  `ReplayWindow` live in native `network-core` and are keyed by
  `(peer_id, logical SessionId)`.
- `SessionCryptoManager` owns contexts for the App Scope. A transient QUIC ↔
  Relay route change does not remove a context; explicit Session close does.
- E2EE is the protobuf zero value and therefore the secure default. Clear
  application payloads require an explicit `CryptoModeCode::None` request.
- E2EE derives a Session root with HKDF-SHA256 from the already paired static
  X25519 DeviceIdentity keys and the logical wire SessionId. Directional
  AES-256-GCM keys are domain-separated by the ordered public keys. The
  existing Ed25519 identity-bound QUIC handshake and pinned peer E2E key
  registry remain the authentication boundary; this Step does not invent a
  second handshake. A future forward-secret handshake can replace the root
  derivation behind the same context boundary. Noise is a framework for such
  authenticated DH handshakes, not a reason to add an ad-hoc handshake here;
  see the [Noise Protocol Framework](https://noiseprotocol.org/noise.html).
- Each E2EE envelope carries a version, suite, key epoch, random 96-bit
  nonce, and AEAD ciphertext. AAD binds the logical Session, channel,
  MessageId, sequence, recovery epoch, delivery policy, and crypto mode.
- `PendingMessage` stores logical plaintext plus its crypto mode. Every send
  and retry invokes the current context and gets a new nonce. Ciphertext is
  never persisted in Delivery recovery state.
- Channel `DataMessage` payloads use the context on both QUIC and Relay. Relay
  continues to forward only opaque encoded messages.
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
  protocol responsibilities and create a new downgrade surface.

## Verification

Native tests cover disabled and default E2EE modes, QUIC delivery recovery,
Relay file chunks, same-context Route migration, key rotation, wrong-key and
tamper rejection, replay rejection, nonce reuse rejection, and plaintext
retention in Delivery pending state. `cargo fmt`, workspace Clippy with
`-D warnings`, and the full locked native workspace test suite are required
before this Step is committed.
