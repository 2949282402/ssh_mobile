[CmdletBinding()]
param([string]$TempRoot = $env:SSH_MOBILE_WINDOWS_TEMP)
. (Join-Path $PSScriptRoot '..\common\powershell_common.ps1')
Assert-NativeWindowsPowerShell
$root = Get-RepositoryRoot
$temp = Initialize-NativeEnvironment $TempRoot
Assert-Commands @('go', 'npm')
$run = Join-Path $temp ("admin-contract-{0}" -f [Guid]::NewGuid().ToString('N'))
$fixture = Join-Path $run 'admin-api.json'
New-Item -ItemType Directory -Path $run -Force | Out-Null
try {
  $cache = if ($env:SSH_MOBILE_CONTRACT_GOCACHE) { $env:SSH_MOBILE_CONTRACT_GOCACHE } else { Join-Path $temp 'admin-contract-go-cache' }
  Invoke-CommandChecked go @('test', './internal/relay', '-run', '^TestExportAdminAPIContractFixture$', '-count=1') (Join-Path $root 'relay') @{ GOCACHE = $cache; SSH_MOBILE_ADMIN_CONTRACT_FIXTURE = $fixture }
  if (-not (Test-Path $fixture) -or (Get-Item $fixture).Length -eq 0) { throw 'Go administrator contract fixture was not produced.' }
  Invoke-CommandChecked npm @('run', 'test:run', '--', 'src/schemas/admin-contract.test.ts') (Join-Path $root 'front') @{ SSH_MOBILE_ADMIN_CONTRACT_FIXTURE = $fixture }
  Write-Host 'Front ↔ Relay administrator API contract passed.'
} finally {
  Remove-Item $run -Recurse -Force -ErrorAction SilentlyContinue
}
