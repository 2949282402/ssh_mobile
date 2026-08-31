[CmdletBinding()]
param(
  [ValidateSet('full')][string]$Mode = 'full',
  [string]$TempRoot = $env:SSH_MOBILE_WINDOWS_TEMP
)

# External-deployment online E2E. This is the PowerShell counterpart of
# scripts/bash/e2e/online_e2e.sh; it never starts Compose and is never called by
# the normal CI aggregate.
. (Join-Path $PSScriptRoot '..\common\powershell_common.ps1')
Assert-NativeWindowsPowerShell
$root = Get-RepositoryRoot
$temp = Initialize-NativeEnvironment $TempRoot
Assert-Commands @('curl.exe', 'go', 'cargo', 'flutter', 'pwsh') 125

$base = if ($env:ONLINE_E2E_BASE_URL) { $env:ONLINE_E2E_BASE_URL } else { $env:CLIENT_BACKEND_E2E_BASE_URL }
$token = $env:RELAY_ENROLLMENT_TOKEN
$adminUser = if ($env:ONLINE_E2E_ADMIN_USER) { $env:ONLINE_E2E_ADMIN_USER } else { $env:CLIENT_BACKEND_E2E_ADMIN_USER }
$adminPassword = if ($env:ONLINE_E2E_ADMIN_PASSWORD) { $env:ONLINE_E2E_ADMIN_PASSWORD } else { $env:CLIENT_BACKEND_E2E_ADMIN_PASSWORD }
$caFile = if ($env:ONLINE_E2E_CA_FILE) { $env:ONLINE_E2E_CA_FILE } else { $env:CLIENT_BACKEND_E2E_CA_FILE }
$runId = if ($env:ONLINE_E2E_RUN_ID) { $env:ONLINE_E2E_RUN_ID } else { '{0}-{1}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'), $PID }
$goTimeout = if ($env:ONLINE_E2E_GO_TIMEOUT) { $env:ONLINE_E2E_GO_TIMEOUT } else { '10m' }

if ($Mode -ne 'full') { throw 'Usage: set ONLINE_E2E_CONFIRM=RUN and invoke online_e2e.ps1 full.' }
if ($env:ONLINE_E2E_CONFIRM -ne 'RUN') { throw 'Refusing online-e2e: set ONLINE_E2E_CONFIRM=RUN to authorize test data writes.' }
if (-not $base -or -not $token -or -not $adminUser -or -not $adminPassword) {
  [Console]::Error.WriteLine('ONLINE_E2E_BASE_URL, RELAY_ENROLLMENT_TOKEN, ONLINE_E2E_ADMIN_USER, and ONLINE_E2E_ADMIN_PASSWORD are required.')
  exit 64
}
if ($runId -notmatch '^[A-Za-z0-9_-]{1,24}$') {
  throw 'ONLINE_E2E_RUN_ID must contain only ASCII letters, digits, "_" or "-" and be at most 24 characters.'
}
$prefix = "online-e2e-$runId-"
$baseUri = $null
if (-not [Uri]::TryCreate($base, [UriKind]::Absolute, [ref]$baseUri) -or $baseUri.Scheme -notin @('http', 'https')) {
  throw 'ONLINE_E2E_BASE_URL must be an absolute http(s) URL.'
}
if ($baseUri.AbsolutePath -notin @('', '/') -or $baseUri.Query -or $baseUri.Fragment -or $baseUri.UserInfo) {
  throw 'ONLINE_E2E_BASE_URL must be an origin URL without a path, query, fragment, or credentials.'
}
$base = $base.TrimEnd('/')
if ($baseUri.Host -in @('127.0.0.1', 'localhost', '::1') -and $env:ONLINE_E2E_ALLOW_LOCAL -ne '1') {
  throw 'Refusing loopback target; set ONLINE_E2E_ALLOW_LOCAL=1 only for an explicitly isolated deployment.'
}
if ($caFile) {
  if (-not (Test-Path -LiteralPath $caFile -PathType Leaf)) { throw 'ONLINE_E2E_CA_FILE is not readable.' }
  $caFile = (Resolve-Path -LiteralPath $caFile).ProviderPath
}

$run = Join-Path $temp ("online-e2e-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run -Force | Out-Null
$clientTemp = Join-Path $run 'client-backend'
New-Item -ItemType Directory -Path $clientTemp -Force | Out-Null
$cookie = Join-Path $run 'admin-cookie'
$loginBody = Join-Path $run 'admin-login.json'
$devicesBody = Join-Path $run 'devices.json'

function TlsArgs {
  if ($caFile) { @('--cacert', $caFile) } else { @() }
}
function CurlStatus([string[]]$Arguments) {
  ((& curl.exe @Arguments 2>$null | Out-String).Trim())
}

function Cleanup-TestDevices {
  $status = 0
  @{ username = $adminUser; password = $adminPassword } | ConvertTo-Json -Compress | Set-Content -LiteralPath $loginBody -Encoding utf8NoBOM
  $loginStatus = CurlStatus ((TlsArgs) + @('-sS', '--max-time', '10', '-H', 'Content-Type: application/json', '-c', $cookie, '--data-binary', "@$loginBody", '-o', 'NUL', '-w', '%{http_code}', "$($base.TrimEnd('/'))/api/admin/v1/auth/login"))
  if ($loginStatus -ne '200') {
    [Console]::Error.WriteLine("CLEANUP GAP: administrator login returned HTTP $loginStatus; test devices may remain enrolled.")
    return $false
  }
  $devicesStatus = CurlStatus ((TlsArgs) + @('-sS', '--max-time', '10', '-b', $cookie, '-o', $devicesBody, '-w', '%{http_code}', "$($base.TrimEnd('/'))/api/admin/v1/devices"))
  if ($devicesStatus -ne '200') {
    [Console]::Error.WriteLine("CLEANUP GAP: device listing returned HTTP $devicesStatus; test devices may remain enrolled.")
    return $false
  }
  try { $payload = Get-Content -LiteralPath $devicesBody -Raw | ConvertFrom-Json } catch {
    [Console]::Error.WriteLine('CLEANUP GAP: device listing was not valid JSON; test devices may remain enrolled.')
    return $false
  }
  if ($null -eq $payload.items -or $payload.items -is [string]) {
    [Console]::Error.WriteLine('CLEANUP GAP: device listing omitted an items array; test devices may remain enrolled.')
    return $false
  }
  foreach ($item in @($payload.items)) {
    if ($item.device_id -is [string] -and $item.device_id.StartsWith($prefix, [StringComparison]::Ordinal)) {
      $revokeStatus = CurlStatus ((TlsArgs) + @('-sS', '--max-time', '10', '-b', $cookie, '-X', 'POST', '-o', 'NUL', '-w', '%{http_code}', "$($base.TrimEnd('/'))/api/admin/v1/devices/$($item.device_id)/revoke"))
      if ($revokeStatus -notin @('204', '404')) {
        [Console]::Error.WriteLine("CLEANUP GAP: revoking a test device returned HTTP $revokeStatus.")
        $status = 1
      }
    }
  }
  $logoutStatus = CurlStatus ((TlsArgs) + @('-sS', '--max-time', '10', '-b', $cookie, '-X', 'POST', '-o', 'NUL', '-w', '%{http_code}', "$($base.TrimEnd('/'))/api/admin/v1/auth/logout"))
  if ($logoutStatus -ne '204') {
    [Console]::Error.WriteLine("CLEANUP GAP: administrator logout returned HTTP $logoutStatus.")
    $status = 1
  }
  return ($status -eq 0)
}

$old = @{}
$completed = $false
$environment = @{
  CLIENT_BACKEND_E2E_BASE_URL = $base
  RELAY_ENROLLMENT_TOKEN = $token
  CLIENT_BACKEND_E2E_ADMIN_USER = $adminUser
  CLIENT_BACKEND_E2E_ADMIN_PASSWORD = $adminPassword
  CLIENT_BACKEND_E2E_DEVICE_PREFIX = $prefix
  CLIENT_BACKEND_E2E_REVOCATION_DEVICE_ID = $prefix + 'e2e-rust-revoke-a'
  CLIENT_BACKEND_E2E_ONLINE = '1'
  ONLINE_E2E_BASE_URL = $base
  ONLINE_E2E_ADMIN_USER = $adminUser
  ONLINE_E2E_ADMIN_PASSWORD = $adminPassword
  ONLINE_E2E_RUN_ID = $runId
}
if ($caFile) { $environment.CLIENT_BACKEND_E2E_CA_FILE = $caFile }
foreach ($entry in $environment.GetEnumerator()) {
  $old[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
  [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
}

try {
  Write-Host "Online E2E target: $base"
  Write-Host "Online E2E run id: $runId"
  $goCache = Join-Path $run 'go-cache'
  Invoke-CommandChecked go @('test', '-tags', 'online_e2e', './tests/online_e2e', '-count=1', '-timeout', $goTimeout) (Join-Path $root 'relay') @{ GOCACHE = $goCache }
  Invoke-CommandChecked pwsh @('-NoProfile', '-File', (Join-Path $root 'scripts\powershell\e2e\client_backend_e2e.ps1'), '-Mode', 'strict', '-TempRoot', $clientTemp) $root
  Write-Host "ONLINE_E2E_PASS run_id=$runId"
  $completed = $true
}
finally {
  $cleanupOk = Cleanup-TestDevices
  foreach ($entry in $old.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
  }
  Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
  if ($completed -and -not $cleanupOk) {
    throw 'online-e2e cleanup did not revoke every test device.'
  }
}
