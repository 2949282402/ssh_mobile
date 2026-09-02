[CmdletBinding()]
param([string]$Minimum = $env:BACKEND_COVERAGE_MINIMUM, [string]$TempRoot = $env:SSH_MOBILE_WINDOWS_TEMP)
. (Join-Path $PSScriptRoot '..\common\powershell_common.ps1')
Assert-NativeWindowsPowerShell
$root = Get-RepositoryRoot
$temp = Initialize-NativeEnvironment $TempRoot
if (-not $Minimum) { $Minimum = '90' }
if ($Minimum -notmatch '^[0-9]+(?:\.[0-9]+)?$') { [Console]::Error.WriteLine("BACKEND_COVERAGE_MINIMUM must be numeric: $Minimum"); exit 64 }
$telemetryMinimum = if ($env:BACKEND_TELEMETRY_COVERAGE_MINIMUM) { $env:BACKEND_TELEMETRY_COVERAGE_MINIMUM } else { $Minimum }
if ($telemetryMinimum -notmatch '^[0-9]+(?:\.[0-9]+)?$') { [Console]::Error.WriteLine("BACKEND_TELEMETRY_COVERAGE_MINIMUM must be numeric: $telemetryMinimum"); exit 64 }
Write-Host "Backend coverage threshold: $Minimum%"
Write-Host "Telemetry coverage threshold: $telemetryMinimum%"
Assert-Commands @('go')
$runId = [Guid]::NewGuid().ToString('N')
$run = Join-Path $temp "backend-coverage-$runId"
New-Item -ItemType Directory $run | Out-Null
$mysql = "ssh-mobile-backend-mysql-$runId"
$redis = "ssh-mobile-backend-redis-$runId"
$analyticsMysql = "ssh-mobile-backend-analytics-mysql-$runId"
$analyticsRedis = "ssh-mobile-backend-analytics-redis-$runId"
$started = $false
try {
  $dsn = $env:RELAY_TEST_MYSQL_DSN
  $redisUrl = $env:RELAY_TEST_REDIS_URL
  $telemetryDsn = if ($env:TELEMETRY_TEST_MYSQL_DSN) { $env:TELEMETRY_TEST_MYSQL_DSN } else { $env:TELEMETRY_MYSQL_DSN }
  $telemetryRedisUrl = if ($env:TELEMETRY_TEST_REDIS_URL) { $env:TELEMETRY_TEST_REDIS_URL } else { $env:TELEMETRY_REDIS_URL }
  if (-not $dsn -or -not $redisUrl -or -not $telemetryDsn -or -not $telemetryRedisUrl) {
    Assert-Commands @('docker')
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine('Docker daemon is required unless Relay and telemetry test endpoints are provided.'); exit 69 }
    if (-not $dsn) {
      Invoke-CommandChecked docker @('run','-d','--rm','--name',$mysql,'-p','127.0.0.1::3306','-e','MYSQL_ROOT_PASSWORD=root','-e','MYSQL_DATABASE=relay','-e','MYSQL_USER=relay','-e','MYSQL_PASSWORD=relay','mysql:8.4@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb');$started=$true
      $mysqlPort = ((& docker port $mysql '3306/tcp' | Select-Object -First 1) -replace '^.*:','');$ready=$false
      foreach ($i in 1..60) { & docker exec $mysql mysqladmin ping -h 127.0.0.1 -urelay -prelay *> $null; if ($LASTEXITCODE -eq 0) { $ready=$true; break }; Start-Sleep 2 }
      if (-not $ready) { throw 'Relay MySQL did not become ready.' };$dsn="relay:relay@tcp(127.0.0.1:$mysqlPort)/relay?parseTime=true&loc=UTC"
    }
    if (-not $redisUrl) {
      Invoke-CommandChecked docker @('run','-d','--rm','--name',$redis,'-p','127.0.0.1::6379','redis:7-alpine@sha256:ff02b58f971e7d7d156a1267e283fcbbeee91773b6aa36c49dac28ecfe28eadf');$started=$true
      $redisPort = ((& docker port $redis '6379/tcp' | Select-Object -First 1) -replace '^.*:','');$ready=$false
      foreach ($i in 1..30) { if (((& docker exec $redis redis-cli ping 2>$null | Out-String).Trim()) -eq 'PONG') { $ready=$true; break }; Start-Sleep 2 }
      if (-not $ready) { throw 'Relay Redis did not become ready.' };$redisUrl="redis://127.0.0.1:$redisPort/0"
    }
    $analyticsMysqlPassword=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant();$analyticsMysqlRootPassword=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant();$analyticsRedisPassword=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
    if (-not $telemetryDsn) {
      Invoke-CommandChecked docker @('run','-d','--rm','--name',$analyticsMysql,'-p','127.0.0.1::3306','-e',"MYSQL_ROOT_PASSWORD=$analyticsMysqlRootPassword",'-e','MYSQL_DATABASE=telemetry','-e','MYSQL_USER=telemetry','-e',"MYSQL_PASSWORD=$analyticsMysqlPassword",'mysql:8.4@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb');$started=$true
      $analyticsMysqlPort = ((& docker port $analyticsMysql '3306/tcp' | Select-Object -First 1) -replace '^.*:','');$ready=$false
      foreach ($i in 1..60) { & docker exec $analyticsMysql mysqladmin ping -h 127.0.0.1 -utelemetry -p$analyticsMysqlPassword *> $null; if ($LASTEXITCODE -eq 0) { $ready=$true; break }; Start-Sleep 2 }
      if (-not $ready) { throw 'Analytics MySQL did not become ready.' };$telemetryDsn="telemetry:$analyticsMysqlPassword@tcp(127.0.0.1:$analyticsMysqlPort)/telemetry?parseTime=true&loc=UTC"
    }
    if (-not $telemetryRedisUrl) {
      Invoke-CommandChecked docker @('run','-d','--rm','--name',$analyticsRedis,'-p','127.0.0.1::6379','-e',"ANALYTICS_REDIS_PASSWORD=$analyticsRedisPassword",'redis:7-alpine@sha256:ff02b58f971e7d7d156a1267e283fcbbeee91773b6aa36c49dac28ecfe28eadf','sh','-ec','exec redis-server --maxmemory 64mb --maxmemory-policy noeviction --requirepass "$ANALYTICS_REDIS_PASSWORD"');$started=$true
      $analyticsRedisPort = ((& docker port $analyticsRedis '6379/tcp' | Select-Object -First 1) -replace '^.*:','');$ready=$false
      foreach ($i in 1..30) { if (((& docker exec $analyticsRedis redis-cli -a $analyticsRedisPassword --no-auth-warning ping 2>$null | Out-String).Trim()) -eq 'PONG') { $ready=$true; break }; Start-Sleep 2 }
      if (-not $ready) { throw 'Analytics Redis did not become ready.' };$telemetryRedisUrl="redis://:$analyticsRedisPassword@127.0.0.1:$analyticsRedisPort/0"
    }
  }
  $raw=Join-Path $run 'raw.out'
  $filtered=Join-Path $run 'filtered.out'
  $relayDir=Join-Path $root 'relay'
  Push-Location $relayDir
  try { $coverPackages=((& go list './internal/...' './cmd/...') -join ',').Trim();if($LASTEXITCODE-ne0){throw'go list failed while enumerating Relay production packages.'} } finally { Pop-Location }
  if (-not $coverPackages) { throw 'Unable to enumerate Relay production packages for coverage.' }
  Invoke-CommandChecked go @('test','./...','-count=1','-covermode=atomic',"-coverpkg=$coverPackages","-coverprofile=$raw") $relayDir @{ RELAY_TEST_MYSQL_DSN=$dsn; RELAY_TEST_REDIS_URL=$redisUrl; TELEMETRY_TEST_MYSQL_DSN=$telemetryDsn; TELEMETRY_MYSQL_DSN=$telemetryDsn; TELEMETRY_TEST_REDIS_URL=$telemetryRedisUrl; TELEMETRY_REDIS_URL=$telemetryRedisUrl }
  $lines=Get-Content $raw
  @($lines[0]) + @($lines | Select-Object -Skip 1 | Where-Object { $_ -notmatch '/relay_v2\.pb\.go:|/cmd/(relay|admin)/main\.go:|/internal/telemetry/generated/' }) | Set-Content $filtered -Encoding utf8NoBOM
  $telemetryLines=@($lines[0]) + @($lines | Select-Object -Skip 1 | Where-Object { $_ -match '/internal/telemetry/' -and $_ -notmatch '/internal/telemetry/generated/' })
  if ($telemetryLines.Count -lt 2) { throw 'Telemetry coverage profile is empty; production telemetry was not instrumented.' }
  $telemetry=Join-Path $run 'telemetry.filtered.out';$telemetryLines|Set-Content $telemetry -Encoding utf8NoBOM
  Push-Location $relayDir
  try {
    $summary = & go tool cover "-func=$filtered"
    if ($LASTEXITCODE -ne 0) { throw "go tool cover exited with code $LASTEXITCODE." }
  } finally {
    Pop-Location
  }
  $summary | Write-Host
  $totalLine=$summary | Where-Object { $_ -match '^total:' } | Select-Object -Last 1
  if ($totalLine -notmatch '([0-9]+(?:\.[0-9]+)?)%\s*$') { throw 'Unable to read Go coverage total.' }
  $total=[double]$Matches[1]
  if ($total -lt [double]$Minimum) { throw "Backend coverage is below $Minimum%." }
  Write-Host "Backend coverage gate passed at $total% (minimum $Minimum%)."
  Push-Location $relayDir
  try {
    $telemetrySummary = & go tool cover "-func=$telemetry"
    if ($LASTEXITCODE -ne 0) { throw "go tool cover exited with code $LASTEXITCODE." }
  } finally {
    Pop-Location
  }
  $telemetrySummary|Write-Host;$telemetryTotalLine=$telemetrySummary|Where-Object{$_-match'^total:'}|Select-Object -Last 1
  if ($telemetryTotalLine -notmatch '([0-9]+(?:\.[0-9]+)?)%\s*$') { throw 'Unable to read telemetry coverage total.' };$telemetryTotal=[double]$Matches[1]
  if ($telemetryTotal -lt [double]$telemetryMinimum) { throw "Telemetry coverage is below $telemetryMinimum%." };Write-Host "Telemetry coverage gate passed at $telemetryTotal% (minimum $telemetryMinimum%)."
} finally {
  if ($started) { & docker rm -f $mysql $redis $analyticsMysql $analyticsRedis *> $null }
  Remove-Item $run -Recurse -Force -ErrorAction SilentlyContinue
}
