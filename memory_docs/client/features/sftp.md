> Last updated: 2026-08-24

# SFTP Feature Memory

## Ownership and state

`packages/features/feature_sftp/` owns the SFTP route UI, application state,
path-history/favorites repository, and `sftp.db`. `SftpModule` owns its
database, repository, and Feature service. Route Scope owns `SftpViewModel`.
The App-scoped SSH manager and compatibility SFTP backend are injected; the
Feature does not create or close them.

## Correctness and safety

- Directory retry distinguishes a live SFTP client from a closed session:
  refresh the current path when live, otherwise reconnect the selected server
  with host-key confirmation.
- Preview, edit, download, and tool reads are bounded during streaming before
  full allocation. A caller limit uses one sentinel byte to detect overflow.
- Explicit retry bypasses cache. An over-budget cache entry is invalidated
  before bounded remote fallback.
- Successful remote mutations invalidate the affected directory and encrypted
  file-cache entries before reloading metadata.
- Every directory entry carries the immutable target fingerprint captured when
  it was listed. Preview, edit, download, and delete resolve through that entry
  and fail closed if the same connection ID now refers to another target.
- Preview/download cache data is protected at rest. Secret-bearing paths such
  as SSH material, environment files, tokens, cloud credentials, and privileged
  system files are not cached.
- Remote preview content is untrusted. Markdown external content remains inert,
  HTML uses a deny-by-default policy without JavaScript or navigation, images
  obey byte/dimension/frame budgets, and PDF files are not parsed inline.
- SFTP diagnostics never emit remote/local paths, host details, or raw exception
  text. They retain only the operation, stable error code, non-sensitive counts,
  connection ID, and full SHA-256 path digests for correlation.

Path history and favorites are per server and belong to the Feature repository,
not the protocol backend. Credentials remain in secure storage outside `sftp.db`.

Canonical package and regression sources:

- [SFTP README](../../../packages/features/feature_sftp/README.md)
- [SFTP AGENTS](../../../packages/features/feature_sftp/AGENTS.md)
- [Security regression guide](../../../docs/security_manual_regression.md)
- [Performance acceptance](../../../docs/PERFORMANCE_ACCEPTANCE.md)
