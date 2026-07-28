# Test Environment Setup & Verification Matrix (Step 0.4)

## Target Platform & Environment Profiles

1. **Windows Nodes**: Windows 10/11 x64 target environment for native build hook and C cdylib.
2. **Android Nodes**: Android arm64-v8a target environment for native NDK cdylib.
3. **Network Topologies**:
   - LAN WiFi (Direct IPv4 / mDNS / QUIC Direct)
   - Mobile Hotspot / Cellular (NAT Traversal / UDP Hole Punching)
   - Public IPv6 Network (IPv6 Direct Probe)
   - Restricted NAT (Go Relay Fallback)

## Verification Matrix Setup
- Test scripts and network topology configurations prepared.
- Target Rust toolchain & Flutter native build hook validation ready.
