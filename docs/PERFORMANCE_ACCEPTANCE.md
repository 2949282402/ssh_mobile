# Performance Acceptance Scenarios

> 最新更新时间：2026-07-26

Use these scenarios before and after changes that touch rendering, storage,
SSH/SFTP, AI streaming, or monitoring. Record device/emulator, build mode,
commit, and observed regressions.

## Terminal Large Output

- Run a command that prints at least 100k lines or several megabytes of text.
- Verify the terminal remains responsive while output is arriving.
- Verify scrolling history, font-size changes, selection/copy, and shortcut bar
  actions still work.
- Watch for frame jank, memory growth, and delayed encrypted history writes.
- Delay history loading while more than 200,000 characters arrive. Verify the
  newest tail remains visible, the prefix is evicted, and memory stays bounded.
- Migrate a large legacy plaintext history. Verify encryption is chunked, the
  original survives an injected failure, and only a complete replacement is
  published.

## AI Long Streaming Reply

- Ask for a long Markdown response with code blocks and tables.
- Verify partial text updates are batched, the current assistant bubble shows a
  running indicator before first token, and stop/cancel saves partial output.
- Verify context-token display does not update on every streamed chunk.

## SFTP Large Directory

- Open a directory with hundreds or thousands of entries.
- Verify connect, refresh, upload, download, delete confirmation, preview, and
  edit actions do not rebuild the whole page unnecessarily.
- Confirm large downloads respect the normal download cap while preview/edit
  limits remain protective.

## Multi-Server Monitor

- Start performance sampling for several servers.
- Verify sampling starts only after the user taps Start, selected servers stay
  frozen for the run, and failures back off without noisy banners.
- Stop and immediately restart against an edited target while an old probe is
  pending. Verify late success/error/retry from the old epoch is discarded and
  every command in the new run uses its captured target binding.
- Check charts, disk sections, ports, and applications tabs for rebuild jank and
  refresh-button disabled states.

## Suggested Metrics

- Flutter DevTools frame chart: no sustained frame build/raster spikes during
  steady-state streaming or sampling.
- Memory: no unbounded growth after five minutes of terminal output or monitor
  sampling.
- Logs: no high-frequency debug lines bypass `AppLogService`.
- Background: SSH/tmux sessions survive app backgrounding according to platform
  policy and configured keep-alive settings.
