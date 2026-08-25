[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Assert-NativeWindowsPowerShell {
  if ($PSVersionTable.PSVersion.Major -lt 7 -or -not $IsWindows) {
    throw 'Native Windows PowerShell 7 or newer is required.'
  }
  if ((Get-Location).ProviderPath -match '^(\\\\wsl|/mnt/)') {
    throw 'Run from a native Windows checkout, not a WSL path.'
  }
}

function Get-RepositoryRoot {
  return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).ProviderPath
}

function Initialize-NativeEnvironment([string]$TempRoot) {
  if ($TempRoot -and $TempRoot -match '^(\\\\wsl|/mnt/|/tmp/)') {
    throw 'The temporary directory must be a native Windows path.'
  }
  if (-not $TempRoot) {
    $TempRoot = Join-Path ([IO.Path]::GetTempPath()) 'ssh-mobile'
  }
  New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
  $resolved = (Resolve-Path -LiteralPath $TempRoot).ProviderPath
  $env:TEMP = $resolved
  $env:TMP = $resolved
  if (Test-Path Env:TMPDIR) { Remove-Item Env:TMPDIR }
  return $resolved
}

function Assert-Commands([string[]]$Names, [int]$ExitCode = 125) {
  foreach ($name in $Names) {
    if ($null -eq (Get-Command $name -ErrorAction SilentlyContinue)) {
      [Console]::Error.WriteLine("Required command is unavailable: $name")
      exit $ExitCode
    }
  }
}

function Invoke-CommandChecked(
  [string]$Command,
  [string[]]$Arguments = @(),
  [string]$WorkingDirectory,
  [hashtable]$Environment = @{}
) {
  $oldLocation = Get-Location
  $oldEnvironment = @{}
  try {
    if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
    foreach ($entry in $Environment.GetEnumerator()) {
      $oldEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
      [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
    }
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command exited with code $LASTEXITCODE." }
  } finally {
    foreach ($entry in $oldEnvironment.GetEnumerator()) {
      [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    Set-Location $oldLocation
  }
}

function ConvertTo-TimeoutSeconds([string]$Duration) {
  if ($Duration -notmatch '^(?<value>[1-9][0-9]*)(?<unit>[smhd])$') {
    throw "Duration must look like 60s, 20m, 1h, or 1d: $Duration"
  }
  $factor = @{ s = 1; m = 60; h = 3600; d = 86400 }[$Matches.unit]
  return [int64]$Matches.value * $factor
}

function Invoke-CommandWithTimeout(
  [string]$Command,
  [string[]]$Arguments,
  [string]$Duration,
  [string]$WorkingDirectory,
  [hashtable]$Environment = @{}
) {
  $out = Join-Path $env:TEMP ("ssh-mobile-{0}.out" -f [Guid]::NewGuid().ToString('N'))
  $err = "$out.err"
  $oldEnvironment = @{}
  foreach ($entry in $Environment.GetEnumerator()) {
    $oldEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
    [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
  }
  try {
    $process = Start-Process -FilePath $Command -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory `
      -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  } finally {
    foreach ($entry in $oldEnvironment.GetEnumerator()) {
      [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
  }
  try {
    if (-not $process.WaitForExit((ConvertTo-TimeoutSeconds $Duration) * 1000)) {
      $process.Kill($true)
      $process.WaitForExit()
      throw "$Command timed out after $Duration."
    }
    Get-Content -LiteralPath $out -ErrorAction SilentlyContinue | Write-Host
    Get-Content -LiteralPath $err -ErrorAction SilentlyContinue | ForEach-Object { [Console]::Error.WriteLine($_) }
    if ($process.ExitCode -ne 0) { throw "$Command exited with code $($process.ExitCode)." }
  } finally {
    Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    $process.Dispose()
  }
}
