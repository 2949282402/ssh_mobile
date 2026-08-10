> Last updated: 2026-08-10

# ADR-005: Network Identity & Cryptographic Key Segregation

## Context
Device authentication and E2E encryption have distinct security requirements.

## Decision
We enforce strict key separation into two distinct keypairs:

1. **Device Identity Key (Ed25519)**: For identity proofs, signaling signatures, and server authentication.
2. **Peer E2E Key (X25519)**: For application-layer E2E payload encryption (AES-256-GCM).
Keys must never be reused across functional boundaries and private keys must be stored in secure system keystores.

## Status
Accepted

## Consequences
- Prevents cross-protocol cryptographic attacks.
- Maintains backwards compatibility with existing LAN share key pinning.
