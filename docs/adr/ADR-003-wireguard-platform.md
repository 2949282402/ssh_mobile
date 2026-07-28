# ADR-003: WireGuard Platform Integration Strategy

## Context
WireGuard virtual networking is needed for RDP, SSH, SMB, and custom IP-level access across devices.

## Decision
We leverage **official native platform components** for WireGuard driver/service execution rather than custom WireGuard crypto in application code.

- **Windows**: Embeddable DLL Service / WireGuardNT
- **Android**: `com.wireguard.android:tunnel` Android VpnService library
- **Apple**: WireGuardKit
- **Rust Orchestrator**: `network-wireguard` crate manages configuration, desired tunnel state, and routing rules while delegating actual adapter control to platform layers.

## Status
Accepted

## Consequences
- Maximizes performance, security, and OS-level VPN integration.
- Platform-specific binding required for adapter management.
