> Last updated: 2026-08-13

# Project Memory

This directory contains concise, current repository knowledge for maintenance
agents. It is not a changelog, an architecture specification, or a test report.

Load only the domains selected by the
[Memory Map](../.agents/skills/ssh-mobile-maintenance/references/memory-map.md):

- `client/`: Flutter Apps, Core and Feature packages, and SSH client infrastructure;
- `sdk/`: Dart network contracts, native bindings, the Rust network runtime, and wire protocol;
- `backend/`: the Go control plane and Relay;
- `front/`: the React administration console.

Detailed decisions remain in [`docs/adr/`](../docs/adr/), complete designs remain
in [`docs/architecture/`](../docs/architecture/) and focused project documents,
and current behavior remains authoritative in code and tests.

Maintenance rules are defined by
[Skill & Memory Maintenance](../docs/agent/skill-memory-maintenance.md).
