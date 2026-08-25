> Last updated: 2026-08-25

# Client Architecture

The Full App composition root is `apps/ssh_mobile_full/lib/app/`.
`AppRuntimeFactory` creates App-scoped resources, `AppRuntime` owns their
lifecycle, and Feature route scopes create and dispose route-scoped ViewModels.

For Network V2, the composition root loads the App-owned Ed25519/X25519
identity bundle, creates/configures one `NetworkRuntime` exactly once per App
process, and creates the shared `NetworkFacade`. LAN, SSH, SFTP, Realtime and
Relay borrow that runtime. Feature activation/deactivation can release its
subscriptions and HTTP/Discovery/Transfer resources but cannot stop, destroy,
or reconfigure the runtime or Facade.

Stable boundaries:

- Core packages own cross-feature contracts and shared UI/data foundations.
- Feature packages own their presentation, application logic, repositories,
  and Feature databases.
- App Shell adapters inject Ports and join Features to App-scoped resources.
- Features do not import another Feature implementation or another package's `/src/`.
- Shared SSH sessions are acquired through leases; Features release leases and
  do not close the App-owned manager.
- Growing structured data stays in the owning Feature/Core database. App
  diagnostics alone use the App-owned log database.
- Passwords, private keys, API keys, and tokens stay in platform secure storage.
- LAN Control V2 state is split into Trust, Discovery, Reachability, Route and
  Relay Enrollment/Authorization; the durable peer Trust Record is not the
  dynamic Discovery device model. Explicit `removePeer` is reserved for
  trust revoke/unpair.

Full designs and maintained audits:

- [Modular refactor plan](../../docs/architecture/MODULAR_REFACTOR_PLAN.md)
- [Module dependency audit](../../docs/architecture/MODULE_DEPENDENCY.md)
- [Resource ownership audit](../../docs/architecture/RESOURCE_OWNERSHIP.md)
- [Compatibility migration inventory](../../docs/architecture/COMPATIBILITY_MIGRATION_INVENTORY.md)
