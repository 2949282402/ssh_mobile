> Last updated: 2026-08-13

# Front Overview

`front/` is the standalone React, Vite, and TypeScript administration console
for the SSH Mobile control-plane and Relay service.

It owns browser presentation, administrator interactions, and client-side API
integration. It does not own authentication policy, device enrollment, Relay
sessions, wire protocols, or network SDK behavior; those belong to `relay/`
and the SDK domain.

Start with:

- the [Front README](../../front/README.md);
- the [Front package manifest](../../front/package.json);
- the [Backend overview](../backend/overview.md) when an API or authentication contract changes.

Administrator credentials, enrollment tokens, and sessions must not be stored
in browser storage or URLs. Use the Front README and code as the current-state
source rather than duplicating endpoint or polling details here.
