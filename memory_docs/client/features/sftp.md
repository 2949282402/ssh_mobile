> Last updated: 2026-08-30

# SFTP Feature Memory

`packages/features/feature_sftp/` owns route UI/state, path history/favorites,
repository, Feature service, and `sftp.db`. `SftpModule` owns DB/repository;
Route Scope owns `SftpViewModel`. App-scoped SSH manager and compatibility SFTP
backend are injected and never created/closed by the Feature.

Correctness and safety:

- Directory retry refreshes a live SFTP client; a closed session reconnects the
  selected server with host-key confirmation. Explicit retry bypasses cache;
  over-budget entries are invalidated before bounded fallback.
- Preview/edit/download/tool reads stream with a caller limit plus one sentinel
  byte; mutations invalidate affected directory and encrypted file-cache entries
  before reload. Entries carry an immutable target fingerprint; operations fail
  closed when a connection ID points at another target.
- Preview/download cache is encrypted at rest and excludes SSH material,
  environment files, tokens, cloud credentials, and privileged system files.
  Remote content is untrusted: Markdown external content is inert, HTML is
  deny-by-default (no JS/navigation), images obey byte/dimension/frame budgets,
  and PDFs are not parsed inline.
- Diagnostics retain only operation, stable error code, non-sensitive counts,
  connection ID, and full SHA-256 path digests—never remote/local paths, host
  details, or raw exceptions. History/favorites are per-server Feature data;
  credentials remain outside `sftp.db` in secure storage.

Contracts: [SFTP README](../../../packages/features/feature_sftp/README.md),
[SFTP AGENTS](../../../packages/features/feature_sftp/AGENTS.md),
[security regression](../../../docs/security_manual_regression.md), and
[performance acceptance](../../../docs/PERFORMANCE_ACCEPTANCE.md).
