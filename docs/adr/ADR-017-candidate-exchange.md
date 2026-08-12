> 最新更新时间：2026-08-12

# ADR-017：Peer Candidate Exchange and Connectivity Checks

## Status

Accepted for the native network v1 runtime.

## Context

One configured peer endpoint is insufficient for LAN interfaces, server
reflexive addresses, public IPv6, and route changes. Candidate reachability
must not be treated as trust: a path is usable only after the existing
identity-bound QUIC handshake succeeds.

## Decision

- `network-nat` owns the bounded Candidate model and ICE-like Offer/Answer
  state. Every candidate carries an ID, endpoint, kind, priority, interface,
  and non-zero generation.
- Candidate signaling uses authenticated Relay control frames
  (`candidate_offer` and `candidate_answer`) and opaque URL-safe payloads. The
  Relay validates only envelope limits and online peer routing; it does not
  interpret candidate endpoints.
- Each Offer starts a bounded connectivity attempt identified by an opaque
  `attempt_id`; the Answer echoes that ID and carries the negotiated connect
  window. Answers for an older attempt are ignored. The answering peer also
  starts parallel authenticated QUIC Initial attempts in the same window, so
  the QUIC attempt itself performs NAT punching on the shared socket.
- A new generation atomically replaces the previous remote candidate set.
  Older generations are ignored, and a same-generation update is treated as a
  complete set so removed addresses cannot remain usable indefinitely.
- Direct connectivity checks run as parallel authenticated QUIC attempts over
  the ranked candidates. The first identity-verified connection wins; failed,
  unreachable, or incorrectly authenticated candidates do not block other
  candidates. Relay remains the fallback route.
- STUN candidate gathering accepts a bounded comma-separated list of servers
  from `SSH_MOBILE_STUN_SERVERS`; responses must match the source address,
  magic cookie, transaction ID, and IPv4/IPv6 XOR-MAPPED-ADDRESS.
- Candidate lists are bounded to 32 entries and 32 KiB per signaling payload.
  Quality metrics are sampled after authentication and affect ranking only;
  they are not trusted when received from a peer.

## Consequences

The runtime can exchange multiple LAN, public IPv6, and server-reflexive
candidates without changing the Flutter/client business protocol. Candidate
updates can be applied without accepting stale NAT state. Full Relay-to-Direct
background upgrade uses the same bounded QUIC attempt and additional native
transports remain later integration steps; this ADR defines the candidate
exchange and authenticated nomination boundary they will consume.

## Verification

The native tests cover multiple candidates, deterministic LAN/IPv6/NAT fallback
ranking, stale generation/attempt rejection, duplicate/mismatched candidate
rejection, STUN transaction and IPv4/IPv6 parsing, and Relay codec preservation.
The retained Docker Relay harness covers end-to-end Candidate Offer/Answer
routing. Full-cone, port-restricted, symmetric-NAT, and UDP-blocked behavior is
represented by deterministic candidate fixtures in unit tests; privileged
network-namespace testing remains an environment-dependent integration gate.
