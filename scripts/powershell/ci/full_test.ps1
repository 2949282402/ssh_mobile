[CmdletBinding()]
param(
  [int]$Jobs=0,[switch]$Serial,[int]$FlutterConcurrency=0,[int]$MelosConcurrency=0,
  [int]$MelosTestConcurrency=0,[string]$AppTimeout='',[int]$AppShards=0,
  [switch]$WithCoverage,[switch]$NoCoverage,[switch]$WithFeatureLoopback,
  [switch]$WithClientBackendSmoke,[string]$WorkspaceTestTimeout='',
  [switch]$NoBootstrap,[switch]$NoDocker,[string]$Only='',[switch]$VerboseOutput,
  [string]$TempRoot='',[Parameter(DontShow)][string]$InternalJob='',
  [Parameter(DontShow)][string]$RunId='',[Parameter(DontShow)][string]$LogDir=''
)
. (Join-Path $PSScriptRoot '..\common\powershell_common.ps1')
Assert-NativeWindowsPowerShell
$root=Get-RepositoryRoot
if(-not$TempRoot){$TempRoot=if($env:FULL_TEST_TMPDIR){$env:FULL_TEST_TMPDIR}else{$env:SSH_MOBILE_WINDOWS_TEMP}}
$temp=Initialize-NativeEnvironment $TempRoot
$gap=125
function Env([string]$Name,[string]$Default){$value=[Environment]::GetEnvironmentVariable($Name);if($value){$value}else{$Default}}
if($Jobs-eq0){$Jobs=if($env:FULL_TEST_JOBS){[int]$env:FULL_TEST_JOBS}else{[Math]::Min([Environment]::ProcessorCount,4)}}
if($Serial){$Jobs=1}
if($FlutterConcurrency-eq0){$FlutterConcurrency=[int](Env 'FULL_TEST_FLUTTER_CONCURRENCY' '1')}
if($MelosConcurrency-eq0){$MelosConcurrency=[int](Env 'FULL_TEST_MELOS_CONCURRENCY' '1')}
if($MelosTestConcurrency-eq0){$MelosTestConcurrency=[int](Env 'FULL_TEST_MELOS_TEST_CONCURRENCY' '1')}
if($AppShards-eq0){$AppShards=[int](Env 'FULL_TEST_APP_SHARDS' '2')}
if(-not$WorkspaceTestTimeout){$WorkspaceTestTimeout=Env 'FULL_TEST_WORKSPACE_TEST_TIMEOUT' '5m'}
$coverage=if($NoCoverage){$false}elseif($WithCoverage){$true}else{(Env 'FULL_TEST_COVERAGE' '0')-eq'1'}
if(-not$AppTimeout){$AppTimeout=Env 'FULL_TEST_APP_TIMEOUT' $(if($coverage){'30m'}else{'8m'})}
if(-not$WithFeatureLoopback){$WithFeatureLoopback=(Env 'FULL_TEST_FEATURE_LOOPBACK' '0')-eq'1'}
if(-not$WithClientBackendSmoke){$WithClientBackendSmoke=(Env 'FULL_TEST_CLIENT_BACKEND_SMOKE' '0')-eq'1'}
$parallelShards=if($Serial){$false}elseif($env:FULL_TEST_APP_SHARDS_PARALLEL){$env:FULL_TEST_APP_SHARDS_PARALLEL-eq'1'}else{-not$coverage}
if($Jobs-lt1-or$FlutterConcurrency-lt1-or$MelosConcurrency-lt1-or$MelosTestConcurrency-lt1-or$AppShards-lt1-or$AppShards-gt4){[Console]::Error.WriteLine('Concurrency must be positive and AppShards must be 1 through 4.');exit 64}
try{ConvertTo-TimeoutSeconds $AppTimeout|Out-Null;ConvertTo-TimeoutSeconds $WorkspaceTestTimeout|Out-Null}catch{[Console]::Error.WriteLine($_);exit 64}
function Need([string[]]$Names){foreach($name in $Names){if(-not(Get-Command $name -ErrorAction SilentlyContinue)){Write-Host "ENVIRONMENT GAP: required command unavailable: $name";return$false}};$true}
function Cmd([string]$Command,[string[]]$Arguments,[string]$Directory=$root,[hashtable]$Environment=@{}){Invoke-CommandChecked $Command $Arguments $Directory $Environment}
function Script([string]$Path,[hashtable]$Parameters=@{}){
  $global:LASTEXITCODE=0
  & $Path @Parameters
  $status=$LASTEXITCODE
  if($status-eq$gap){exit$gap}
  if($status-ne0){throw "$Path exited with code $status."}
}
function Melos([string]$Command,[string[]]$Scopes){$arguments=@('run','melos','exec','--concurrency',"$MelosConcurrency",'--fail-fast');foreach($scope in $Scopes){$arguments+="--scope=$scope"};$arguments+=@('--',$Command);Cmd dart $arguments}
function JobBootstrap{if(-not(Need @('dart','flutter','npm','cargo','go','python'))){exit$gap};Cmd dart @('pub','get');Cmd flutter @('pub','get') (Join-Path $root 'packages\infrastructure\ssh_mobile_network_native');Cmd flutter @('pub','get') (Join-Path $root 'apps\ssh_mobile_full');Cmd npm @('ci') (Join-Path $root 'front');Cmd cargo @('fetch','--locked') (Join-Path $root 'native\network_core');Cmd go @('mod','download') (Join-Path $root 'relay')}
function JobFront{if(-not(Need @('npm'))){exit$gap};$directory=Join-Path $root 'front';foreach($task in @('typecheck','lint','test:run','build')){Cmd npm @('run',$task) $directory};if($NoDocker-or-not(Need @('docker'))){exit$gap};&docker info*>$null;if($LASTEXITCODE-ne0){exit$gap};Cmd docker @('build','-t',"ssh-mobile-relay-front:$RunId",$directory)}
function JobAdmin{Script (Join-Path $PSScriptRoot '..\contracts\admin_api_contract.ps1') @{TempRoot=$temp}}
function JobNative{
  if(-not(Need @('cargo'))){exit$gap}
  $directory=Join-Path $root 'native\network_core'
  Cmd cargo @('fmt','--all','--','--check') $directory
  Cmd cargo @('test','--workspace','--locked','--','--test-threads=1') $directory
  Cmd cargo @('clippy','--workspace','--all-targets','--locked','--','-D','warnings') $directory
  Write-Host 'ENVIRONMENT GAP: Linux host-network coturn is unavailable on the native Windows gate; TURN fallback was not run.'
  exit$gap
}
function JobSdk{if(-not(Need @('dart','flutter'))){exit$gap};$scopes=@('network_sdk','network_transport','ssh_mobile_network_native');Melos 'dart format --output=none --set-exit-if-changed lib test' $scopes;Melos 'flutter analyze --no-fatal-infos --no-pub' $scopes;Melos "flutter test --no-pub --concurrency $MelosTestConcurrency" $scopes}
function JobLanNetworkV2{
  if(-not(Need @('dart','flutter','cargo'))){exit$gap}
  $featureDirectory=Join-Path $root 'packages\features\feature_lan_share'
  $featureTests=@(
    'test/services/lan_peer_trust_v2_test.dart',
    'test/features/lan_native_peer_registry_v2_test.dart',
    'test/services/lan_pairing_protocol_v2_test.dart',
    'test/services/lan_peer_trust_identity_v2_test.dart',
    'test/services/lan_peer_presentation_models_test.dart',
    'test/services/lan_native_transfer_coordinator_v2_test.dart',
    'test/services/lan_http_v2_route_test.dart',
    'test/services/lan_web_share_request_handler_test.dart'
  )
  $sdkDirectory=Join-Path $root 'packages\infrastructure\network_sdk'
  $sdkTests=@(
    'test/network_facade_v2_refactor_test.dart',
    'test/network_sdk_contract_test.dart',
    'test/network_v2_contract_test.dart',
    'test/network_v2_facade_test.dart'
  )
  $appDirectory=Join-Path $root 'apps\ssh_mobile_full'
  $appTests=@(
    'test/app/network_runtime_ownership_v2_test.dart',
    'test/services/network/network_identity_service_test.dart',
    'test/services/network/network_protocol_v2_codec_test.dart',
    'test/features/lan_share/lan_e2e_encryption_test.dart',
    'test/features/lan_share/lan_pairing_v2_contract_test.dart',
    'test/features/lan_share/lan_storage_safety_v2_test.dart',
    'test/services/lan_web_share_safety_test.dart'
  )
  $webShareTlsWorker='tool/lan_web_share_tls_process.dart'
  $missing=@($featureTests|Where-Object{-not(Test-Path (Join-Path $featureDirectory $_))}|ForEach-Object{"packages/features/feature_lan_share/$_"})
  $missing+=@($sdkTests|Where-Object{-not(Test-Path (Join-Path $sdkDirectory $_))}|ForEach-Object{"packages/infrastructure/network_sdk/$_"})
  $missing+=@($appTests|Where-Object{-not(Test-Path (Join-Path $appDirectory $_))}|ForEach-Object{"apps/ssh_mobile_full/$_"})
  $webShareWorkerDirectory=Join-Path $root 'packages\features\feature_lan_share'
  if(-not(Test-Path (Join-Path $webShareWorkerDirectory $webShareTlsWorker))){$missing+="packages/features/feature_lan_share/$webShareTlsWorker"}
  if($missing.Count){$missing|ForEach-Object{Write-Error "MISSING LAN V2 acceptance test: $_"};throw'LAN V2 acceptance manifest is incomplete.'}
  Cmd flutter (@('test','--no-pub','--no-test-assets')+$featureTests) $featureDirectory
  Cmd flutter (@('test','--no-pub','--no-test-assets')+$sdkTests) $sdkDirectory
  Cmd flutter (@('test','--no-pub','--no-test-assets')+$appTests) $appDirectory
  # Keep the real TLS listener in an ordinary Dart VM process. The boundary
  # suite above uses in-memory requests; this worker owns bindSecure and has no
  # retry/skip path that could hide a native bind stall in flutter_tester.
  Invoke-CommandWithTimeout dart @('run',$webShareTlsWorker) $AppTimeout $webShareWorkerDirectory @{HTTP_PROXY='';HTTPS_PROXY='';ALL_PROXY='';NO_PROXY='localhost,127.0.0.1,::1'}
  $nativeDirectory=Join-Path $root 'native\network_core'
  Cmd cargo @('test','-p','network-core','--locked','--lib','two_runtimes','--','--test-threads=1') $nativeDirectory
  Cmd cargo @('test','-p','network-core','--locked','--lib','receiver_runtime_restart_restores_direct_trust_without_repairing','--','--test-threads=1') $nativeDirectory
  Cmd cargo @('test','-p','network-core','--locked','--lib','peer_runtime_restart_replaces_session_and_keeps_e2ee_delivery','--','--test-threads=1') $nativeDirectory
  Cmd cargo @('test','-p','network-core','--locked','--lib','network_v2_route_auth','--','--test-threads=1') $nativeDirectory
}
function StartStorage{
  $script:mysql="ssh-mobile-full-mysql-$RunId";$script:redis="ssh-mobile-full-redis-$RunId"
  Cmd docker @('run','-d','--rm','--name',$mysql,'-p','127.0.0.1::3306','-e','MYSQL_ROOT_PASSWORD=root','-e','MYSQL_DATABASE=relay','-e','MYSQL_USER=relay','-e','MYSQL_PASSWORD=relay','mysql:8.4')
  Cmd docker @('run','-d','--rm','--name',$redis,'-p','127.0.0.1::6379','redis:7-alpine')
  $mysqlPort=((&docker port $mysql '3306/tcp'|Select-Object -First 1)-replace'^.*:','');$redisPort=((&docker port $redis '6379/tcp'|Select-Object -First 1)-replace'^.*:','')
  $mysqlReady=$false
  foreach($i in 1..60){&docker exec $mysql mysqladmin ping -h 127.0.0.1 -urelay -prelay*>$null;if($LASTEXITCODE-eq0){$mysqlReady=$true;break};Start-Sleep 2}
  if(-not$mysqlReady){throw 'MySQL test container did not become ready.'}
  $redisReady=$false
  foreach($i in 1..30){$pong=&docker exec $redis redis-cli ping 2>$null;if($LASTEXITCODE-eq0-and$pong-eq'PONG'){$redisReady=$true;break};Start-Sleep 2}
  if(-not$redisReady){throw 'Redis test container did not become ready.'}
  $env:RELAY_TEST_MYSQL_DSN="relay:relay@tcp(127.0.0.1:$mysqlPort)/relay?parseTime=true&loc=UTC";$env:RELAY_TEST_REDIS_URL="redis://127.0.0.1:$redisPort/0"
}
function JobRelay{
  if(-not(Need @('go','gofmt'))){exit$gap};$directory=Join-Path $root 'relay';$script:mysql='';$script:redis='';$ready=$env:RELAY_TEST_MYSQL_DSN-and$env:RELAY_TEST_REDIS_URL
  try{if(-not$ready-and-not$NoDocker-and(Need @('docker'))){&docker info*>$null;if($LASTEXITCODE-eq0){try{StartStorage;$ready=$true}catch{Write-Host "ENVIRONMENT GAP: MySQL/Redis test containers were not ready: $_"}}};$bad=@(&gofmt -l $directory);if($bad.Count){$bad|Write-Host;throw'Go formatting failed.'};Cmd go @('test','./...') $directory;Cmd go @('test','-race','./...') $directory;Cmd go @('vet','./...') $directory;Cmd go @('run','golang.org/x/vuln/cmd/govulncheck@v1.6.0','./...') $directory;if(-not$ready){exit$gap}}finally{if($mysql){&docker rm -f $mysql $redis*>$null}}
}
function JobProtocol{if(-not(Need @('cargo','go','python','protoc','buf','dart','flutter'))){exit$gap};Cmd protoc @('--proto_path=protocol',"--descriptor_set_out=$(Join-Path $LogDir 'network-v2.desc')",'protocol/proto/relay/v2/relay_v2.proto','protocol/proto/network/v2/network.proto');Script (Join-Path $PSScriptRoot '..\contracts\relay_v2_contract.ps1') @{TempRoot=$temp};Script (Join-Path $PSScriptRoot '..\contracts\network_v2_acceptance.ps1') @{Mode='strict';TempRoot=$temp};Cmd buf @('lint') (Join-Path $root 'protocol');Cmd buf @('breaking','.','--against','../.git#ref=6ec194bb3a66a748215d3abc11d6da84bd329619,subdir=protocol','--path','proto/relay/v2/relay_v2.proto') (Join-Path $root 'protocol')}
function JobArchitecture{if(-not(Need @('dart'))){exit$gap};foreach($file in @('tool/check_agent_docs.dart','test/tool/agent_docs_check_test.dart','test/tool/ci_workflow_test.dart','tool/architecture_check.dart','tool/check_module_dependencies.dart','tool/check_resource_owners.dart','tool/compatibility_check.dart','tool/duplicate_implementation_check.dart')){Cmd dart @('run',$file)}}
function JobAppStatic{if(-not(Need @('dart','flutter','git'))){exit$gap};$directory=Join-Path $root 'apps\ssh_mobile_full';Cmd dart @('run','tool/generate_app_icons.dart') $directory;Cmd git @('diff','--exit-code','--','assets','android','ios','macos','web','windows/runner/resources/app_icon.ico') $directory;Cmd dart @('format','--output=none','--set-exit-if-changed','lib','test','tool') $directory;Cmd dart @('run','build_runner','clean') $directory;Cmd dart @('run','build_runner','build') $directory;Cmd git @('diff','--exit-code','--','lib/data/database/app_database.g.dart') $directory;Cmd flutter @('analyze','--no-fatal-infos') $directory}
function JobCore{$scopes=@('app_core','app_ui','connection_core','ssh_core');Melos 'dart format --output=none --set-exit-if-changed lib test' $scopes;Melos 'flutter analyze --no-fatal-infos --no-pub' $scopes;Melos "flutter test --no-pub --concurrency $MelosTestConcurrency" $scopes}
function JobFeatures{
  $scopes=@('feature_ai','feature_connection','feature_developer','feature_lan_share','feature_mcp','feature_monitoring','feature_playbook','feature_rag','feature_sftp','feature_system_admin','feature_terminal','feature_webview')
  Melos 'dart format --output=none --set-exit-if-changed lib test' $scopes;Melos 'flutter analyze --no-fatal-infos --no-pub' $scopes
  $ordinaryScopes=@($scopes|Where-Object{$_-ne'feature_mcp'});Melos "flutter test --no-pub --no-test-assets --concurrency $MelosTestConcurrency" $ordinaryScopes
  $mcp=Join-Path $root 'packages\features\feature_mcp';$tests=@(Get-ChildItem (Join-Path $mcp 'test') -Recurse -Filter '*_test.dart'|ForEach-Object{[IO.Path]::GetRelativePath($mcp,$_.FullName).Replace('\','/')}|Where-Object{$WithFeatureLoopback-or$_-ne'test/services/mcp/mcp_http_server_native_test.dart'}|Sort-Object)
  if($tests.Count){Invoke-CommandWithTimeout flutter (@('test','--no-pub','--no-test-assets','--concurrency',"$MelosTestConcurrency")+$tests) $WorkspaceTestTimeout $mcp}
}
function AppFiles{$directory=Join-Path $root 'apps\ssh_mobile_full';@(Get-ChildItem (Join-Path $directory 'test') -Recurse -Filter '*_test.dart'|ForEach-Object{[IO.Path]::GetRelativePath($directory,$_.FullName).Replace('\','/')}|Where-Object{$_-notin@('test/features/startup/views/startup_screen_test.dart','test/screens/system_admin/system_admin_snapshot_tabs_test.dart','test/services/network/transfer_transport_test.dart')-and$_-notlike'test/integration/client_backend/*'}|Sort-Object)}
function JobApp([int]$Shard){
  if(-not(Need @('flutter'))){exit$gap};$directory=Join-Path $root 'apps\ssh_mobile_full';$files=AppFiles
  $coverageDir=Join-Path $LogDir "coverage\shard-$Shard";New-Item -ItemType Directory $coverageDir -Force|Out-Null
  $batchSize=10
  for($offset=0;$offset -lt $files.Count;$offset+=$batchSize){
    $batch=@($files|Select-Object -Skip $offset -First $batchSize)
    $batchIndex=[int]($offset/$batchSize);$batchCoverage=Join-Path $coverageDir "lcov-batch-$batchIndex.info"
    $arguments=@('test','--no-pub','--no-test-assets','--exclude-tags','client-backend,native-loopback','--reporter','compact','--fail-fast','--timeout','60s','--concurrency',"$FlutterConcurrency")
    if($coverage){$arguments+=@('--coverage','--coverage-path',$batchCoverage)}
    $arguments+=$batch
    Invoke-CommandWithTimeout flutter $arguments $AppTimeout $directory @{HTTP_PROXY='';HTTPS_PROXY='';ALL_PROXY='';NO_PROXY='localhost,127.0.0.1,::1'}
  }
  if($coverage){
    $merged=Join-Path $coverageDir 'lcov.info';Remove-Item $merged -Force -ErrorAction SilentlyContinue
    foreach($part in (Get-ChildItem $coverageDir -Filter 'lcov-batch-*.info'|Sort-Object Name)){
      if(-not(Test-Path $merged)){Copy-Item $part.FullName $merged}else{Get-Content $part.FullName|Where-Object{$_ -ne 'TN:'}|Add-Content $merged}
    }
  }
  foreach($isolated in @(
    @{Name='startup';File='test/features/startup/views/startup_screen_test.dart';Coverage=$true},
    @{Name='system-admin';File='test/screens/system_admin/system_admin_snapshot_tabs_test.dart';Coverage=$true},
    @{Name='native-transfer';File='test/services/network/transfer_transport_test.dart';Coverage=$false}
  )){
    $isolatedArguments=@('test','--no-pub','--no-test-assets','--reporter','compact','--fail-fast','--timeout','60s','--concurrency',"$FlutterConcurrency",'--total-shards',"$AppShards",'--shard-index',"$Shard")
    if($coverage-and$isolated.Coverage){$isolatedArguments+=@('--coverage','--coverage-path',(Join-Path $coverageDir "isolated-$($isolated.Name)-lcov.info"))}
    $isolatedArguments+=$isolated.File
    Invoke-CommandWithTimeout flutter $isolatedArguments $AppTimeout $directory @{HTTP_PROXY='';HTTPS_PROXY='';ALL_PROXY='';NO_PROXY='localhost,127.0.0.1,::1'}
  }
}
function JobCoverage{$arguments=@('run','tool/check_coverage.dart','--minimum=35');foreach($shard in 0..($AppShards-1)){$coverageDir=Join-Path $LogDir "coverage\shard-$shard";$arguments+="--file=$(Join-Path $coverageDir 'lcov.info')";foreach($name in @('startup','system-admin')){$arguments+="--file=$(Join-Path $coverageDir "isolated-$name-lcov.info")"}};Cmd dart $arguments (Join-Path $root 'apps\ssh_mobile_full')}
function JobAndroid{Cmd flutter @('build','apk','--debug','--no-pub') (Join-Path $root 'apps\ssh_mobile_full')}
function JobWindows{Cmd flutter @('build','windows','--no-pub') (Join-Path $root 'apps\ssh_mobile_full')}
function JobTerminal{Cmd flutter @('build','windows','--debug','--no-pub') (Join-Path $root 'apps\ssh_mobile_terminal')}
function JobE2E{Script (Join-Path $PSScriptRoot '..\e2e\client_backend_e2e.ps1') @{Mode='smoke';TempRoot=$temp}}
function Dispatch([string]$Name){switch -Regex ($Name){'^bootstrap$'{JobBootstrap};'^front-quality$'{JobFront};'^admin-api-contract$'{JobAdmin};'^native-network-quality$'{JobNative};'^sdk-dart-quality$'{JobSdk};'^lan-network-v2-targeted$'{JobLanNetworkV2};'^relay-quality$'{JobRelay};'^protocol-v2-contract$'{JobProtocol};'^architecture-check$'{JobArchitecture};'^app-static-quality$'{JobAppStatic};'^workspace-core-quality$'{JobCore};'^workspace-features-quality$'{JobFeatures};'^app-unit-shard-([0-3])$'{JobApp ([int]$Matches[1])};'^app-coverage$'{JobCoverage};'^android-build$'{JobAndroid};'^windows-build$'{JobWindows};'^terminal-smoke-build$'{JobTerminal};'^client-backend-smoke$'{JobE2E};default{throw"Unknown job $Name"}}}
if($InternalJob){try{Dispatch $InternalJob;exit 0}catch{[Console]::Error.WriteLine($_);exit 1}}
if(-not$RunId){$RunId="$(Get-Date -Format yyyyMMdd-HHmmss)-$PID"}
if(-not$LogDir){$LogDir=Join-Path $(if($env:FULL_TEST_LOG_DIR){$env:FULL_TEST_LOG_DIR}else{$temp}) "ssh-mobile-full-test-$RunId"}
New-Item -ItemType Directory $LogDir -Force|Out-Null
$requested=[string[]]@()
if($Only){$requested=[string[]]@($Only.Split(',')|Where-Object{$_})}
function Wanted([string]$Name){$requested.Count-eq0-or$Name-in$requested}
$results=@{};$durations=@{};$selected=[Collections.Generic.List[string]]::new();$start=Get-Date
function StartJob([string]$Name){
  $processInfo=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$processInfo.UseShellExecute=$false
  foreach($argument in @('-NoProfile','-File',$PSCommandPath,'-InternalJob',$Name,'-RunId',$RunId,'-LogDir',$LogDir,'-Jobs',"$Jobs",'-FlutterConcurrency',"$FlutterConcurrency",'-MelosConcurrency',"$MelosConcurrency",'-MelosTestConcurrency',"$MelosTestConcurrency",'-AppTimeout',$AppTimeout,'-AppShards',"$AppShards",'-WorkspaceTestTimeout',$WorkspaceTestTimeout,'-TempRoot',$temp)){$processInfo.ArgumentList.Add($argument)}
  if($coverage){$processInfo.ArgumentList.Add('-WithCoverage')}else{$processInfo.ArgumentList.Add('-NoCoverage')};if($WithFeatureLoopback){$processInfo.ArgumentList.Add('-WithFeatureLoopback')};if($NoDocker){$processInfo.ArgumentList.Add('-NoDocker')}
  $processInfo.RedirectStandardOutput=$true;$processInfo.RedirectStandardError=$true;$process=[Diagnostics.Process]::new();$process.StartInfo=$processInfo;$process.Start()|Out-Null;$selected.Add($Name);Write-Host "[RUN ] $Name"
  @{Name=$Name;Process=$process;Started=Get-Date;Out=$process.StandardOutput.ReadToEndAsync();Err=$process.StandardError.ReadToEndAsync()}
}
function Complete($Job){$Job.Process.WaitForExit();$output=$Job.Out.Result+$Job.Err.Result;$status=$Job.Process.ExitCode;$duration=[int]((Get-Date)-$Job.Started).TotalSeconds;$results[$Job.Name]=$status;$durations[$Job.Name]=$duration;$output|Set-Content (Join-Path $LogDir "$($Job.Name).log") -Encoding utf8NoBOM;if($status-eq0){Write-Host "[PASS] $($Job.Name) (${duration}s)"}elseif($status-eq$gap){Write-Host "[GAP ] $($Job.Name)";$output|Write-Host}else{Write-Host "[FAIL] $($Job.Name)";$output|Write-Host};$Job.Process.Dispose()}
function Batch([string[]]$Names,[int]$Limit=$Jobs){$queue=[Collections.Generic.Queue[string]]::new();foreach($name in $Names){if(Wanted $name){$queue.Enqueue($name)}};$active=[Collections.Generic.List[object]]::new();while($queue.Count-or$active.Count){while($queue.Count-and$active.Count-lt$Limit){$active.Add((StartJob $queue.Dequeue()))};$done=$active|Where-Object{$_.Process.HasExited}|Select-Object -First 1;if($null-eq$done){Start-Sleep -Milliseconds 200}else{Complete $done;$active.Remove($done)}}}
Write-Host "SSH Mobile native Windows CI`nroot: $root`nlogs: $LogDir"
if(-not$NoBootstrap){Batch @('bootstrap') 1}
Batch @('front-quality','admin-api-contract','native-network-quality','sdk-dart-quality','lan-network-v2-targeted','relay-quality','protocol-v2-contract','architecture-check','app-static-quality')
if($WithClientBackendSmoke){Batch @('client-backend-smoke') 1}
Batch @('workspace-core-quality') 1;Batch @('workspace-features-quality') 1
$appJobs=@(0..($AppShards-1)|ForEach-Object{"app-unit-shard-$_"});Batch $appJobs $(if($parallelShards){$Jobs}else{1})
Batch @('android-build') 1;Batch @('windows-build') 1;Batch @('terminal-smoke-build') 1
if($coverage-and@($appJobs|Where-Object{$results[$_]-ne0}).Count-eq0){Batch @('app-coverage') 1}
Write-Host "`nFinal summary:"
foreach($name in $selected){Write-Host("  {0} {1} ({2}s)"-f$(if($results[$name]-eq0){'PASS'}elseif($results[$name]-eq$gap){'GAP '}else{'FAIL'}),$name,$durations[$name])}
Write-Host "Total: $([int]((Get-Date)-$start).TotalSeconds)s"
if(@($results.Values|Where-Object{$_-ne0-and$_-ne$gap}).Count){exit 1}
if(@($results.Values|Where-Object{$_-eq$gap}).Count){exit 2}
