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

require_tools() {
  local command_name
  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "ENVIRONMENT GAP: required command is unavailable: $command_name" >&2
      exit 125
    fi
  done
}

python3 -m unittest discover \
  -s protocol/contract_tests \
  -p 'test_*.py'

if [[ "$mode" != "strict" ]]; then
  exit 0
fi

# Strict acceptance executes Flutter owner selectors. Check both the Dart
# executable used by the package tooling and the Flutter executable before any
# owner test starts, so a missing Linux toolchain is reported as an environment
# gap instead of an opaque selector failure.
require_tools dart flutter

# The strict entry point delegates behavior to the owning Rust and Go suites.
# The matrix is allowed to say covered only when the corresponding owner test
# exists; the final Python pass below rejects any open case.
(cd native/network_core && cargo test -p network-nat 'candidate_v2::tests::' --locked)
(cd native/network_core && cargo test -p network-nat 'path_manager::tests::nat_fixture_candidate_priority_prefers_direct_paths_and_keeps_relay_fallback' --locked)
(cd native/network_core && cargo test -p network-core 'path_handshake::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'crypto_handshake::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'connect::connectivity_attempt::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'connect::connectivity_attempt::tests::stage_b_resolves_and_offers_before_relay_reservation' --locked)
(cd native/network_core && cargo test -p network-core 'connect::peer_supervisor::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'peer::tests::late_quic_candidate_arriving_before_direct_deadline_can_win' --locked)
(cd native/network_core && cargo test -p network-core 'connect::path::tests::' --locked)
(cd native/network_core && cargo test -p network-core 'relay::tests::remote_candidate_cache_invalidates_on_epoch_and_ready_ttl_change' --locked)
(cd native/network_core && cargo test -p network-core 'runtime::tests::runtime_path_projection_is_non_owning' --locked)
(cd native/network_core && cargo test -p network-core 'runtime::tests::stale_session_failure_does_not_close_replacement_path' --locked)
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
(cd native/network_core && cargo test -p network-core 'peer_runtime_restart_replaces_session_and_keeps_e2ee_delivery' --locked)
(cd native/network_core && cargo test -p network-relay 'v2::' --locked)
(cd native/network_core && cargo test -p network-relay 'v2::control_client::tests::dropping_unpolled_connectivity_attempt_start_releases_tracker' --locked)
(cd native/network_core && cargo test -p network-relay 'v2::control_client::tests::old_waiter_cleanup_cannot_remove_new_same_id_tracker' --locked)
(cd native/network_core && cargo test -p network-relay --features test-support --test relay_control_client_integration --locked -- --test-threads=1)
for integration_selector in \
  dropped_connectivity_attempt_start_releases_answer_tracker \
  cancelled_connectivity_answer_waiter_releases_answer_tracker \
  concurrent_connectivity_attempts_keep_targets_isolated_and_ordered \
  control_authentication_failure_never_enters_ready_state \
  remote_control_disconnect_is_observable_and_cleans_client_state \
  control_client_disconnect_then_reconnect_succeeds
do
  (cd native/network_core && cargo test -p network-relay --features test-support \
    --test relay_control_client_integration --locked "$integration_selector" \
    -- --test-threads=1)
done
(cd native/network_core && cargo test -p network-relay-proto --locked)
(cd native/network_core && cargo test -p network-ffi --locked)

(
  cd relay
  go test ./internal/relay -run \
    'Test(ConnectExpiredCredentialReturnsCode12|AuthenticatedRequestFailsClosedWhenNonceCacheUnavailable|AuthenticatedDeviceAdmissionRechecksRevocation|AuthFailsClosedWhenCacheUnavailable|ShortCredentialTTLExpiresBeforeReadyAdmission|ReadyReportsConfiguredPresenceTTL|NetworkV2RevokeAdmissionMatrix|NetworkV2ExpiredCredentialCannotOpenDataSocket|RelayDataAdmissionBindsDeviceRoleAndToken|RelayDataCloseDeviceClosesPendingActiveAndCounterpart|RelayDataSameRoleRetryRejectsDuplicate|RelayDataPairReadyRequiresBothRoles|RelayDataRegistryRejectsDuplicateRoleAndConsumesPair|ControlV2RejectsRelayDataFrame|ControlV2ReservationAndRelayData|AdminRevokeReturnsErrorWhenRevokeFails|ReconcileRevocationsDisconnectsRevokedDevice|DisconnectDeviceDoesNotClearForeignPresence|RelayDataSlidingExpiryKeepsActiveSessionAlive|RelayDataIdleCredentialExpiryKeepsReadySessionAlive|RelayDataConnectValidation)$'
)

# Dart/mobile owner tests are part of the same strict entry point so matrix
# cases cannot be marked covered without executable package evidence.
(cd packages/infrastructure/network_transport && flutter test --no-pub test/event_mux_test.dart)
(cd packages/infrastructure/network_sdk && flutter test --no-pub test/network_v2_contract_test.dart)
(cd packages/infrastructure/network_sdk && flutter test --no-pub test/network_v2_facade_test.dart)
(cd packages/infrastructure/ssh_mobile_network_native && flutter test --no-pub test/ssh_mobile_network_native_test.dart)
SSH_MOBILE_ACCEPTANCE_STRICT=1 python3 -m unittest discover \
  -s protocol/contract_tests \
  -p 'test_*.py'
