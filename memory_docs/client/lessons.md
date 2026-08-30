> Last updated: 2026-08-30

# Client Lessons

- `packages/infrastructure/ssh_core/` is Client infrastructure; directory
  location alone does not make a package SDK.
- App/Module/Route scopes have different owners. Release only the current
  scope's resources; Features release SSH leases, never shared Sessions/Manager.
- Provider selectors need stable identities (cached snapshots/revision counters);
  keep `ReorderableListView` keys on the builder's immediate child and memoize
  xterm styles/themes while inputs are unchanged.
- Keep large remote decoding, SFTP entry construction/sorting, and monitoring
  parsing off the UI isolate; assign only final state on it.
- Restore widget-test platform overrides in `try/finally`; edit generator inputs;
  do not use system text scaling for device-density fixes.
- Developer diagnostics cover instrumented owners only, not an exact legacy
  resource inventory. Persistence failures stay visible; in-memory repositories
  are test fakes, not runtime recovery.

Security-sensitive work also reads the
[security regression guide](../../docs/security_manual_regression.md).
