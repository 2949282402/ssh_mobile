> Last updated: 2026-08-25

# Repository scripts

Agents choose the tree matching the actual host:

- `bash/` for Linux and WSL;
- `powershell/` for native Windows PowerShell 7.

Both trees use the same functional layout: `ci`, `coverage`, `contracts`,
`e2e`, `terminal`, `platform`, and `common`. A `.sh` and `.ps1` at the same
relative path and with the same base name form one maintenance unit. Update
their parameters, environment variables, steps, timeouts, cleanup, exit
semantics, and validation scope together.

`powershell/platform/` contains Windows-only toolchain and MSI packaging tasks,
and `powershell/common/` contains the shared native-process runtime. Their Bash
directories are intentionally documentation-only until Linux-specific
counterparts are needed.
