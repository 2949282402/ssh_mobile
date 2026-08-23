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

if ([string]::IsNullOrWhiteSpace($TempRoot)) {
  $TempRoot = Join-Path ([IO.Path]::GetTempPath()) 'ssh-mobile-flutter'
}
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

$flutterVersion = (& $flutterCommand --version --machine | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
  throw "Unable to query Flutter version from $flutterCommand."
}
try {
  $flutterMetadata = $flutterVersion | ConvertFrom-Json
} catch {
  throw "Flutter --version --machine did not return JSON: $flutterVersion"
}

if ($flutterMetadata.frameworkVersion -ne $expectedFlutter) {
  throw "Expected Flutter $expectedFlutter, found $($flutterMetadata.frameworkVersion)."
}
if ($flutterMetadata.dartSdkVersion -ne $expectedDart) {
  throw "Expected Dart $expectedDart, found $($flutterMetadata.dartSdkVersion)."
}

$dartVersion = (& $dartCommand --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $dartVersion -notmatch "Dart SDK version $expectedDart(?:\s|\()") {
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
