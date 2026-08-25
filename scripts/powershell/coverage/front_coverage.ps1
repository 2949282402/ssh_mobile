[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments, [string]$TempRoot = $env:SSH_MOBILE_WINDOWS_TEMP)
. (Join-Path $PSScriptRoot '..\common\powershell_common.ps1')
Assert-NativeWindowsPowerShell
$root = Get-RepositoryRoot
Initialize-NativeEnvironment $TempRoot | Out-Null
Assert-Commands @('npm')
$front = Join-Path $root 'front'
if (-not (Test-Path (Join-Path $front 'node_modules\@vitest\coverage-v8'))) { Invoke-CommandChecked npm @('ci') $front }
Invoke-CommandChecked npm (@('run', 'test:coverage', '--') + $RemainingArguments) $front
