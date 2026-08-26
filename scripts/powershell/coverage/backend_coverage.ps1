[CmdletBinding()]
param([string]$Minimum = $env:BACKEND_COVERAGE_MINIMUM, [string]$TempRoot = $env:SSH_MOBILE_WINDOWS_TEMP)
. (Join-Path $PSScriptRoot '..\common\powershell_common.ps1')
Assert-NativeWindowsPowerShell
$root = Get-RepositoryRoot
$temp = Initialize-NativeEnvironment $TempRoot
if (-not $Minimum) { $Minimum = '80' }
if ($Minimum -notmatch '^[0-9]+(?:\.[0-9]+)?$') { [Console]::Error.WriteLine("BACKEND_COVERAGE_MINIMUM must be numeric: $Minimum"); exit 64 }
Assert-Commands @('go')
$runId = [Guid]::NewGuid().ToString('N')
$run = Join-Path $temp "backend-coverage-$runId"
New-Item -ItemType Directory $run | Out-Null
$mysql = "ssh-mobile-backend-mysql-$runId"
$redis = "ssh-mobile-backend-redis-$runId"
$started = $false
try {
  $dsn = $env:RELAY_TEST_MYSQL_DSN
  $redisUrl = $env:RELAY_TEST_REDIS_URL
  if (-not $dsn -or -not $redisUrl) {
    Assert-Commands @('docker')
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine('Docker daemon is required unless Relay test endpoints are provided.'); exit 69 }
    Invoke-CommandChecked docker @('run','-d','--rm','--name',$mysql,'-p','127.0.0.1::3306','-e','MYSQL_ROOT_PASSWORD=root','-e','MYSQL_DATABASE=relay','-e','MYSQL_USER=relay','-e','MYSQL_PASSWORD=relay','mysql:8.4')
    $started = $true
    Invoke-CommandChecked docker @('run','-d','--rm','--name',$redis,'-p','127.0.0.1::6379','redis:7-alpine')
    $mysqlPort = ((& docker port $mysql '3306/tcp' | Select-Object -First 1) -replace '^.*:','')
    $redisPort = ((& docker port $redis '6379/tcp' | Select-Object -First 1) -replace '^.*:','')
    $ready = $false
    foreach ($i in 1..60) { & docker exec $mysql mysqladmin ping -h 127.0.0.1 -urelay -prelay *> $null; if ($LASTEXITCODE -eq 0) { $ready=$true; break }; Start-Sleep 2 }
    if (-not $ready) { throw 'MySQL did not become ready.' }
    $ready = $false
    foreach ($i in 1..30) { if (((& docker exec $redis redis-cli ping 2>$null | Out-String).Trim()) -eq 'PONG') { $ready=$true; break }; Start-Sleep 2 }
    if (-not $ready) { throw 'Redis did not become ready.' }
    $dsn="relay:relay@tcp(127.0.0.1:$mysqlPort)/relay?parseTime=true&loc=UTC"
    $redisUrl="redis://127.0.0.1:$redisPort/0"
  }
  $raw=Join-Path $run 'raw.out'
  $filtered=Join-Path $run 'filtered.out'
  $relayDir=Join-Path $root 'relay'
  Invoke-CommandChecked go @('test','./...','-count=1','-covermode=atomic',"-coverprofile=$raw") $relayDir @{ RELAY_TEST_MYSQL_DSN=$dsn; RELAY_TEST_REDIS_URL=$redisUrl }
  $lines=Get-Content $raw
  @($lines[0]) + @($lines | Select-Object -Skip 1 | Where-Object { $_ -notmatch '/relay_v2\.pb\.go:|/cmd/relay/main\.go:' }) | Set-Content $filtered -Encoding utf8NoBOM
  $summary=& go tool cover "-func=$filtered"
  $summary | Write-Host
  $totalLine=$summary | Where-Object { $_ -match '^total:' } | Select-Object -Last 1
  if ($totalLine -notmatch '([0-9]+(?:\.[0-9]+)?)%\s*$') { throw 'Unable to read Go coverage total.' }
  $total=[double]$Matches[1]
  if ($total -lt [double]$Minimum) { throw "Backend coverage is below $Minimum%." }
  Write-Host "Backend coverage gate passed at $total%."
} finally {
  if ($started) { & docker rm -f $mysql $redis *> $null }
  Remove-Item $run -Recurse -Force -ErrorAction SilentlyContinue
}
