[CmdletBinding()]
param([ValidateSet('baseline','strict')][string]$Mode='baseline', [string]$TempRoot=$env:SSH_MOBILE_WINDOWS_TEMP)
. (Join-Path $PSScriptRoot '..\common\powershell_common.ps1')
Assert-NativeWindowsPowerShell
$root=Get-RepositoryRoot
Initialize-NativeEnvironment $TempRoot | Out-Null
Assert-Commands @('python') 125
Invoke-CommandChecked python @('-m','unittest','discover','-s','protocol/contract_tests','-p','test_*.py') $root
if ($Mode -ne 'strict') { exit 0 }
Assert-Commands @('dart','flutter','cargo','go') 125
$native=Join-Path $root 'native\network_core'
$checks=@(
 @('network-nat','candidate_v2::tests::'),
 @('network-nat','path_manager::tests::nat_fixture_candidate_priority_prefers_direct_paths_and_keeps_relay_fallback'),
 @('network-core','path_handshake::tests::'),@('network-core','crypto_handshake::tests::'),
 @('network-core','connect::connectivity_attempt::tests::'),
 @('network-core','connect::connectivity_attempt::tests::stage_b_resolves_and_offers_before_relay_reservation'),
 @('network-core','connect::peer_supervisor::tests::'),
 @('network-core','peer::tests::late_quic_candidate_arriving_before_direct_deadline_can_win'),
 @('network-core','connect::path::tests::'),
 @('network-core','relay::tests::remote_candidate_cache_invalidates_on_epoch_and_ready_ttl_change'),
 @('network-core','runtime::tests::runtime_path_projection_is_non_owning'),
 @('network-core','runtime::tests::stale_session_failure_does_not_close_replacement_path'),
 @('network-core','commands::tests::'),@('network-core','channel::tests::'),@('network-core','transfer::tests::'),
 @('network-core','discovery::tests::'),@('network-core','discovery::recovery::tests::'),@('network-core','realtime::tests::'),
 @('network-core','delivery::tests::'),@('network-core','stream::tests::'),
 @('network-core','relay_data_clients_forward_envelopes_over_reservation'),
 @('network-core','file_transfer_resumes_across_a_fresh_connection'),
 @('network-core','delivery_recovery_replays_same_message_after_explicit_recovery'),
 @('network-core','peer_runtime_restart_replaces_session_and_keeps_e2ee_delivery'),
 @('network-relay','v2::'),
 @('network-relay','v2::control_client::tests::dropping_unpolled_connectivity_attempt_start_releases_tracker'),
 @('network-relay','v2::control_client::tests::old_waiter_cleanup_cannot_remove_new_same_id_tracker')
)
foreach($check in $checks){ Invoke-CommandChecked cargo @('test','-p',$check[0],$check[1],'--locked') $native }
Invoke-CommandChecked cargo @('test','-p','network-relay','--features','test-support','--test','relay_control_client_integration','--locked','--','--test-threads=1') $native
foreach($selector in @('dropped_connectivity_attempt_start_releases_answer_tracker','cancelled_connectivity_answer_waiter_releases_answer_tracker','concurrent_connectivity_attempts_keep_targets_isolated_and_ordered','control_authentication_failure_never_enters_ready_state','remote_control_disconnect_is_observable_and_cleans_client_state','control_client_disconnect_then_reconnect_succeeds')){
 Invoke-CommandChecked cargo @('test','-p','network-relay','--features','test-support','--test','relay_control_client_integration','--locked',$selector,'--','--test-threads=1') $native
}
Invoke-CommandChecked cargo @('test','-p','network-relay-proto','--locked') $native
Invoke-CommandChecked cargo @('test','-p','network-ffi','--locked') $native
$goSelector='Test(ConnectExpiredCredentialReturnsCode12|AuthenticatedRequestFailsClosedWhenNonceCacheUnavailable|AuthenticatedDeviceAdmissionRechecksRevocation|AuthFailsClosedWhenCacheUnavailable|ShortCredentialTTLExpiresBeforeReadyAdmission|ReadyReportsConfiguredPresenceTTL|NetworkV2RevokeAdmissionMatrix|NetworkV2ExpiredCredentialCannotOpenDataSocket|RelayDataAdmissionBindsDeviceRoleAndToken|RelayDataCloseDeviceClosesPendingActiveAndCounterpart|RelayDataSameRoleRetryReplacesPendingEndpoint|RelayDataSameRoleRetryInvalidatesActivePairAndRequiresFreshCounterpart|RelayDataPairReadyRequiresBothRoles|RelayDataRegistryPairReadyBarrierAbortsPartialQueue|ControlV2RejectsRelayDataFrame|ControlV2ReservationAndRelayData|AdminRevokeReturnsErrorWhenRevokeFails|ReconcileRevocationsDisconnectsRevokedDevice|DisconnectDeviceDoesNotClearForeignPresence|RelayDataSlidingExpiryKeepsActiveSessionAlive|RelayDataIdleCredentialExpiryKeepsReadySessionAlive|RelayDataConnectValidation)'
Invoke-CommandChecked go @('test','./internal/relay','-run',$goSelector) (Join-Path $root 'relay')
foreach($test in @(@('packages\infrastructure\network_transport','test/event_mux_test.dart'),@('packages\infrastructure\network_sdk','test/network_v2_contract_test.dart'),@('packages\infrastructure\network_sdk','test/network_v2_facade_test.dart'),@('packages\infrastructure\ssh_mobile_network_native','test/ssh_mobile_network_native_test.dart'))){
 Invoke-CommandChecked flutter @('test','--no-pub',$test[1]) (Join-Path $root $test[0])
}
Invoke-CommandChecked python @('-m','unittest','discover','-s','protocol/contract_tests','-p','test_*.py') $root @{SSH_MOBILE_ACCEPTANCE_STRICT='1'}
