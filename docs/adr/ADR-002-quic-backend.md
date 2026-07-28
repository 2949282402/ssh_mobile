# ADR-002: QUIC Transport Backend Selection

## Context
High-speed file transfer requires a robust QUIC transport implementation supporting multiplexed reliable streams, flow control, and loss recovery.

## Decision
We select **Quinn** as the primary QUIC backend for `network-quic`, encapsulated behind a generic `QuicBackend` trait interface.

- **Primary Backend**: `Quinn` (pure Rust, seamless async Tokio integration)
- **Abstraction**: `pub trait QuicBackend`
- **Future Backends**: `MsQuic` (via C bindings if needed)

## Status
Accepted

## Consequences
- Unified Rust toolchain and Tokio async runtime integration with Quinn.
- Flexibility to swap or benchmark alternative backends without breaking caller code.
