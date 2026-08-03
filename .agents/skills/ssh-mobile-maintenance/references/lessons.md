# SSH Mobile Regression Notes

> 最新更新时间：2026-07-29

Read this file only when debugging a matching regression. Keep general rules in
`AGENTS.md`, current decisions in `AGENT_MEMORY.md`, and expected behavior in
code/tests.

## Protocol and data

- Encode OpenAI-compatible JSON request bodies as UTF-8 bytes. Streaming parsers
  must tolerate split tool-call deltas and providers that emit a usage-only
  chunk before `[DONE]`.
- Preserve provider-required `reasoning_content` across tool rounds, but keep
  hidden reasoning out of future model context and redact persisted traces.
- Bound SFTP reads while streaming, before full allocation. On retry, reconnect
  a closed session but refresh the current directory when the session is live.

## Flutter state and rendering

- Provider selectors only reduce rebuilds when selected objects have stable
  identity. Prefer cached snapshots or revision counters over allocating lists
  or scanning large collections in selectors.
- Keep the stable key on the immediate child returned by
  `ReorderableListView.builder`.
- Memoize xterm `TerminalStyle` and `TerminalTheme` objects for unchanged
  settings; new identities invalidate renderer caches.
- In widget tests, restore debug platform overrides inside the `testWidgets`
  body with `try/finally`; the binding invariant check can run before global
  teardown.

## Platform diagnostics

- `INSTALL_FAILED_USER_RESTRICTED` after a successful Android build means the
  device blocked or canceled installation; it is not a Gradle compile failure.
- Keep Android release cleartext traffic disabled. Debug/profile overrides are
  only for local provider testing.
- Rewrite mojibake documentation as clean UTF-8 rather than patching corrupted
  byte sequences.
