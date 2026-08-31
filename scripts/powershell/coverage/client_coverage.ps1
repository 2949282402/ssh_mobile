[CmdletBinding()]
param([switch]$NoBootstrap, [string]$Minimum = $env:CLIENT_COVERAGE_MINIMUM, [string]$FlutterTimeout = $env:CLIENT_FLUTTER_COVERAGE_TIMEOUT, [string]$Flutter = $env:CLIENT_FLUTTER_BIN, [string]$TempRoot = $env:SSH_MOBILE_WINDOWS_TEMP)
. (Join-Path $PSScriptRoot '..\common\powershell_common.ps1')
Assert-NativeWindowsPowerShell
$root = Get-RepositoryRoot
$temp = Initialize-NativeEnvironment $TempRoot
if (-not $Minimum) { $Minimum = '90' }
if (-not $FlutterTimeout) { $FlutterTimeout = '30m' }
if (-not $Flutter) { $Flutter = 'flutter' }
if ($Minimum -notmatch '^[0-9]+(?:\.[0-9]+)?$') { [Console]::Error.WriteLine("CLIENT_COVERAGE_MINIMUM must be numeric: $Minimum"); exit 64 }
ConvertTo-TimeoutSeconds $FlutterTimeout | Out-Null
Assert-Commands @($Flutter, 'dart')
$app = Join-Path $root 'apps\ssh_mobile_full'
$run = Join-Path $temp ("client-coverage-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run -Force | Out-Null
$environment = @{ HTTP_PROXY=''; HTTPS_PROXY=''; ALL_PROXY=''; SSH_MOBILE_WINDOWS_PROXY=''; NO_PROXY='localhost,127.0.0.1,::1'; APPDATA=(Join-Path $run 'appdata'); LOCALAPPDATA=(Join-Path $run 'localappdata') }
$tests = @('test/services/network/network_protocol_v2_codec_test.dart','test/services/network/network_protocol_v2_codec_commands_test.dart','test/services/network/network_protocol_v2_codec_events_test.dart','test/services/network/network_protocol_v2_codec_stream_events_test.dart','test/services/network/network_protocol_v2_codec_transfer_progress_test.dart','test/services/network/transfer_transport_test.dart','test/services/network/transfer_transport_gateway_test.dart','test/services/network/network_identity_service_test.dart','test/app/realtime_feature_adapters_test.dart','test/app/app_runtime_test.dart')
try {
  Write-Host "Client Network V2 coverage threshold: $Minimum%"
  $profiles = @()
  foreach ($test in $tests) {
    $profile = Join-Path $run (([IO.Path]::GetFileNameWithoutExtension($test)) + '-lcov.info')
    Invoke-CommandWithTimeout $Flutter @('test','--no-pub','--no-test-assets','--coverage','--coverage-path',$profile,'--reporter','expanded',$test) $FlutterTimeout $app $environment
    $profiles += "--file=$profile"
  }
  $sourceArguments = @('--source-root=lib/services/network/')
  $coverageBaseRef = if ($env:CLIENT_COVERAGE_BASE_REF) { $env:CLIENT_COVERAGE_BASE_REF } elseif ($env:CI_BASE_SHA) { $env:CI_BASE_SHA } elseif ($env:GITHUB_BASE_SHA) { $env:GITHUB_BASE_SHA } else { $env:GITHUB_EVENT_BEFORE }
  if ($coverageBaseRef) { $sourceArguments += "--base-ref=$coverageBaseRef" }
  Invoke-CommandChecked dart (@('run','tool/check_coverage.dart',"--minimum=$Minimum",'--details') + $profiles + $sourceArguments + '--include=lib/services/network/') $app
} finally {
  Remove-Item $run -Recurse -Force -ErrorAction SilentlyContinue
}
