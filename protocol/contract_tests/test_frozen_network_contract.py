"""Phase 0 characterization and final-gate checks for the frozen network v2 plan.

This suite deliberately stays outside Rust, Go, and Dart ownership packages. It
checks the committed wire fixtures and the evidence inventory, while the strict
runner delegates executable behavior to the owning Rust and Go test suites.
"""

from __future__ import annotations

import json
import os
import struct
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MATRIX_PATH = ROOT / "protocol/contract_tests/acceptance_matrix.json"
MANIFEST_PATH = ROOT / "protocol/relay_v2_testdata/manifest.json"


REQUIRED_CASE_IDS = {
    "candidate.fresh_stage_a",
    "candidate.expired_stage_a",
    "candidate.expired_stage_b_refresh",
    "candidate.epoch_invalidation",
    "candidate.wall_clock_jump_monotonic",
    "candidate.heartbeat_does_not_refresh",
    "candidate.ready_presence_ttl",
    "candidate.equal_revision_fingerprint",
    "relay.data_env_crypto_first",
    "relay.pre_pair_reject",
    "relay.business_before_ready_reject",
    "relay.crypto_drives_v2",
    "relay.ready_business_admission",
    "relay.opaque_payload",
    "relay.route_separation",
    "revocation.expired_control_admission",
    "revocation.expired_data_admission",
    "revocation.natural_expiry_keeps_ready",
    "revocation.pending_initiator_responder_active",
    "revocation.old_token_reconnect",
    "revocation.persistent_failure_fails_closed",
    "revocation.nonparticipant_untouched",
    "flow.stage_a_pure_direct",
    "flow.stage_b_resolve_offer",
    "flow.stage_c_relay_fallback",
    "flow.multi_peer_gate",
    "flow.role_token_pairready",
    "flow.path_lease",
    "flow.idle_ssh_240s",
    "flow.delivery_retry_resume",
    "flow.bounded_event_mux",
    "flow.mobile_versioning",
}


def _read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def _load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def _load_matrix() -> dict[str, object]:
    value = _load_json(MATRIX_PATH)
    if not isinstance(value, dict):
        raise TypeError("acceptance matrix must be a JSON object")
    return value


class FrozenNetworkContractTest(unittest.TestCase):
    def test_acceptance_matrix_is_complete_and_statused(self) -> None:
        matrix = _load_matrix()
        cases = matrix.get("cases")
        self.assertIsInstance(cases, list)
        assert isinstance(cases, list)

        case_ids = [case.get("id") for case in cases if isinstance(case, dict)]
        self.assertEqual(len(case_ids), len(set(case_ids)))
        self.assertEqual(set(case_ids), REQUIRED_CASE_IDS)

        allowed_statuses = {"covered", "characterized", "gap"}
        for case in cases:
            self.assertIsInstance(case, dict)
            assert isinstance(case, dict)
            self.assertIn(case.get("status"), allowed_statuses)
            self.assertTrue(case.get("acceptance"))
            self.assertTrue(case.get("evidence"))

        if os.environ.get("SSH_MOBILE_ACCEPTANCE_STRICT") == "1":
            open_cases = [
                case["id"] for case in cases if case["status"] != "covered"
            ]
            self.assertFalse(
                open_cases,
                "final acceptance remains open for: " + ", ".join(open_cases),
            )

    def test_matrix_evidence_paths_and_markers_are_present(self) -> None:
        matrix = _load_matrix()
        cases = matrix["cases"]
        assert isinstance(cases, list)
        for case in cases:
            assert isinstance(case, dict)
            for evidence in case["evidence"]:
                self.assertIsInstance(evidence, dict)
                assert isinstance(evidence, dict)
                relative_path = evidence["path"]
                path = ROOT / relative_path
                self.assertTrue(path.is_file(), f"missing evidence file: {path}")
                source = path.read_text(encoding="utf-8")
                for marker in evidence.get("contains", []):
                    self.assertIn(
                        marker,
                        source,
                        f"evidence marker {marker!r} missing from {path}",
                    )

    def test_relay_v2_golden_fixtures_are_framed_and_manifest_complete(self) -> None:
        manifest = _load_json(MANIFEST_PATH)
        self.assertIsInstance(manifest, dict)
        assert isinstance(manifest, dict)
        self.assertEqual(manifest.get("schema_version"), 2)

        constants = manifest.get("constants")
        self.assertIsInstance(constants, dict)
        assert isinstance(constants, dict)
        self.assertEqual(constants.get("RELAY_V2_VERSION"), 2)
        self.assertEqual(constants.get("FRAME_LENGTH_PREFIX_BYTES"), 4)
        self.assertEqual(constants.get("PRESENCE_TTL_S"), 60)

        fixtures = manifest.get("fixtures")
        self.assertIsInstance(fixtures, list)
        assert isinstance(fixtures, list)
        self.assertEqual(len(fixtures), 23)

        max_frame_bytes = constants["MAX_RELAY_FRAME_BYTES"]
        self.assertEqual(max_frame_bytes, constants["MAX_RELAY_DATA_FRAME_BYTES"])
        for fixture in fixtures:
            self.assertIsInstance(fixture, dict)
            assert isinstance(fixture, dict)
            path = MANIFEST_PATH.parent / fixture["file"]
            self.assertTrue(path.is_file(), f"missing fixture: {path}")
            payload = path.read_bytes()
            self.assertGreaterEqual(len(payload), 4, path.name)
            declared_length = struct.unpack(">I", payload[:4])[0]
            self.assertEqual(declared_length, len(payload) - 4, path.name)
            self.assertLessEqual(len(payload), max_frame_bytes, path.name)

        sequence = _load_json(
            ROOT / "protocol/relay_v2_testdata/session_sequence.golden.json"
        )
        self.assertIsInstance(sequence, dict)
        assert isinstance(sequence, dict)
        self.assertTrue(sequence.get("sequence"))

    def test_relay_data_contract_is_opaque_and_route_scoped(self) -> None:
        proto = _read("protocol/proto/relay/v2/relay_v2.proto")
        self.assertIn("message RelayDataPayload", proto)
        self.assertIn("bytes encrypted_payload = 2", proto)
        self.assertIn("opaque; relay never decrypts or parses", proto)

        contract = _read("protocol/RELAY_V2_CONTRACT.md")
        self.assertIn("Relay NEVER parses", contract)
        self.assertIn("`encrypted_payload`", contract)
        self.assertIn("Offering the wrong envelope type on a", contract)
        self.assertIn("route is a protocol violation", contract)

    def test_relay_dispatch_checks_path_admission_before_business_dispatch(self) -> None:
        relay = _read("native/network_core/crates/network-core/src/relay.rs")
        guard_start = relay.index("if kind != DATA_ENV_CRYPTO")
        match_start = relay.index("match kind", guard_start)
        self.assertLess(guard_start, match_start)
        guard = relay[guard_start:match_start]
        self.assertIn("relay_path_ready", guard)
        self.assertIn("business envelope rejected", guard)

    def test_candidate_cache_evidence_uses_monotonic_ttl_and_epoch_rules(self) -> None:
        cache = _read("native/network_core/crates/network-nat/src/candidate_v2.rs")
        self.assertIn("Instant", cache)
        self.assertIn("now.saturating_duration_since(self.learned_at)", cache)
        self.assertIn("server_presence_ttl", cache)
        self.assertIn("invalidate_for_remote_epoch", cache)
        self.assertIn("SameRevisionDifferentFingerprint", cache)
        self.assertIn("self.learned_at.max(learned_at)", cache)

    def test_revocation_matrix_has_control_data_and_storage_evidence(self) -> None:
        control = _read("relay/internal/relay/control_v2_test.go")
        storage = _read("relay/internal/relay/fix_package_a_test.go")
        self.assertIn("TestRelayDataCloseDeviceClosesPendingActiveAndCounterpart", control)
        self.assertIn("TestRelayDataAdmissionBindsDeviceRoleAndToken", control)
        self.assertIn("TestAdminRevokeReturnsErrorWhenRevokeFails", storage)
        self.assertIn("TestDisconnectDeviceDoesNotClearForeignPresence", storage)

    def test_bounded_peer_supervisor_and_event_mux_are_bounded(self) -> None:
        supervisor = _read(
            "native/network_core/crates/network-core/src/connect/peer_supervisor.rs"
        )
        self.assertIn("PEER_MAILBOX_CAPACITY", supervisor)
        self.assertIn("MAX_PEER_WAITERS", supervisor)
        self.assertIn("mailbox_and_resource_limits_are_bounded", supervisor)

        events = _read("native/network_core/crates/network-core/src/events.rs")
        self.assertNotIn("UnboundedSender", events)
        runtime = _read("native/network_core/crates/network-core/src/runtime.rs")
        self.assertIn("EVENT_MAILBOX_CAPACITY", runtime)
        self.assertIn("MAX_EVENT_QUEUE_BYTES", runtime)
        ffi = _read("native/network_core/crates/network-ffi/src/lib.rs")
        self.assertIn("event_mux_applies_bounded_control_data_fairness", ffi)
        matrix = _load_matrix()
        cases = {case["id"]: case for case in matrix["cases"]}
        self.assertEqual(cases["flow.bounded_event_mux"]["status"], "covered")

    def test_ci_runs_the_phase_zero_baseline(self) -> None:
        workflow = _read(".github/workflows/flutter.yml")
        self.assertIn("bash scripts/network_v2_acceptance.sh baseline", workflow)


if __name__ == "__main__":
    unittest.main()
