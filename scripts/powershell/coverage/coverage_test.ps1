[CmdletBinding()]
param([switch]$NoBootstrap, [string]$Minimum = $env:CLIENT_COVERAGE_MINIMUM, [string]$FlutterTimeout = $env:CLIENT_FLUTTER_COVERAGE_TIMEOUT, [string]$Flutter = $env:CLIENT_FLUTTER_BIN, [string]$TempRoot = $env:SSH_MOBILE_WINDOWS_TEMP)
& (Join-Path $PSScriptRoot 'client_coverage.ps1') -NoBootstrap:$NoBootstrap -Minimum $Minimum -FlutterTimeout $FlutterTimeout -Flutter $Flutter -TempRoot $TempRoot
