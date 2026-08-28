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
$FullTestScriptPath=$PSCommandPath
. (Join-Path $PSScriptRoot 'full_test_config.ps1')
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
if(-not$RunId){$RunId="$(Get-Date -Format yyyyMMdd-HHmmss)-$PID"}
if(-not$LogDir){$LogDir=Join-Path $(if($env:FULL_TEST_LOG_DIR){$env:FULL_TEST_LOG_DIR}else{$temp}) "ssh-mobile-full-test-$RunId"}
New-Item -ItemType Directory $LogDir -Force|Out-Null
. (Join-Path $PSScriptRoot 'full_test_runtime.ps1')
. (Join-Path $PSScriptRoot 'full_test_app.ps1')
. (Join-Path $PSScriptRoot 'full_test_jobs.ps1')
. (Join-Path $PSScriptRoot 'full_test_runner.ps1')
if($InternalJob){try{Dispatch $InternalJob;exit 0}catch{[Console]::Error.WriteLine($_);exit 1}}
Invoke-FullTest
