"""Phase 0 characterization and final-gate checks for the frozen network v2 plan.

This suite deliberately stays outside Rust, Go, and Dart ownership packages. It
checks the committed wire fixtures and the evidence inventory, while the strict
runner delegates executable behavior to the owning Rust, Go, and Dart test
selectors.
"""

from __future__ import annotations

import json
import os
import re
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
    "flow.stage_b_ownership_before_offer",
    "flow.late_quic_candidate",
    "flow.stage_c_relay_fallback",
    "flow.multi_peer_gate",
    "flow.role_token_pairready",
    "flow.path_lease",
    "flow.idle_ssh_240s",
    "flow.delivery_retry_resume",
    "flow.bounded_event_mux",
    "flow.mobile_versioning",
    "ensure.stronger_requirement_extends_active_probe",
    "ensure.weaker_path_does_not_complete_stronger_waiter",
    "ensure.business_keeps_maintain_false",
    "business.message_auto_ensure",
    "business.transfer_auto_ensure",
    "business.stream_auto_ensure",
    "ownership.peer_path_manager_sole_carrier_owner",
    "ownership.no_second_strong_carrier_truth",
    "ownership.stale_session_preserves_replacement_path",
    "ownership.relay_tracker_drop_cleanup",
    "ownership.relay_tracker_waiter_cancellation",
    "ownership.relay_tracker_stale_owner",
    "relay.control_auth_disconnect_reconnect",
    "flow.connection_boundary_failures",
    "flow.cancelled_connect_reconnect",
    "flow.timeout_connect_reconnect",
    "relay.protocol_frame_validation",
    "security.direct_disabled_business",
    "security.required_disabled_mismatch",
    "security.relay_disabled_rejected",
    "transfer.resume_with_new_session_id",
    "stream.lifetime_path_lease",
    "stream.normal_retire_drain",
    "stream.hard_close_revocation",
    "peer.passive_inbound_online",
    "peer.passive_inbound_no_maintenance",
    "environment.maintain_false_preserved",
    "environment.maintain_true_preserved",
    "environment.relay_survives",
    "environment.realtime_survives",
    "recovery.relay_ready_not_blocked",
    "recovery.direct_backoff",
    "path.equivalent_loser",
    "path.weaker_loser",
    "path.strict_superset_promotion",
    "event.control_not_starved_by_data",
    "diagnostics.real_owner_counts",
}


def _read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def _source_paths(path: Path) -> list[Path]:
    """Return a source file and any extracted Rust test sidecar(s).

    The acceptance matrix names the owning production module, while Rust test
    implementations live under ``src/tests``.  Static evidence and behavior
    checks must inspect both locations after that migration.
    """
    paths: list[Path] = []
    if path.is_file():
        paths.append(path)

    src_root = next((parent for parent in path.parents if parent.name == "src"), None)
    if src_root is None:
        return paths

    if path.name == "tests.rs":
        sidecar_root = src_root / "tests"
        if sidecar_root.is_dir():
            paths.extend(sorted(sidecar_root.rglob("*.rs")))
        return list(dict.fromkeys(paths))

    relative = path.relative_to(src_root)
    if relative.name == "lib.rs":
        relative = relative.with_name("mod.rs")
    sidecar_root = src_root / "tests"
    for sidecar in (sidecar_root / relative, sidecar_root / relative.name):
        if sidecar.is_file():
            paths.append(sidecar)
    return list(dict.fromkeys(paths))


def _read_with_tests(relative_path: str) -> str:
    path = ROOT / relative_path
    paths = _source_paths(path)
    if not paths:
        # Preserve Path.read_text's useful missing-target error for a genuinely
        # invalid matrix entry.
        return path.read_text(encoding="utf-8")
    return "\n".join(source.read_text(encoding="utf-8") for source in paths)


def _load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def _load_matrix() -> dict[str, object]:
    value = _load_json(MATRIX_PATH)
    if not isinstance(value, dict):
        raise TypeError("acceptance matrix must be a JSON object")
    return value


def _production_sources() -> list[Path]:
    roots = (
        ROOT / "native/network_core/crates",
        ROOT / "relay/internal",
        ROOT / "packages/infrastructure",
        ROOT / "protocol/proto",
    )
    suffixes = {".rs", ".go", ".dart", ".proto"}
    sources: list[Path] = []
    for root in roots:
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix not in suffixes:
                continue
            if path.name.endswith("_test.go") or path.name == "tests.rs":
                continue
            if "test" in path.parts:
                continue
            sources.append(path)
    return sources


def _without_comments(source: str) -> str:
    return re.sub(r"//[^\n]*|/\*.*?\*/", "", source, flags=re.DOTALL)


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
                sources = _source_paths(path)
                self.assertTrue(sources, f"missing evidence file: {path}")
                source = "\n".join(
                    candidate.read_text(encoding="utf-8") for candidate in sources
                )
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
        self.assertEqual(len(fixtures), 22)

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
        self.assertNotIn("message RelayDataReady", proto)
        self.assertNotIn("ready = 14", proto)

        offer_start = proto.index("message ConnectivityOffer {")
        offer_end = proto.index("}\n", offer_start)
        self.assertNotIn("target_device_id", proto[offer_start:offer_end])

        signal_start = proto.index("message RealtimeSignal {")
        signal_end = proto.index("}\n", signal_start)
        signal = proto[signal_start:signal_end]
        self.assertIn("string target_device_id = 3", signal)
        self.assertNotIn("sender_device_id", signal)

        contract = _read("protocol/RELAY_V2_CONTRACT.md")
        self.assertIn("Relay NEVER parses", contract)
        self.assertIn("`encrypted_payload`", contract)
        self.assertIn("Offering the wrong envelope type on a", contract)
        self.assertIn("route is a protocol violation", contract)
        self.assertIn("Resolve → Offer", contract)
        self.assertIn("WebSocket Ping", contract)
        self.assertIn("active data lifetime", contract)
        self.assertIn("no `RelayDataReady`", contract)
        self.assertIn("no `sender_device_id`", contract)

    def test_relay_dispatch_checks_path_admission_before_business_dispatch(self) -> None:
        relay = _read("native/network_core/crates/network-core/src/relay_data.rs")
        guard_start = relay.index("if kind != DATA_ENV_CRYPTO")
        match_start = relay.index("match kind", guard_start)
        self.assertLess(guard_start, match_start)
        guard = relay[guard_start:match_start]
        self.assertIn("relay_path_ready", guard)
        self.assertIn("business envelope rejected", guard)

    def test_candidate_cache_evidence_uses_monotonic_ttl_and_epoch_rules(self) -> None:
        cache = _read_with_tests(
            "native/network_core/crates/network-nat/src/candidate_v2.rs"
        )
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
        supervisor = _read_with_tests(
            "native/network_core/crates/network-core/src/connect/peer_supervisor.rs"
        )
        self.assertIn("PEER_MAILBOX_CAPACITY", supervisor)
        self.assertIn("MAX_PEER_WAITERS", supervisor)
        self.assertIn("mailbox_and_resource_limits_are_bounded", supervisor)

        events = _read("native/network_core/crates/network-core/src/events.rs")
        self.assertNotIn("UnboundedSender", events)
        event_lanes = _read_with_tests(
            "native/network_core/crates/network-core/src/runtime_event_lanes.rs"
        )
        self.assertIn("EVENT_MAILBOX_CAPACITY", event_lanes)
        self.assertIn("MAX_EVENT_QUEUE_BYTES", event_lanes)
        self.assertIn("EventSender::Bounded", event_lanes)
        ffi = _read("native/network_core/crates/network-ffi/src/lib.rs")
        self.assertIn("EventMux", ffi)
        self.assertIn("SSH_NET_MAX_CONSECUTIVE_CONTROL_EVENTS", ffi)
        matrix = _load_matrix()
        cases = {case["id"]: case for case in matrix["cases"]}
        self.assertEqual(cases["flow.bounded_event_mux"]["status"], "covered")

    def test_ci_runs_the_final_strict_acceptance_gate(self) -> None:
        workflow = _read(".github/workflows/flutter.yml")
        self.assertIn("bash scripts/network_v2_acceptance.sh strict", workflow)
        self.assertNotIn("bash scripts/network_v2_acceptance.sh baseline", workflow)

    def test_strict_selectors_cover_matrix_behavior_tests(self) -> None:
        """Keep the committed owner-test inventory executable by the strict gate."""
        script = _read("scripts/network_v2_acceptance.sh")
        matrix = _load_matrix()
        for case in matrix["cases"]:
            assert isinstance(case, dict)
            verification = case.get("behavioral_verification")
            assert isinstance(verification, dict)
            for test in verification["tests"]:
                assert isinstance(test, dict)
                owner = test["owner"]
                path = test["path"]
                name = test["name"]
                if owner == "go":
                    selector_name = name.removeprefix("Test")
                    self.assertIn(
                        selector_name,
                        script,
                        f"Go matrix test {name!r} is not selected by strict acceptance",
                    )
                    continue
                if owner == "dart":
                    selector_path = path.split("/test/", 1)[-1]
                    self.assertIn(
                        selector_path,
                        script,
                        f"Dart matrix file {selector_path!r} is not selected",
                    )
                    continue

                self.assertEqual(owner, "rust")
                crate = path.split("/crates/", 1)[1].split("/", 1)[0]
                self.assertIn(f"cargo test -p {crate}", script)
                if "/tests/" in path:
                    integration_test = path.split("/tests/", 1)[1].removesuffix(".rs")
                    self.assertIn(
                        f"--test {integration_test}",
                        script,
                        f"Rust integration target {integration_test!r} is not selected",
                    )
                    self.assertIn(
                        name,
                        script,
                        f"Rust integration test {name!r} is not selected",
                    )
                    continue
                source = path.split("/src/", 1)[1]
                if source == "tests.rs":
                    self.assertIn(
                        name,
                        script,
                        f"Rust crate-level matrix test {name!r} is not selected",
                    )
                elif crate in {"network-ffi", "network-relay-proto"}:
                    # These owner commands intentionally run the complete small
                    # crate because the matrix tests share its ABI/manifest gate.
                    continue
                elif crate == "network-relay":
                    module = source.split("/", 1)[0]
                    self.assertIn(f"'{module}::", script)
                elif crate == "network-nat" and source == "path_manager.rs":
                    self.assertIn(
                        name,
                        script,
                        f"Rust path-manager matrix test {name!r} is not selected",
                    )
                else:
                    if source.endswith("/mod.rs"):
                        module = source[: -len("/mod.rs")]
                    else:
                        module = source[: -len(".rs")]
                    module = module.replace("/", "::")
                    self.assertIn(
                        f"'{module}::tests::",
                        script,
                        f"Rust module selector for {path} is missing",
                    )

    def test_acceptance_flutter_preflight_and_no_pub_selectors(self) -> None:
        script = _read("scripts/network_v2_acceptance.sh")
        self.assertIn("require_tools dart flutter", script)
        self.assertIn('command -v "$command_name"', script)
        for selector in (
            "test/event_mux_test.dart",
            "test/network_v2_contract_test.dart",
            "test/network_v2_facade_test.dart",
            "test/ssh_mobile_network_native_test.dart",
        ):
            self.assertIn(f"flutter test --no-pub {selector}", script)

    def test_protocol_job_preflights_flutter_and_coverage_gate_is_opt_in(self) -> None:
        full_test = _read("scripts/full_test.sh")
        coverage_test = _read("scripts/coverage_test.sh")
        client_coverage = _read("scripts/client_coverage.sh")
        protocol_job = re.search(
            r"job_protocol\(\) \{(.*?)\n\}", full_test, flags=re.DOTALL
        )
        self.assertIsNotNone(protocol_job)
        assert protocol_job is not None
        self.assertIn("need bash cargo go python3 protoc buf dart flutter", protocol_job.group(1))
        self.assertIn('DEFAULT_APP_COVERAGE="${FULL_TEST_COVERAGE:-0}"', full_test)
        self.assertIn("scripts/client_coverage.sh", full_test)
        self.assertIn("client_coverage.sh", coverage_test)
        self.assertIn('MINIMUM="${CLIENT_COVERAGE_MINIMUM:-80}"', client_coverage)
        self.assertIn("--include=lib/services/network/", client_coverage)
        self.assertIn("record_skip app-coverage", full_test)

        self.assertIn("@vitest/coverage-v8", _read("scripts/front_coverage.sh") + _read("front/package.json"))
        self.assertIn('MINIMUM="${BACKEND_COVERAGE_MINIMUM:-80}"', _read("scripts/backend_coverage.sh"))
        self.assertIn('MINIMUM="${CLIENT_COVERAGE_MINIMUM:-80}"', client_coverage)
        self.assertIn('MINIMUM="${SDK_COVERAGE_MINIMUM:-80}"', _read("scripts/sdk_coverage.sh"))

    def test_relay_readme_documents_v2_transport_routes_only(self) -> None:
        readme = _read("relay/README.md")
        self.assertIn("`GET /v2/control`", readme)
        self.assertIn("`GET /v2/relay/{reservation_id}`", readme)
        self.assertIn("There is no `/v1/connect` route", readme)
        self.assertNotIn("- `GET /v1/connect`", readme)
        self.assertNotIn("## WebSocket protocol v1", readme)

    def test_marker_evidence_is_not_behavior_coverage(self) -> None:
        matrix = _load_matrix()
        policy = matrix.get("evidence_policy")
        self.assertIsInstance(policy, dict)
        assert isinstance(policy, dict)
        self.assertEqual(policy.get("source_markers"), "inventory_only")
        self.assertEqual(policy.get("covered_requires"), "owner_behavior_test")
        for case in matrix["cases"]:
            assert isinstance(case, dict)
            if case["status"] == "covered":
                verification = case.get("behavioral_verification")
                self.assertIsInstance(verification, dict)
                assert isinstance(verification, dict)
                self.assertEqual(verification.get("kind"), "owner_behavior_test")
                tests = verification.get("tests")
                self.assertIsInstance(tests, list)
                assert isinstance(tests, list)
                self.assertTrue(tests)
                for test in tests:
                    self.assertIsInstance(test, dict)
                    assert isinstance(test, dict)
                    self.assertIn(test.get("owner"), {"rust", "go", "dart"})
                    path = ROOT / test["path"]
                    sources = _source_paths(path)
                    self.assertTrue(sources, f"missing behavior test: {path}")
                    source = "\n".join(
                        candidate.read_text(encoding="utf-8") for candidate in sources
                    )
                    name = re.escape(test["name"])
                    if test["owner"] == "rust":
                        pattern = (
                            rf"(?m)^\s*#\[(?:tokio::)?test[^\]]*\]\s*"
                            rf"(?:async\s+)?fn\s+{name}\s*\("
                        )
                    elif test["owner"] == "go":
                        pattern = rf"(?m)^\s*func\s+{name}\s*\("
                    else:
                        pattern = rf"\btest(?:Widgets)?\s*\(\s*['\"]{name}['\"]"
                    self.assertRegex(
                        source,
                        pattern,
                        f"behavior test {test['name']!r} is not a test declaration in {path}",
                    )

    def test_forbidden_stale_production_concepts_are_absent(self) -> None:
        """Static drift guard; this does not assert runtime lifecycle behavior."""
        if os.environ.get("SSH_MOBILE_ACCEPTANCE_STRICT") != "1":
            self.skipTest("architecture guards run in strict acceptance")
        forbidden = (
            "network.v1",
            "ConnectionRegistry",
            "NeedsReplacement",
            "RelayDataReady",
        )
        offenders = []
        for path in _production_sources():
            source = _without_comments(path.read_text(encoding="utf-8"))
            for concept in forbidden:
                if concept in source:
                    offenders.append(f"{path.relative_to(ROOT)}: {concept}")
        self.assertEqual([], offenders, "stale production concepts: " + ", ".join(offenders))

        session_source = _without_comments(
            _read("native/network_core/crates/network-core/src/session.rs")
        )
        self.assertNotRegex(
            session_source,
            r"required_capabilities|current_route|current_relay_data",
        )

    def test_frozen_field_shapes_have_no_stale_compatibility_fields(self) -> None:
        if os.environ.get("SSH_MOBILE_ACCEPTANCE_STRICT") != "1":
            self.skipTest("architecture guards run in strict acceptance")
        proto = _without_comments(_read("protocol/proto/relay/v2/relay_v2.proto"))
        offer = re.search(
            r"message\s+ConnectivityOffer\s*\{(.*?)\n\}", proto, flags=re.DOTALL
        )
        signal = re.search(
            r"message\s+RealtimeSignal\s*\{(.*?)\n\}", proto, flags=re.DOTALL
        )
        self.assertIsNotNone(offer)
        self.assertIsNotNone(signal)
        assert offer is not None and signal is not None
        self.assertNotIn("target_device_id", offer.group(1))
        self.assertNotIn("sender_device_id", signal.group(1))

    def test_runtime_has_no_obvious_second_strong_physical_path_registry(self) -> None:
        """A source-shape guard for duplicate carrier ownership, not a lifecycle proof."""
        if os.environ.get("SSH_MOBILE_ACCEPTANCE_STRICT") != "1":
            self.skipTest("architecture guards run in strict acceptance")
        runtime = _read("native/network_core/crates/network-core/src/runtime.rs")
        self.assertNotRegex(
            runtime,
            r"struct\s+OwnedTransportPath\s*\{.*?\broute:\s*Arc<PhysicalRoute>",
        )
        self.assertNotIn(
            "transport_paths: RwLock<HashMap<String, Vec<OwnedTransportPath>>>",
            runtime,
        )


if __name__ == "__main__":
    unittest.main()
