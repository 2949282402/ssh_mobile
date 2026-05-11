param(
  [string]$Version = "1.0.0",
  [string]$ProductName = "SSH Mobile",
  [string]$Manufacturer = "SSH Mobile",
  [string]$Flutter = "flutter"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$releaseDir = Join-Path $repoRoot "build\windows\x64\runner\Release"
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

$heat = Find-Tool "heat.exe"
$candle = Find-Tool "candle.exe"
$light = Find-Tool "light.exe"

if (!$heat -or !$candle -or !$light) {
  New-Item -ItemType Directory -Force -Path $wixCacheDir | Out-Null
  if (!(Test-Path -LiteralPath $wixPackage)) {
    $url = "https://www.nuget.org/api/v2/package/wix/$wixVersion"
    Write-Host "WiX Toolset v3 not found locally. Downloading $url ..."
    Invoke-WebRequest -Uri $url -OutFile $wixPackage
  }
  if (!(Test-Path -LiteralPath $wixExtractDir) -or
      !(Find-ToolInDirectory "heat.exe" $wixExtractDir)) {
    Remove-Item -LiteralPath $wixExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    $wixZip = Join-Path $wixCacheDir "wix.$wixVersion.zip"
    Copy-Item -LiteralPath $wixPackage -Destination $wixZip -Force
    Expand-Archive -LiteralPath $wixZip -DestinationPath $wixExtractDir -Force
  }

  $heat = Find-ToolInDirectory "heat.exe" $wixExtractDir
  $candle = Find-ToolInDirectory "candle.exe" $wixExtractDir
  $light = Find-ToolInDirectory "light.exe" $wixExtractDir
}

if (!$heat -or !$candle -or !$light) {
  throw "WiX Toolset v3 tools were not found. Install WiX manually or check the downloaded package in $wixExtractDir."
}

Push-Location $repoRoot
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
  "-dSourceDir=$stageDir" `
  "-dProductName=$ProductName" `
  "-dProductVersion=$Version" `
  "-dManufacturer=$Manufacturer" `
  -out (Join-Path $objDir "\") `
  $productWxs $harvestWxs
if ($LASTEXITCODE -ne 0) {
  throw "candle.exe failed with exit code $LASTEXITCODE"
}

& $light -nologo `
  -out $msiPath `
  (Join-Path $objDir "Product.wixobj") `
  (Join-Path $objDir "AppFiles.wixobj")
if ($LASTEXITCODE -ne 0) {
  throw "light.exe failed with exit code $LASTEXITCODE"
}

Write-Host "MSI created: $msiPath"
