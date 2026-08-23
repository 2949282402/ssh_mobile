[CmdletBinding()]
param(
  [string]$Version = "1.0.0",
  [string]$ProductName = "SSH Mobile",
  [string]$Manufacturer = "SSH Mobile",
  [string]$Flutter = "flutter",
  [string]$TempRoot = $env:SSH_MOBILE_WINDOWS_TEMP,
  [switch]$SuppressIceValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression

$currentLocation = (Get-Location).ProviderPath
if ($PSVersionTable.PSVersion.Major -lt 7) {
  throw 'PowerShell 7 or newer is required on Windows. Start pwsh.exe, not Windows PowerShell 5.1.'
}
if ($currentLocation -match '^(\\\\wsl|/mnt/)') {
  throw 'Run the MSI builder from a native Windows path; do not inherit a WSL UNC working directory.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot ".." -ErrorAction Stop)).ProviderPath

# WSL-launched PowerShell can inherit a Linux temporary directory and a
# truncated PATHEXT.  Both make MSBuild's manifest step fail even when the
# Flutter/Dart/Rust versions are correct.
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC'
if ([string]::IsNullOrWhiteSpace($TempRoot) -or $TempRoot -match '^(\\\\wsl|/mnt/|/tmp/)') {
  $systemDrive = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) {
    'C:'
  } else {
    $env:SystemDrive
  }
  $TempRoot = Join-Path $systemDrive 'Temp\ssh-mobile'
}
New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
$env:TEMP = $TempRoot
$env:TMP = $TempRoot
if (Test-Path Env:TMPDIR) {
  Remove-Item Env:TMPDIR
}
$env:RUSTUP_TOOLCHAIN = '1.97.1-x86_64-pc-windows-msvc'

$windowsSdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$windowsSdkVersion = Get-ChildItem -LiteralPath $windowsSdkRoot -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^10\.' } |
  Sort-Object Name -Descending |
  Select-Object -First 1
if ($null -eq $windowsSdkVersion) {
  throw "Windows 10 SDK was not found under $windowsSdkRoot."
}
$windowsSdkBin = Join-Path $windowsSdkVersion.FullName 'x64'
foreach ($requiredTool in @('mt.exe', 'rc.exe')) {
  if (-not (Test-Path -LiteralPath (Join-Path $windowsSdkBin $requiredTool) -PathType Leaf)) {
    throw "Windows SDK tool is missing: $(Join-Path $windowsSdkBin $requiredTool)"
  }
}
$env:Path = "$windowsSdkBin;$env:Path"
$env:WindowsSdkDir = "$(Split-Path -Parent $windowsSdkVersion.FullName)\"
$env:WindowsSDKVersion = "$($windowsSdkVersion.Name)\"

$appDir = Join-Path $repoRoot "apps\ssh_mobile_full"
# Full App 已迁移到 workspace member；构建与产物路径必须以 App 目录为 Owner。
$releaseDir = Join-Path $appDir "build\windows\x64\runner\Release"
$workDir = Join-Path $repoRoot "build\windows_msi"
$stageDir = Join-Path $workDir "stage"
$objDir = Join-Path $workDir "obj"
$outDir = Join-Path $workDir "out"
$productWxs = Join-Path $repoRoot "installer\windows\Product.wxs"
$harvestWxs = Join-Path $workDir "AppFiles.wxs"
$msiPath = Join-Path $outDir ("SSH_Mobile_Windows_v{0}_setup.msi" -f $Version)
$wixVersion = "3.14.1"
$wixCacheDir = Join-Path $repoRoot "build\wix"
$wixPackage = Join-Path $wixCacheDir "wix.$wixVersion.nupkg"
$wixExtractDir = Join-Path $wixCacheDir "wix.$wixVersion"

function Find-Tool($name) {
  $command = Get-Command $name -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  $candidates = @(
    "${env:ProgramFiles(x86)}\WiX Toolset v3.14\bin\$name",
    "${env:ProgramFiles(x86)}\WiX Toolset v3.11\bin\$name",
    "$env:ProgramFiles\WiX Toolset v3.14\bin\$name",
    "$env:ProgramFiles\WiX Toolset v3.11\bin\$name"
  )

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }

  return $null
}

function Find-ToolInDirectory($name, $directory) {
  if (!(Test-Path -LiteralPath $directory)) {
    return $null
  }
  $match = Get-ChildItem -LiteralPath $directory -Recurse -Filter $name -File -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($match) {
    return $match.FullName
  }
  return $null
}

function Save-RemoteFile($url, $destination) {
  $curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue
  if ($curl) {
    & $curl.Source --fail --location --retry 3 --retry-delay 2 --silent --show-error --output $destination $url
    if ($LASTEXITCODE -ne 0) {
      throw "curl.exe failed to download $url with exit code $LASTEXITCODE"
    }
    return
  }

  Invoke-WebRequest -Uri $url -OutFile $destination
}

function Test-WixPackage($path) {
  if (!(Test-Path -LiteralPath $path)) {
    return $false
  }

  $stream = $null
  $archive = $null
  try {
    $stream = [IO.File]::OpenRead($path)
    $archive = [IO.Compression.ZipArchive]::new(
      $stream,
      [IO.Compression.ZipArchiveMode]::Read,
      $false
    )
    $entryNames = $archive.Entries | ForEach-Object { $_.Name }
    foreach ($requiredName in @(
        "heat.exe",
        "candle.exe",
        "light.exe",
        "WixFirewallExtension.dll"
      )) {
      if ($entryNames -notcontains $requiredName) {
        return $false
      }
    }
    return $true
  } catch {
    return $false
  } finally {
    if ($archive) {
      $archive.Dispose()
    }
    if ($stream) {
      $stream.Dispose()
    }
  }
}

$heat = Find-Tool "heat.exe"
$candle = Find-Tool "candle.exe"
$light = Find-Tool "light.exe"
$firewallExtension = Find-Tool "WixFirewallExtension.dll"

if (!$heat -or !$candle -or !$light -or !$firewallExtension) {
  New-Item -ItemType Directory -Force -Path $wixCacheDir | Out-Null
  if (!(Test-WixPackage $wixPackage)) {
    Remove-Item -LiteralPath $wixPackage -Force -ErrorAction SilentlyContinue
    $downloadPath = "$wixPackage.download"
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    $url = "https://api.nuget.org/v3-flatcontainer/wix/$wixVersion/wix.$wixVersion.nupkg"
    Write-Host "WiX Toolset v3 not found locally. Downloading $url ..."
    try {
      Save-RemoteFile $url $downloadPath
      if (!(Test-WixPackage $downloadPath)) {
        throw "Downloaded WiX package is incomplete or does not contain the required tools."
      }
      Move-Item -LiteralPath $downloadPath -Destination $wixPackage -Force
    } finally {
      Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    }
  }
  if (!(Test-Path -LiteralPath $wixExtractDir) -or
      !(Find-ToolInDirectory "heat.exe" $wixExtractDir) -or
      !(Find-ToolInDirectory "candle.exe" $wixExtractDir) -or
      !(Find-ToolInDirectory "light.exe" $wixExtractDir) -or
      !(Find-ToolInDirectory "WixFirewallExtension.dll" $wixExtractDir)) {
    Remove-Item -LiteralPath $wixExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    $wixZip = Join-Path $wixCacheDir "wix.$wixVersion.zip"
    Copy-Item -LiteralPath $wixPackage -Destination $wixZip -Force
    Expand-Archive -LiteralPath $wixZip -DestinationPath $wixExtractDir -Force
  }

  $heat = Find-ToolInDirectory "heat.exe" $wixExtractDir
  $candle = Find-ToolInDirectory "candle.exe" $wixExtractDir
  $light = Find-ToolInDirectory "light.exe" $wixExtractDir
  $firewallExtension = Find-ToolInDirectory "WixFirewallExtension.dll" $wixExtractDir
}

if (!$heat -or !$candle -or !$light -or !$firewallExtension) {
  throw "WiX Toolset v3 tools and WixFirewallExtension.dll were not found. Install WiX manually or check the downloaded package in $wixExtractDir."
}

Push-Location $appDir
try {
  & $Flutter build windows
  if ($LASTEXITCODE -ne 0) {
    throw "flutter build windows failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}

Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stageDir, $objDir, $outDir | Out-Null

Get-ChildItem -LiteralPath $releaseDir -Force |
  Where-Object { $_.Name -notlike "*.msix" } |
  ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $stageDir -Recurse -Force
  }

& $heat dir $stageDir -cg AppFiles -dr INSTALLFOLDER -srd -sreg -scom -gg -var var.SourceDir -out $harvestWxs
if ($LASTEXITCODE -ne 0) {
  throw "heat.exe failed with exit code $LASTEXITCODE"
}

& $candle -arch x64 `
  -ext $firewallExtension `
  "-dSourceDir=$stageDir" `
  "-dProductName=$ProductName" `
  "-dProductVersion=$Version" `
  "-dManufacturer=$Manufacturer" `
  -out (Join-Path $objDir "\") `
  $productWxs $harvestWxs
if ($LASTEXITCODE -ne 0) {
  throw "candle.exe failed with exit code $LASTEXITCODE"
}

$lightArguments = @(
  '-nologo',
  '-ext', $firewallExtension,
  '-out', $msiPath,
  (Join-Path $objDir "Product.wixobj"),
  (Join-Path $objDir "AppFiles.wixobj")
)
if ($SuppressIceValidation) {
  Write-Warning 'WiX ICE validation is suppressed for this package run; validate the MSI separately on a host with Windows Installer ICE support.'
  $lightArguments = @('-sice:*') + $lightArguments
}
& $light @lightArguments
if ($LASTEXITCODE -ne 0) {
  throw "light.exe failed with exit code $LASTEXITCODE"
}

Write-Host "MSI created: $msiPath"
