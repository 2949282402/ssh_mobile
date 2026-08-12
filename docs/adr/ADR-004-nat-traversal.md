> 最新更新时间：2026-08-12

# ADR-004: NAT Traversal and Path Selection Architecture

## Context
Peers must communicate across local networks, IPv6, NATs, and restricted firewall environments.

## Decision
We implement an **ICE-style Candidate Selection** system managed by `PathManager` in `network-nat`.

Key Principles:
1. One UDP socket is used for local/STUN candidate gathering and then handed to
   Quinn; no raw UDP probe protocol competes with Quinn on that socket.
2. Candidate Priority: LAN Direct > IPv6 Direct > Port-Mapped/Server-Reflexive
   QUIC Direct > Relay Fallback.
3. Candidate Offer/Answer carries a generation, attempt ID, and bounded connect
   window. Both peers can start authenticated QUIC Initial attempts in that
   window; the first identity-verified Connection is nominated.
4. Continuous background path sampling, automatic route upgrading (Relay ->
   Direct), and downgrade on network change remain Session-owned.
5. Relays (Go server) are strictly zero-knowledge, memory-only, opaque packet
   forwarders.

## Status
Accepted

## Consequences
- High P2P connection success rate with low relay bandwidth usage.
- Strict single-socket constraint prevents NAT binding invalidation.
- The QUIC connectivity attempt itself performs NAT punching, so there is no
  unauthenticated or dead `UdpSocket::recv_from` probe architecture.
