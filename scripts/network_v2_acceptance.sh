#!/usr/bin/env bash
set -euo pipefail

mode="${1:-baseline}"
case "$mode" in
  baseline|strict)
    ;;
  *)
    echo "usage: $0 [baseline|strict]" >&2
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python3 -m unittest discover \
  -s protocol/contract_tests \
  -p 'test_*.py'

if [[ "$mode" != "strict" ]]; then
  exit 0
fi

# The strict entry point delegates behavior to the owning language suites. It
# is intentionally separate from the Phase 0 baseline: the matrix records
# characterized and open cases until their end-to-end tests are implemented.
(cd native/network_core && cargo test -p network-nat 'candidate_v2::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'path_handshake::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'connect::connectivity_attempt::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'connect::peer_supervisor::tests::' --locked)

(
  cd relay
  go test ./internal/relay -run \
    'Test(ConnectExpiredCredentialReturnsCode12|NetworkV2ExpiredCredentialCannotOpenDataSocket|RelayDataAdmissionBindsDeviceRoleAndToken|RelayDataCloseDeviceClosesPendingActiveAndCounterpart|RelayDataSameRoleRetryRejectsDuplicate|RelayDataPairReadyRequiresBothRoles|ControlV2RejectsRelayDataFrame|AdminRevokeReturnsErrorWhenRevokeFails|ReconcileRevocationsDisconnectsRevokedDevice|DisconnectDeviceDoesNotClearForeignPresence|RelayDataSlidingExpiryKeepsActiveSessionAlive|RelayDataIdleCredentialExpiryKeepsReadySessionAlive|RelayDataConnectValidation)$'
)

# Dart/mobile owns its package-level gates; the final matrix check below keeps
# those results coupled to the same strict acceptance entry point.
SSH_MOBILE_ACCEPTANCE_STRICT=1 python3 -m unittest discover \
  -s protocol/contract_tests \
  -p 'test_*.py'
