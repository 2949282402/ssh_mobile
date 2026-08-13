> Last updated: 2026-08-13

# Client Overview

The Client domain contains the Flutter applications and their application,
Core, Feature, and SSH infrastructure:

- `apps/ssh_mobile_full/`: the complete product application and composition root;
- `apps/ssh_mobile_terminal/`: the restricted Terminal-only runtime slice;
- `packages/core/`: shared contracts, UI, and Connection ownership;
- `packages/features/`: maintained Feature implementations;
- `packages/infrastructure/ssh_core/`: App-scoped SSH contracts and runtime boundary.

Network SDK internals belong to the [SDK domain](../sdk/overview.md). The Go
Relay and React administration console belong to the Backend and Front domains.

For package-scoped work, read the nearest `AGENTS.md` and the Workspace Member
`README.md`. Those files are the local edit and public-package contracts; this
Memory supplies only cross-package knowledge that is expensive to rediscover.
The root [README](../../README.md) remains the user-facing source for setup,
configuration, and product behavior.
