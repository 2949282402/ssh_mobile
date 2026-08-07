Last updated: 2026-08-07

# ADR-002: QUIC Transport Backend Selection

## Context
High-speed file transfer requires a robust QUIC transport implementation supporting multiplexed reliable streams, flow control, and loss recovery.

## Decision
We select **Quinn** as the only maintained QUIC backend for `network-quic`.

- **Primary Backend**: `Quinn` (pure Rust, seamless async Tokio integration)
- **Abstraction**: internal Rust ownership modules; no C QUIC wrapper

## Status
Accepted

## Consequences
- Unified Rust toolchain and Tokio async runtime integration with Quinn.
- One Rust/Tokio implementation keeps the v1 runtime and FFI behavior reviewable.
