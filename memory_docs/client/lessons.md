> Last updated: 2026-08-13

# Client Lessons

- A directory under `packages/infrastructure/` is not automatically part of the
  Network SDK domain. `ssh_core` is Client infrastructure.
- App Scope, Module Scope, and Route Scope have different owners. Dispose only
  resources owned by the current scope.
- A Feature releases an SSH lease; it does not close a shared Session or the
  App-owned SSH manager.
- Provider selectors reduce rebuilds only when selected values have stable
  identity. Prefer cached snapshots or revision counters over allocating lists
  or scanning large collections during selection.
- Large remote-output decoding, SFTP entry construction/sorting, and monitoring
  parsing stay off the UI isolate; only final state assignment belongs on it.
- In widget tests, restore debug platform overrides inside the `testWidgets`
  body with `try/finally`; binding invariant checks can run before global teardown.
- Edit generator inputs instead of generated files, and never scale the user's
  system text setting as part of device-density correction.
- Developer diagnostics report instrumented owners only; they are not an exact
  inventory of uninstrumented legacy resources.
- Production persistence failures remain visible. In-memory repositories are
  test fakes, not runtime recovery behavior.

Security-sensitive work must also read the
[security regression guide](../../docs/security_manual_regression.md).
