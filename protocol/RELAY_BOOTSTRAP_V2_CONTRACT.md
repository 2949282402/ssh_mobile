> Last updated: 2026-08-26

# Relay Bootstrap Protocol V2 — Wire Contract

## 1. Status

LOCKED (Relay / Admin Backend Split, Final Review V3). This document is the
lockstep authority for the Relay Bootstrap HTTP API that issues and refreshes
device credentials for the protocol-v2 control and relay data planes. It is the
additive successor to the legacy Bootstrap V1 shape (`POST /v1/devices/enroll`,
`POST /v1/devices/refresh`) and the companion to the frozen transport contract
`protocol/RELAY_V2_CONTRACT.md`. The protobuf wire schema
(`protocol/proto/relay/v2/relay_v2.proto`, package `relay.v2`) is not part of
this contract and is unchanged.

Transport admission depends on this contract: a durable enrollment created
here with `protocol_version = 2` is required before any `/v2/control` or
`/v2/relay/{reservation_id}` socket is admitted (§5). The v2 transport route
semantics and frame envelope are defined in the frozen
`protocol/RELAY_V2_CONTRACT.md`.

## 2. Endpoints

Both endpoints are plain HTTP(S) JSON APIs. Requests are `application/json`
with a 4096-byte body limit; responses are `application/json` with
`Cache-Control: no-store`. There is no protobuf encoding on this boundary.

### POST /v2/devices/enroll

Creates or advances a durable enrollment and issues the credential that steers
every subsequent v2 socket.

Request:

| Field | Type | Required | Notes |
|---|---|---|---|
| `device_id` | string | yes | ≤ 128 bytes |
| `public_key` | string | yes | Ed25519 raw public key, base64url (no padding) |
| `enrollment_token` | string | yes | server-issued enrollment secret |
| `protocol_version` | int | yes | MUST be 2 |
| `platform` | string | no | ≤ 64 chars, e.g. `android`, `linux` |

Response (HTTP 200):

| Field | Type | Notes |
|---|---|---|
| `credential` | string | HMAC-signed bearer credential |
| `expires_at` | int | Unix epoch seconds |
| `server_time` | int | Unix epoch seconds |
| `protocol_version` | int | always 2 |

### POST /v2/devices/refresh

Re-issues a short-lived credential for an already-enrolled device without the
enrollment token. Proof of possession of the enrolled Ed25519 key is mandatory.

Request:

| Field | Type | Notes |
|---|---|---|
| `device_id` | string | ≤ 128 bytes |
| `public_key` | string | MUST equal the enrolled public key |
| `timestamp` | int | Unix epoch seconds; positive, within the ±300 s freshness window |
| `nonce` | string | 32 random bytes, base64url (no padding), single-use |
| `signature` | string | Ed25519 signature of the refresh transcript |

Refresh transcript (exact byte string, no trailing newline):

```
POST\n/v2/devices/refresh\n<timestamp>\n<nonce>
```

- `<timestamp>` is the canonical positive decimal Unix-seconds integer.
- Clock-skew window is inclusive: `server_time - 300 <= timestamp <= server_time
  + 300`. Missing, negative, non-canonical, stale, or too-future timestamps are
  rejected.
- The nonce is atomically consumed once and expires at `timestamp + 301 s`. A
  replay or replay-protection-cache failure fails closed and never issues a
  credential.

Response (HTTP 200):

| Field | Type | Notes |
|---|---|---|
| `credential` | string | HMAC-signed bearer credential |
| `expires_at` | int | Unix epoch seconds |
| `server_time` | int | Unix epoch seconds |
| `protocol_version` | int | always 2 |

## 3. Re-enroll policy

- A refresh for a device whose durable enrollment is missing, or whose stored
  `protocol_version != 2`, fails with HTTP 404 and code `1` (protocol error /
  re-enroll required). The client MUST re-enroll with the enrollment token and
  must not silently retry refresh. The refresh endpoint never issues the
  enrollment token.
- Re-enrolling an existing `device_id` with the SAME public key advances the
  enrollment generation and sets `protocol_version = 2`. All credentials issued
  under the previous generation are invalidated immediately (active v2 sockets
  are closed) and the credential TTL is refreshed to a full window.
- Re-enrolling an existing `device_id` with a DIFFERENT public key returns HTTP
  409 code `13` (identity conflict) and leaves the existing enrollment, active
  sockets, and credentials untouched.

## 4. Downgrade protection

- The durable enrollment records the protocol version agreed at enrollment
  time. If `stored protocol_version > requested protocol_version`, the downgrade
  is rejected with HTTP 400 code `1` (protocol error). In particular a device
  enrolled at `protocol_version = 2` cannot re-enroll back to
  `protocol_version = 1`.
- `POST /v2/devices/enroll` accepts exactly `protocol_version = 2`; any other
  value is rejected with code `1` (protocol error). There is no Bootstrap V1
  fallback on this boundary.

## 5. ProtocolVersion admission invariant

Admission to `GET /v2/control` and `GET /v2/relay/{reservation_id}` requires
the durable `enrollment.ProtocolVersion == 2`, in addition to the existing
credential, enrollment-generation, key-match, revocation, and timestamped-proof
checks ([ADR-031](../docs/adr/ADR-031-relay-refresh-proof-freshness.md)). A
valid credential alone is insufficient when the durable enrollment does not
record protocol version 2: the upgrade is rejected with HTTP 401 code `2`
(`authenticationFailed`) and the client must re-enroll through this contract.

## 6. Error mapping (aligned with Dart NetworkErrorCode)

Device-plane HTTP failures return the stable structured error shape and never
expose raw server errors:

```json
{
  "code": 8,
  "message": "safe diagnostic",
  "operation": "enroll_relay",
  "peer_id": "optional-device-id"
}
```

| Code | Dart `NetworkErrorCode` | Meaning |
|---|---|---|
| 0 | `unspecified` | Unspecified |
| 1 | `invalidArgument` | Invalid argument / protocol error |
| 2 | `authenticationFailed` | Authentication failed |
| 8 | `relayError` | Relay error / storage unavailable |
| 12 | `credentialExpired` | Credential expired |
| 13 | `identityConflict` | Identity conflict |

Errors may optionally carry a retry policy mirroring the frozen v1 behavior:
`retry_disposition` (`0` unspecified, `1` no_retry, `2` retry_with_backoff,
`3` retry_after, `4` refresh_credential_then_retry) with `retry_after_seconds`
when disposition is `3`. Both fields are omitted when unspecified.

Stable endpoint-level status mappings:

| Endpoint | Condition | HTTP | Code |
|---|---|---|---|
| enroll | unsupported `protocol_version` | 400 | 1 |
| enroll | invalid token / auth | 401 | 2 |
| enroll | identity conflict (different key) | 409 | 13 |
| enroll | device capacity exhausted | 429 | 8 |
| enroll | storage unavailable | 503 | 8 |
| refresh | missing/stale identity proof | 401 | 2 |
| refresh | storage unavailable | 500/503 | 8 |
| refresh | not enrolled or `protocol_version != 2` | 404 | 1 |
| refresh | revoked device | 401 | 2 |