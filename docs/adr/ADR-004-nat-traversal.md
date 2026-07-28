# ADR-004: NAT Traversal and Path Selection Architecture

## Context
Peers must communicate across local networks, IPv6, NATs, and restricted firewall environments.

## Decision
We implement an **ICE-style Candidate Selection** system managed by `PathManager` in `network-nat`.

Key Principles:
1. Single UDP socket reused for STUN, UDP hole punching, and actual P2P transport managed by `EndpointManager`.
2. Candidate Priority: LAN Direct > IPv6 Direct > IPv4 UDP P2P (Hole Punch) > Relay Fallback.
3. Continuous background path probing, automatic route upgrading (Relay -> Direct) and downgrade on network change.
4. Relays (Go server) are strictly zero-knowledge, memory-only, opaque packet forwarders.

## Status
Accepted

## Consequences
- High P2P connection success rate with low relay bandwidth usage.
- Strict single-socket constraint prevents NAT binding invalidation.
