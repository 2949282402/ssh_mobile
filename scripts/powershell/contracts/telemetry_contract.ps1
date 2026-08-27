# Verify Telemetry Data Contracts across Go, Front (TypeScript), and Dart.

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = (Resolve-Path "$scriptDir/../../..").Path

Write-Host "Validating Telemetry contracts..."

# 1. Go validation
Push-Location "$rootDir/relay"
try {
    go test ./internal/telemetry -run '^TestTelemetryContract' -count=1
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}

# 2. TypeScript / Front validation
Push-Location "$rootDir/front"
try {
    npm run test:run -- src/schemas/telemetry-contract.test.ts
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}

# 3. Dart validation
Push-Location "$rootDir"
try {
    flutter test --no-pub packages/core/app_core/test/telemetry_contract_test.dart
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}

Write-Host "Telemetry Contract validation passed."
