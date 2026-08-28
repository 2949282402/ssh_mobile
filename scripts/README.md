> Last updated: 2026-08-28

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

The native network quality pair runs the common Rust format, workspace-test,
and Clippy gates on both platforms. Its coturn host-network fallback test is a
Linux-only capability: the PowerShell aggregate reports that step as an explicit
environment GAP after completing the common checks.

The CI aggregate entrypoints are intentionally thin dispatchers:
`ci/full_test.sh` and `ci/full_test.ps1` load paired configuration, runtime,
runner, App, and workspace/service helper modules. Each helper stays below the
500-line review limit by keeping functional and responsibility boundaries
cohesive; mechanically numbered chunks (`part_01`, `file_01`) and gratuitous
over-splitting are prohibited. The helpers preserve the same job names,
arguments, timeout behavior, cleanup, and exit statuses across hosts. The
GitHub Actions workflow is the authoritative full gate; use
`bash scripts/bash/ci/full_test.sh` for the proportional Linux/WSL checks
available on a local host.
