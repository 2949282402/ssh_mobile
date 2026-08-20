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

# The strict entry point delegates behavior to the owning Rust and Go suites.
# The matrix is allowed to say covered only when the corresponding owner test
# exists; the final Python pass below rejects any open case.
(cd native/network_core && cargo test -p network-nat 'candidate_v2::tests::' --locked)
(cd native/network_core && cargo test -p network-nat 'path_manager::tests::nat_fixture_candidate_priority_prefers_direct_paths_and_keeps_relay_fallback' --locked)
(cd native/network_core && cargo test -p network-core 'path_handshake::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'crypto_handshake::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'connect::connectivity_attempt::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'connect::peer_supervisor::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'connect::path::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'commands::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'channel::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'transfer::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'discovery::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'discovery::recovery::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'realtime::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'delivery::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'stream::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'relay_data_clients_forward_envelopes_over_reservation' --locked)
(cd native/network_core && cargo test -p network-core 'file_transfer_resumes_across_a_fresh_connection' --locked)
(cd native/network_core && cargo test -p network-core 'delivery_recovery_replays_same_message_after_explicit_recovery' --locked)
(cd native/network_core && cargo test -p network-relay 'v2::' --locked)
(cd native/network_core && cargo test -p network-relay-proto --locked)
(cd native/network_core && cargo test -p network-ffi --locked)

(
  cd relay
  go test ./internal/relay -run \
    'Test(ConnectExpiredCredentialReturnsCode12|NetworkV2ExpiredCredentialCannotOpenDataSocket|RelayDataAdmissionBindsDeviceRoleAndToken|RelayDataCloseDeviceClosesPendingActiveAndCounterpart|RelayDataSameRoleRetryRejectsDuplicate|RelayDataPairReadyRequiresBothRoles|RelayDataRegistryRejectsDuplicateRoleAndConsumesPair|ControlV2RejectsRelayDataFrame|ControlV2ReservationAndRelayData|AdminRevokeReturnsErrorWhenRevokeFails|ReconcileRevocationsDisconnectsRevokedDevice|DisconnectDeviceDoesNotClearForeignPresence|RelayDataSlidingExpiryKeepsActiveSessionAlive|RelayDataIdleCredentialExpiryKeepsReadySessionAlive|RelayDataConnectValidation)$'
)

# Dart/mobile owner tests are part of the same strict entry point so matrix
# cases cannot be marked covered without executable package evidence.
(cd packages/infrastructure/network_transport && flutter test test/event_mux_test.dart)
(cd packages/infrastructure/network_sdk && flutter test test/network_v2_contract_test.dart)
(cd packages/infrastructure/ssh_mobile_network_native && flutter test test/ssh_mobile_network_native_test.dart)
SSH_MOBILE_ACCEPTANCE_STRICT=1 python3 -m unittest discover \
  -s protocol/contract_tests \
  -p 'test_*.py'
