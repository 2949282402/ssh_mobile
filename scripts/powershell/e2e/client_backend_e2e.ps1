[CmdletBinding()]
param([ValidateSet('smoke','strict')][string]$Mode='smoke',[string]$TempRoot=$env:SSH_MOBILE_WINDOWS_TEMP)
. (Join-Path $PSScriptRoot '..\common\powershell_common.ps1')
Assert-NativeWindowsPowerShell
$root=Get-RepositoryRoot
$temp=Initialize-NativeEnvironment $TempRoot
$run=Join-Path $temp ("client-backend-e2e-{0}"-f[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run|Out-Null
$project="ssh-mobile-client-backend-$PID"
$envFile=Join-Path $run 'relay.env'
$base=$env:CLIENT_BACKEND_E2E_BASE_URL
$token=$env:RELAY_ENROLLMENT_TOKEN
$storage=if($env:CLIENT_BACKEND_E2E_STORAGE){$env:CLIENT_BACKEND_E2E_STORAGE}else{'memory'}
$adminUser=$env:CLIENT_BACKEND_E2E_ADMIN_USER
$adminPassword=$env:CLIENT_BACKEND_E2E_ADMIN_PASSWORD
$devicePrefix=$env:CLIENT_BACKEND_E2E_DEVICE_PREFIX
if($null-eq$devicePrefix){$devicePrefix=''}
$revocationDeviceId=if($env:CLIENT_BACKEND_E2E_REVOCATION_DEVICE_ID){$env:CLIENT_BACKEND_E2E_REVOCATION_DEVICE_ID}else{$devicePrefix+'e2e-rust-revoke-a'}
$requiredCommands=@('curl.exe','cargo','flutter')
if(-not($base-or$token)){$requiredCommands+='docker'}
Assert-Commands $requiredCommands 125
$started=$false
$rustProcess=$null
if($storage-notin@('memory','mysql')){[Console]::Error.WriteLine("CLIENT_BACKEND_E2E_STORAGE must be memory or mysql: $storage");exit 64}
function Compose([string[]]$Args){
  $a=@('compose','--project-name',$project,'--env-file',$envFile,'--file',(Join-Path $root 'compose.yaml'))
  $a+=@('--profile','storage')
  Invoke-CommandChecked docker ($a+$Args) $root
}
function Hex([int]$n){[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes($n)).ToLowerInvariant()}
function B64([int]$n){[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes($n)).TrimEnd('=').Replace('+','-').Replace('/','_')}
function Port{$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);try{$listener.Start();([Net.IPEndPoint]$listener.LocalEndpoint).Port}finally{$listener.Stop()}}
function CurlStatus([string[]]$Args){((& curl.exe @Args 2>$null|Out-String).Trim())}
function TlsArgs{if($env:CLIENT_BACKEND_E2E_CA_FILE){@('--cacert',$env:CLIENT_BACKEND_E2E_CA_FILE)}else{@()}}
. (Join-Path $PSScriptRoot 'client_backend_telemetry.ps1')
function WaitHealth{
  foreach($i in 1..90){if((CurlStatus ((TlsArgs)+@('-sS','--max-time','3','-o','NUL','-w','%{http_code}',"$base/healthz")))-eq'204'){return};Start-Sleep 1}
  throw "Relay health probe failed: $base/healthz"
}
function AssertRoutes{
  foreach($route in @('/v2/control','/v2/relay/00000000000000000000000000000000')){
    $headers=Join-Path $run 'headers';$body=Join-Path $run 'body'
    $status=CurlStatus ((TlsArgs)+@('-sS','--max-time','5','-H','Accept: application/json','-D',$headers,'-o',$body,'-w','%{http_code}',"$base$route"))
    $contentType=(Get-Content $headers|Where-Object{$_-match'^Content-Type:'}|Select-Object -Last 1)
    if($status-ne'401'-or$contentType-notmatch'application/json'){throw "Relay route regression: $route returned $status / $contentType"}
  }
}
function StartDeployment{
  & docker info *> $null
  if($LASTEXITCODE-ne0){[Console]::Error.WriteLine('ENVIRONMENT GAP: Docker daemon unavailable');exit 125}
  $http=Port;$https=Port;$script:token=Hex 24;$key=B64 32;$authKey=B64 32;$internalToken=Hex 24;$script:adminUser='e2e-admin';$script:adminPassword=Hex 24
  $mysqlRoot=Hex 24;$mysqlPassword=Hex 24;$redisPassword=Hex 24
  $analyticsMysqlPassword=Hex 24;$analyticsMysqlRootPassword=Hex 24;$analyticsRedisPassword=Hex 24;$telemetryAuthSecret=Hex 24
  $script:base="http://127.0.0.1:$http"
  $octet=Get-Random -Minimum 18 -Maximum 30;$subnet="172.$octet.0.0/24";$caddy="172.$octet.0.10"
  $ttl=if($env:CLIENT_BACKEND_E2E_CREDENTIAL_TTL){$env:CLIENT_BACKEND_E2E_CREDENTIAL_TTL}elseif($Mode-eq'strict'){'30s'}else{'24h'}
  # Relay MySQL/Redis services are always part of the Compose topology now,
  # so provide valid endpoints even for an explicit memory-mode test.
  $db="e2e_relay:${mysqlPassword}@tcp(mysql:3306)/relay?parseTime=true&loc=UTC"
  $redisUrl='redis://redis:6379/0'
  @('RELAY_PUBLIC_DOMAIN=http://127.0.0.1',"RELAY_PUBLIC_URL=$base","RELAY_HTTP_PORT=$http","RELAY_HTTPS_PORT=$https",'RELAY_CADDY_IMAGE=caddy:2.8-alpine','CADDY_HTTP_PORT=80','CADDY_HTTPS_PORT=443','RELAY_INTERNAL_PORT=8080','ADMIN_INTERNAL_PORT=8081','FRONT_INTERNAL_PORT=80',"RELAY_STORAGE_MODE=$storage","RELAY_DATABASE_URL=$db","RELAY_REDIS_URL=$redisUrl","RELAY_REDIS_PASSWORD=$redisPassword",'RELAY_INSTANCE_ID=client-backend-e2e','RELAY_PRESENCE_TTL=60s',"RELAY_ENROLLMENT_TOKEN=$token","RELAY_INTERNAL_TOKEN=$internalToken","RELAY_CREDENTIAL_KEY=$key","RELAY_CREDENTIAL_TTL=$ttl",'ADMIN_USER=e2e-admin',"ADMIN_PASSWORD=$adminPassword","ADMIN_AUTH_KEY=$authKey","ADMIN_RELAY_INTERNAL_TOKEN=$internalToken","ADMIN_TRUSTED_PROXY_CIDRS=$caddy/32",'ADMIN_SESSION_TTL=24h','ADMIN_MAX_SESSIONS=32','ADMIN_LOGIN_MAX_ATTEMPTS=5','ADMIN_LOGIN_WINDOW=1m','ADMIN_LOGIN_BLOCK=5m','ADMIN_MAX_LOGIN_ENTRIES=4096','ADMIN_HTTP_READ_TIMEOUT=15s','ADMIN_HTTP_WRITE_TIMEOUT=15s','ADMIN_HTTP_IDLE_TIMEOUT=60s','ADMIN_HTTP_MAX_HEADER_BYTES=16384','RELAY_MAX_CONNECTIONS=2048','RELAY_MAX_ENROLLED_DEVICES=4096','RELAY_MAX_REVOKED_DEVICES=4096','RELAY_MAX_TRANSFER_SESSIONS=4096','RELAY_MAX_PENDING_FRAMES_PER_DEVICE=64','RELAY_MAX_PENDING_BYTES_PER_DEVICE=16777216','RELAY_MAX_FRAMES_PER_SECOND_PER_DEVICE=256','RELAY_MAX_BYTES_PER_SECOND_PER_DEVICE=67108864','RELAY_HTTP_READ_TIMEOUT=15s','RELAY_HTTP_WRITE_TIMEOUT=15s','RELAY_HTTP_IDLE_TIMEOUT=60s','RELAY_HTTP_MAX_HEADER_BYTES=16384',"RELAY_TRUSTED_PROXY_CIDRS=$caddy/32","RELAY_CADDY_IP=$caddy","RELAY_NETWORK_SUBNET=$subnet","MYSQL_ROOT_PASSWORD=$mysqlRoot",'MYSQL_DATABASE=relay','MYSQL_USER=e2e_relay',"MYSQL_PASSWORD=$mysqlPassword", "TELEMETRY_MYSQL_DSN=telemetry:$analyticsMysqlPassword@tcp(analytics-mysql:3306)/telemetry?parseTime=true&loc=UTC", "TELEMETRY_REDIS_URL=redis://:$analyticsRedisPassword@analytics-redis:6379/0", "TELEMETRY_AUTH_SECRET=$telemetryAuthSecret", "ANALYTICS_MYSQL_PASSWORD=$analyticsMysqlPassword", "ANALYTICS_MYSQL_ROOT_PASSWORD=$analyticsMysqlRootPassword", "ANALYTICS_REDIS_PASSWORD=$analyticsRedisPassword")|Set-Content $envFile -Encoding utf8NoBOM
  $script:started=$true
  Compose @('up','-d','--build')
  WaitHealth
}
function RunRust{
  Invoke-CommandChecked cargo @('test','-p','network-relay','--features','test-support','--test','client_backend_e2e','--locked','--','--ignored','--test-threads=1') (Join-Path $root 'native\network_core') @{CLIENT_BACKEND_E2E_BASE_URL=$base;RELAY_ENROLLMENT_TOKEN=$token;CLIENT_BACKEND_E2E_STRICT=$(if($Mode-eq'strict'){'1'}else{''})}
}
function RunDart{
  Invoke-CommandChecked flutter @('test','--no-pub','test/integration/client_backend/relay_bootstrap_e2e_test.dart') (Join-Path $root 'apps\ssh_mobile_full') @{CLIENT_BACKEND_E2E_BASE_URL=$base;RELAY_ENROLLMENT_TOKEN=$token;HTTP_PROXY='';HTTPS_PROXY='';ALL_PROXY='';NO_PROXY='localhost,127.0.0.1,::1'}
}
function AdminRevoke{
  $cookie=Join-Path $run 'cookie';$body=Join-Path $run 'login.json'
  @{username=$adminUser;password=$adminPassword}|ConvertTo-Json -Compress|Set-Content $body -Encoding utf8NoBOM
  $status=CurlStatus ((TlsArgs)+@('-sS','--max-time','10','-H','Content-Type: application/json','-c',$cookie,'--data-binary',"@$body",'-o','NUL','-w','%{http_code}',"$base/api/admin/v1/auth/login"))
  if($status-ne'200'){throw "Admin login failed: $status"}
  $status=CurlStatus ((TlsArgs)+@('-sS','--max-time','10','-b',$cookie,'-X','POST','-o','NUL','-w','%{http_code}',"$base/api/admin/v1/devices/$revocationDeviceId/revoke"))
  if($status-ne'204'){throw "Admin revoke failed: $status"}
  $status=CurlStatus ((TlsArgs)+@('-sS','--max-time','10','-b',$cookie,'-X','POST','-o','NUL','-w','%{http_code}',"$base/api/admin/v1/auth/logout"))
  if($status-ne'204'){throw "Admin logout failed: $status"}
}
function AssertStorageAfterRestart{
  if(-not$adminUser-or-not$adminPassword){return};$cookie=Join-Path $run 'restart-admin-cookie';$body=Join-Path $run 'restart-admin-login.json';$devices=Join-Path $run 'devices-after-restart.json'
  @{username=$adminUser;password=$adminPassword}|ConvertTo-Json -Compress|Set-Content $body -Encoding utf8NoBOM
  $status=CurlStatus ((TlsArgs)+@('-sS','--max-time','10','-H','Content-Type: application/json','-c',$cookie,'--data-binary',"@$body",'-o','NUL','-w','%{http_code}',"$base/api/admin/v1/auth/login"));if($status-ne'200'){throw "Strict post-restart admin login failed: $status"}
  $status=CurlStatus ((TlsArgs)+@('-sS','--max-time','10','-b',$cookie,'-o',$devices,'-w','%{http_code}',"$base/api/admin/v1/devices"));if($status-ne'200'){throw "Strict post-restart device snapshot failed: $status"}
  $bodyText=Get-Content $devices -Raw
  if($storage-eq'mysql'){if($bodyText-notmatch([regex]::Escape($devicePrefix+'e2e-rust-a'))){throw'MySQL storage profile lost an enrolled device after Relay restart.'};if($bodyText-match([regex]::Escape($devicePrefix+'e2e-rust-revoke-a'))){throw'MySQL storage profile retained a revoked device after Relay restart.'}}
  elseif($bodyText-match([regex]::Escape($devicePrefix+'e2e-rust-a')+'|'+[regex]::Escape($devicePrefix+'e2e-rust-b'))){throw'Memory storage profile retained an enrollment after Relay restart.'}
}
function RunRevocation{
  $native=Join-Path $root 'native\network_core'
  Invoke-CommandChecked cargo @('test','-p','network-relay','--features','test-support','--test','client_backend_e2e','--locked','--no-run') $native
  $ready=Join-Path $run 'ready';$done=Join-Path $run 'done';$log=Join-Path $run 'rust.log'
  $vars=@{CLIENT_BACKEND_E2E_BASE_URL=$base;RELAY_ENROLLMENT_TOKEN=$token;CLIENT_BACKEND_E2E_STRICT='1';CLIENT_BACKEND_E2E_REVOCATION='1';CLIENT_BACKEND_E2E_REVOCATION_READY_FILE=$ready;CLIENT_BACKEND_E2E_REVOCATION_DONE_FILE=$done}
  $old=@{}
  foreach($v in $vars.GetEnumerator()){$old[$v.Key]=[Environment]::GetEnvironmentVariable($v.Key,'Process');[Environment]::SetEnvironmentVariable($v.Key,$v.Value,'Process')}
  try{$script:rustProcess=Start-Process cargo -ArgumentList @('test','-p','network-relay','--features','test-support','--test','client_backend_e2e','--locked','--','--ignored','--test-threads=1') -WorkingDirectory $native -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"}
  finally{foreach($v in $old.GetEnumerator()){[Environment]::SetEnvironmentVariable($v.Key,$v.Value,'Process')}}
  foreach($i in 1..600){if(Test-Path $ready){break};if($rustProcess.HasExited){throw 'Revocation client exited early.'};Start-Sleep -Milliseconds 250}
  if(-not(Test-Path $ready)){throw 'Revocation client did not become ready.'}
  AdminRevoke
  New-Item -ItemType File $done|Out-Null
  $rustProcess.WaitForExit()
  if($rustProcess.ExitCode-ne0){throw 'Revocation client failed.'}
  $rustProcess.Dispose();$script:rustProcess=$null
}
try{
  if($base-or$token){if(-not$base-or-not$token){[Console]::Error.WriteLine('CLIENT_BACKEND_E2E_BASE_URL and RELAY_ENROLLMENT_TOKEN must be provided together');exit 64}}else{StartDeployment}
  AssertRoutes
  TelemetryIngestion
  RunDart
  if($Mode-eq'strict'-and$adminUser-and$adminPassword){RunRevocation}else{RunRust}
  if($Mode-eq'strict'-and$started){
    Compose @('restart','caddy')
    WaitHealth
    AssertRoutes
    Compose @('stop','relay')
    $downStatus=CurlStatus ((TlsArgs)+@('-sS','--max-time','3','-o','NUL','-w','%{http_code}',"$base/healthz"))
    if($downStatus-eq'204'){throw "Deployment regression: public /healthz returned 204 while Relay was stopped"}
    Compose @('start','relay')
    WaitHealth
    AssertRoutes
    Compose @('restart','relay')
    WaitHealth
    AssertRoutes
    AssertStorageAfterRestart
  }
  Write-Host $(if($Mode-eq'strict'){'CLIENT_BACKEND_STRICT_PASS'}else{'CLIENT_BACKEND_SMOKE_PASS'})
}finally{
  if($null-ne$rustProcess-and-not$rustProcess.HasExited){$rustProcess.Kill($true)}
  if($started){try{Compose @('down','--volumes','--remove-orphans')}catch{Write-Warning $_}}
  Remove-Item $run -Recurse -Force -ErrorAction SilentlyContinue
}
