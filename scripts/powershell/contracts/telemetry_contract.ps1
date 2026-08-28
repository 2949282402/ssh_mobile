[CmdletBinding()]
param([string]$TempRoot = $env:SSH_MOBILE_WINDOWS_TEMP)
. (Join-Path $PSScriptRoot '..\common\powershell_common.ps1')
Assert-NativeWindowsPowerShell
$root = Get-RepositoryRoot
$temp = Initialize-NativeEnvironment $TempRoot
Assert-Commands @('dart', 'go', 'npm', 'flutter')

Write-Host "Validating Telemetry contracts..."

# 1. Regenerate contract artifacts from the YAML source of truth, then verify
#    byte-for-byte that the generated artifacts are fresh (no drift).
Invoke-CommandChecked dart @('run', 'tool/gen_telemetry_contract.dart') $root
Invoke-CommandChecked dart @('run', 'tool/check_telemetry_contract_generated.dart') $root
Invoke-CommandChecked dart @('run', 'tool/check_telemetry_producers.dart') $root
Invoke-CommandChecked dart @('run', 'test/tool/telemetry_producer_ban_test.dart') $root

# 2. Go validation
Invoke-CommandChecked go @('test', './tests/telemetry', '-run', '^TestTelemetryContract', '-count=1') (Join-Path $root 'relay')

# 3. TypeScript / Front validation
Invoke-CommandChecked npm @('run', 'test:run', '--', 'tests/telemetry/telemetry-contract.test.ts') (Join-Path $root 'front')

# 4. Dart validation
Invoke-CommandChecked flutter @('test', '--no-pub', 'packages/core/app_core/test/telemetry_contract_test.dart') $root

Write-Host "Telemetry Contract validation passed."
