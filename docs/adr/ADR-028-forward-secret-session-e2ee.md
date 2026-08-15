> 最新更新时间：2026-08-15

# ADR-028：Forward-secret Session E2EE Key Agreement

## Status

Accepted for native network v1 Step 4. transport-network v2 retains this ADR's
v3 Root exchange, `KeyEpoch`, and structured-nonce model unchanged.

> **2026-08-15 名称澄清（transport-network v2 碰撞）**：本 ADR 中的 "v2 is
> rejected" 指 **crypto-handshake 版本**——v2 手写 Root 推导被拒绝，当前采用 v3
> Root exchange。它与 [ADR-TRANSPORT-NETWORK-V2](ADR-TRANSPORT-NETWORK-V2.md)
> 定义的 **transport-network v2（协议代际）** 是**两个正交概念**：transport-network
> v2 保留本 ADR 的 v3 `KeyEpoch` / 结构化 nonce / 前向保密，不降级、不复用被拒绝
> 的 crypto v2。见 ADR-TRANSPORT-NETWORK-V2 的命名方案。

## Context

`CryptoContext` is Session-owned and must survive QUIC, Relay, TCP, and
WebSocket route changes. The first Noise implementation replaced the older
long-lived X25519 root, but incorrectly used `get_handshake_hash()` directly as
the HKDF input key material. That hash is public transcript state; the Noise DH
secret accumulates in the chaining key and becomes usable through `Split()` /
`TransportState`. A passive observer could therefore reproduce the old
Application Root from observable handshake data.

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
- Session continuity is decided centrally by comparing the authenticated
  remote binding with the current Session's `remote_session_binding`. An equal
  binding is a route replacement and retains the local SessionId, crypto
  context, key epoch, and pending Delivery state. A different binding is a
  peer Runtime restart: the old Session, aliases, task indexes, and Delivery
  state are retired before a new local SessionId and root are installed.
- Protocol version, the `e2ee/noise-xx-aes256gcm-v3` capability, peer/device
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
- Use the same application handshake on the authenticated QUIC stream and the
  authenticated generic TCP/WebSocket stream. Relay forwards six bounded opaque
  stages: `HELLO`, `RESPONSE`, `FINAL`, `ROOT_SEED`, `ROOT_CONFIRM`, and
  `ACCEPT`. Route selection may change the carrier, but it does not
  replace an existing Session crypto context. `SessionCryptoManager` aliases
  the new route binding to the already-installed context and removes all
  aliases on explicit Session close.
- After both identity proofs succeed, convert `HandshakeState` into
  `TransportState`. The responder generates a fresh 32-byte RootSeed with
  `OsRng` and sends it only inside Noise transport ciphertext. Derive the
  direction-independent Application Root with HKDF-SHA256 using RootSeed as IKM,
  the handshake hash as transcript salt, and the v3 domain plus Session binding
  as `info`. The transcript hash is never secret input key material.
- The initiator derives and returns a v3 RootConfirm token under Noise transport;
  the responder verifies it in constant time and returns the final encrypted
  Accept. Neither side installs `SessionCryptoMaterial` or reports Connected
  before its required final stage completes. v2 is rejected and there is no
  downgrade path during development.
- Expand separate initiator-to-responder and responder-to-initiator
  AES-256-GCM traffic keys from the Application Root. Static DeviceIdentity keys
  authenticate identity only; they are not traffic roots.
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

Session creation now has a bounded application handshake and post-handshake root
exchange after transport authentication. Wrong identity, unsupported capability,
transcript mismatch, tampered RootSeed ciphertext, wrong RootConfirm, missing
Accept, or timeout prevents route admission. Relay retains only the opaque
`crypto_handshake` control type and cannot parse RootSeed or any Noise payload.

The existing encrypted Relay offer metadata may still use its separate
ephemeral X25519 envelope for pre-session transfer approval. That envelope is
not the Session traffic root and does not weaken this decision.

Key rotation is local to the Session crypto owner; route migration does not
reset counters or silently rederive business state. Explicit Session close
removes the root and all binding aliases.

## Verification

- Noise identity proof, secret-seed root derivation, wrong-pinned-identity and v2
  rejection, RootSeed tamper, wrong RootConfirm, missing Accept, all six Relay
  frames, Relay ciphertext tamper, and repeated-session root separation are
  covered in `crypto_handshake` tests. A source guard rejects restoration of
  `derive_session_root(handshake_hash, ...)`.
- `CryptoContext` tests cover 100,000 structured nonces, epoch rotation and
  recent-epoch acceptance, old-epoch rejection, wrong key/tamper/replay,
  Delivery duplicate compatibility, and missing-root downgrade rejection.
- Native route tests cover authenticated TCP/WebSocket admission and
  TCP-to-QUIC migration with unchanged SessionId, `CryptoContext` Arc, and key
  epoch.
- Required final commands are `cargo fmt --all -- --check`,
  `cargo clippy --workspace --all-targets --locked -- -D warnings`, and
  `cargo test --workspace --locked` from `native/network_core`.
