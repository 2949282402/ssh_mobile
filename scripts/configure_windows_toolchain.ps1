[CmdletBinding()]
param(
  # Pass the Windows Flutter SDK root explicitly.  Do not rely on whichever
  # flutter.exe happens to be first on PATH when switching between SDKs.
  [string]$FlutterRoot = $env:SSH_MOBILE_WINDOWS_FLUTTER_ROOT,

  # Keep native Flutter's temporary files on a native Windows path.  This is
  # especially important when a shell inherited a WSL-style TMPDIR value.
  [string]$TempRoot = $env:SSH_MOBILE_WINDOWS_TEMP,

  # Persist only the SDK root and its bin directory.  TEMP/TMP and the Rust
  # override remain process-scoped so unrelated Windows applications/projects
  # are not changed.
  [switch]$PersistUserPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
  throw 'PowerShell 7 or newer is required on Windows. Start pwsh.exe, not Windows PowerShell 5.1.'
}

$currentLocation = (Get-Location).ProviderPath
if ($currentLocation -match '^(\\\\wsl|/mnt/)') {
  throw 'Run from a native Windows path before configuring the toolchain; do not inherit a WSL UNC working directory.'
}

# WSL-launched PowerShell can inherit a truncated PATHEXT (for example,
# ``.CPL`` only).  Flutter's Windows launcher uses ``where git``; restore the
# native executable extensions in this process so cmd.exe resolves where.exe.
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC'

if (-not [string]::IsNullOrWhiteSpace($TempRoot) -and
    $TempRoot -match '^(\\\\wsl|/mnt/|/tmp/)') {
  throw 'TempRoot must be a native Windows path; do not pass a WSL or Linux temporary directory.'
}
if ([string]::IsNullOrWhiteSpace($TempRoot)) {
  $systemDrive = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) {
    'C:'
  } else {
    $env:SystemDrive
  }
  $TempRoot = Join-Path $systemDrive 'Temp\ssh-mobile'
}

$expectedFlutter = '3.47.0'
$expectedDart = '3.13.0'
$expectedRust = '1.97.1'
$expectedRustToolchain = "$expectedRust-x86_64-pc-windows-msvc"

function Resolve-FlutterRoot {
  param([string]$ConfiguredRoot)

  if (-not [string]::IsNullOrWhiteSpace($ConfiguredRoot)) {
    return (Resolve-Path -LiteralPath $ConfiguredRoot -ErrorAction Stop).ProviderPath
  }

  $command = Get-Command flutter -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    throw 'Flutter is not on PATH. Pass -FlutterRoot <Windows Flutter SDK root>.'
  }

  $commandPath = $command.Path
  if ([string]::IsNullOrWhiteSpace($commandPath)) {
    $commandPath = $command.Source
  }
  if ([string]::IsNullOrWhiteSpace($commandPath)) {
    throw 'Unable to resolve the Flutter command path.'
  }

  $binPath = Split-Path -Parent $commandPath
  return (Resolve-Path -LiteralPath (Join-Path $binPath '..') -ErrorAction Stop).ProviderPath
}

function Invoke-WindowsBatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BatchPath,
    [Parameter(Mandatory = $false)]
    [string[]]$ArgumentList = @()
  )

  # A PowerShell 7 process launched through WSL can still lose a .bat
  # document's console streams. Start-Process keeps the invocation native and
  # captures both streams so version validation cannot lose the result.
  $quotedPath = '"' + $BatchPath + '"'
  $commandLine = @('call', $quotedPath) + $ArgumentList -join ' '
  $comSpec = Get-Command cmd.exe -ErrorAction Stop
  $tempBase = if ([string]::IsNullOrWhiteSpace($TempRoot)) {
    [IO.Path]::GetTempPath()
  } else {
    $TempRoot
  }
  New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
  $runId = [Guid]::NewGuid().ToString('N')
  $stdoutPath = Join-Path $tempBase "ssh-mobile-tool-$runId.out"
  $stderrPath = Join-Path $tempBase "ssh-mobile-tool-$runId.err"
  $process = Start-Process -FilePath $comSpec.Source `
    -ArgumentList @('/d', '/s', '/c', $commandLine) `
    -WorkingDirectory $currentLocation `
    -Wait -PassThru `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath
  $stdout = if (Test-Path -LiteralPath $stdoutPath) {
    Get-Content -LiteralPath $stdoutPath -Raw
  } else {
    ''
  }
  $stderr = if (Test-Path -LiteralPath $stderrPath) {
    Get-Content -LiteralPath $stderrPath -Raw
  } else {
    ''
  }
  Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  $exitCode = $process.ExitCode
  if ($exitCode -ne 0) {
    throw "$BatchPath exited with code $exitCode. Output: $stdout$stderr"
  }
  return "$stdout$stderr"
}

$resolvedFlutterRoot = Resolve-FlutterRoot $FlutterRoot
$flutterBin = Join-Path $resolvedFlutterRoot 'bin'
$flutterCommand = Join-Path $flutterBin 'flutter.bat'
$dartCommand = Join-Path $flutterBin 'dart.bat'

if (-not (Test-Path -LiteralPath $flutterCommand -PathType Leaf)) {
  throw "Flutter launcher not found: $flutterCommand"
}
if (-not (Test-Path -LiteralPath $dartCommand -PathType Leaf)) {
  throw "Dart launcher not found: $dartCommand"
}

$currentPath = if ($null -eq $env:Path) { '' } else { $env:Path }
$pathEntries = @(
  $currentPath -split ';' | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
  }
)
$hasFlutterBin = @($pathEntries | Where-Object {
  $_.TrimEnd('\') -ieq $flutterBin.TrimEnd('\')
})
if ($hasFlutterBin.Count -eq 0) {
  $env:Path = if ($currentPath.Length -eq 0) {
    $flutterBin
  } else {
    "$flutterBin;$currentPath"
  }
}
$env:SSH_MOBILE_WINDOWS_FLUTTER_ROOT = $resolvedFlutterRoot

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
$env:TEMP = $TempRoot
$env:TMP = $TempRoot
if (Test-Path Env:TMPDIR) {
  Remove-Item Env:TMPDIR
}

# The repository's native/network_core/rust-toolchain.toml is authoritative
# for builds.  This process-scoped value keeps a hook launched from another
# working directory on the same Windows toolchain.
$env:RUSTUP_TOOLCHAIN = $expectedRustToolchain

$flutterVersion = (Invoke-WindowsBatch $flutterCommand @('--version', '--machine') |
  Out-String).Trim()
try {
  # The first Windows Flutter invocation may build the flutter tool and emit
  # dependency messages before the machine-readable JSON.  Parse the JSON
  # object rather than assuming it starts at byte zero.
  $jsonStart = $flutterVersion.IndexOf('{')
  $jsonEnd = $flutterVersion.LastIndexOf('}')
  if ($jsonStart -lt 0 -or $jsonEnd -lt $jsonStart) {
    throw 'No JSON object was found.'
  }
  $flutterMetadata = $flutterVersion.Substring(
    $jsonStart,
    $jsonEnd - $jsonStart + 1
  ) | ConvertFrom-Json
} catch {
  throw "Flutter --version --machine did not return JSON: $flutterVersion"
}

if ($flutterMetadata.frameworkVersion -ne $expectedFlutter) {
  throw "Expected Flutter $expectedFlutter, found $($flutterMetadata.frameworkVersion)."
}
if ($flutterMetadata.dartSdkVersion -ne $expectedDart) {
  throw "Expected Dart $expectedDart, found $($flutterMetadata.dartSdkVersion)."
}

$dartVersion = (Invoke-WindowsBatch $dartCommand @('--version') |
  Out-String).Trim()
if ($dartVersion -notmatch "Dart SDK version:?\s*$expectedDart(?:\s|\()") {
  throw "Expected Dart $expectedDart, found: $dartVersion"
}

$rustup = Get-Command rustup.exe -ErrorAction SilentlyContinue
if ($null -eq $rustup) {
  throw 'rustup.exe is required for the pinned Windows Rust toolchain.'
}
$rustVersion = (& $rustup.Path run $expectedRustToolchain rustc --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $rustVersion -notmatch "^rustc $expectedRust(?:\s|\()") {
  throw "Expected Rust $expectedRustToolchain, found: $rustVersion"
}

if ($PersistUserPath) {
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($null -eq $userPath) {
    $userPath = ''
  }
  $userEntries = @(
    $userPath -split ';' | Where-Object {
      -not [string]::IsNullOrWhiteSpace($_)
    }
  )
  $userHasFlutterBin = @($userEntries | Where-Object {
    $_.TrimEnd('\') -ieq $flutterBin.TrimEnd('\')
  })
  if ($userHasFlutterBin.Count -eq 0) {
    $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
      $flutterBin
    } else {
      "$flutterBin;$userPath"
    }
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
  }
  [Environment]::SetEnvironmentVariable(
    'SSH_MOBILE_WINDOWS_FLUTTER_ROOT',
    $resolvedFlutterRoot,
    'User'
  )
}

Write-Host "Windows Flutter SDK: $resolvedFlutterRoot"
Write-Host "Flutter $($flutterMetadata.frameworkVersion); Dart $($flutterMetadata.dartSdkVersion)"
Write-Host "Rust toolchain: $expectedRustToolchain"
Write-Host "Native TEMP/TMP: $TempRoot"
if ($PersistUserPath) {
  Write-Host 'User PATH and SSH_MOBILE_WINDOWS_FLUTTER_ROOT were updated.'
} else {
  Write-Host 'Configuration is process-scoped. Use -PersistUserPath to persist the SDK PATH.'
}
