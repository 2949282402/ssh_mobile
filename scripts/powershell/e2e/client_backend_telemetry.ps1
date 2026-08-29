# Live Analytics ingestion probe dot-sourced by client_backend_e2e.ps1.
#
# The deployment launcher owns only Compose setup.  The Rust test owns the
# device identity and keeps the one-time telemetry secret in process memory:
# Relay enrollment -> signed telemetry enrollment -> HMAC proof -> short token
# -> ingest -> expired-token 401 -> automatic re-authentication and retry.

function TelemetryIngestion {
  Assert-Commands @('cargo', 'curl.exe') 125

  $nativeRoot = Join-Path $root 'native\network_core'
  $strict = if ($Mode -eq 'strict') { '1' } else { '' }
  Invoke-CommandChecked cargo @(
    'test',
    '-p', 'network-relay',
    '--features', 'test-support',
    '--test', 'telemetry_e2e',
    '--locked',
    '--',
    '--ignored',
    '--test-threads=1'
  ) $nativeRoot @{
    CLIENT_BACKEND_E2E_BASE_URL = $base
    RELAY_ENROLLMENT_TOKEN = $token
    CLIENT_BACKEND_E2E_STRICT = $strict
  }

  # Keep a stable CI marker for the paired Bash gate and downstream log
  # collection.  No credential or response body is included in the marker.
  Write-Host 'TELEMETRY_INGESTION_PASS identity_attestation=1 token_refresh=1'
}
