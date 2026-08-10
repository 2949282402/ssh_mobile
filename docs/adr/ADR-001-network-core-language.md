> Last updated: 2026-08-10

# ADR-001: Network Core Implementation Language

## Context
The SSH Mobile application requires a high-performance, cross-platform network engine supporting P2P connections, QUIC file transfers, and NAT traversal across Windows, Android, iOS, and macOS.

## Decision
We choose **Rust** to implement the cross-platform client network core (`network_core`).

- **UI & Application State**: Flutter / Dart
- **Client Network Core**: Rust (with Tokio async runtime)
- **Control Plane Server & Relay**: Go
- **FFI Boundary**: C ABI exposed by Rust cdylib (`network-ffi`)

## Status
Accepted

## Consequences
- Single codebase for complex networking, cryptographic operations, and protocol state machines.
- High memory safety and performance without garbage collection pauses.
- Requires maintenance of FFI bindings between Dart and Rust.
