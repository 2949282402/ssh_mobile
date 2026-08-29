try:
    from .frozen_contract_support import *
except ImportError:
    from frozen_contract_support import *


class FrozenContractAcceptanceMixin:
    def test_ci_runs_the_final_strict_acceptance_gate(self) -> None:
        workflow = _read(".github/workflows/flutter.yml")
        self.assertIn("bash scripts/bash/contracts/network_v2_acceptance.sh strict", workflow)
        self.assertNotIn("bash scripts/bash/contracts/network_v2_acceptance.sh baseline", workflow)

    def test_strict_selectors_cover_matrix_behavior_tests(self) -> None:
        """Keep the committed owner-test inventory executable by the strict gate."""
        script = _read("scripts/bash/contracts/network_v2_acceptance.sh")
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
        script = _read("scripts/bash/contracts/network_v2_acceptance.sh")
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
        full_test = _read("scripts/bash/ci/full_test.sh")
        coverage_test = _read("scripts/bash/coverage/coverage_test.sh")
        client_coverage = _read("scripts/bash/coverage/client_coverage.sh")
        protocol_job = re.search(
            r"job_protocol\(\) \{(.*?)\n\}", full_test, flags=re.DOTALL
        )
        self.assertIsNotNone(protocol_job)
        assert protocol_job is not None
        self.assertIn("need bash cargo go python3 protoc buf dart flutter", protocol_job.group(1))
        self.assertIn('DEFAULT_APP_COVERAGE="${FULL_TEST_COVERAGE:-0}"', full_test)
        self.assertIn("scripts/bash/coverage/client_coverage.sh", full_test)
        self.assertIn("client_coverage.sh", coverage_test)
        self.assertIn('MINIMUM="${CLIENT_COVERAGE_MINIMUM:-90}"', client_coverage)
        self.assertIn("--include=lib/services/network/", client_coverage)
        self.assertIn("record_skip app-coverage", full_test)

        self.assertIn("@vitest/coverage-v8", _read("scripts/bash/coverage/front_coverage.sh") + _read("front/package.json"))
        self.assertIn('MINIMUM="${BACKEND_COVERAGE_MINIMUM:-90}"', _read("scripts/bash/coverage/backend_coverage.sh"))
        self.assertIn('MINIMUM="${CLIENT_COVERAGE_MINIMUM:-90}"', client_coverage)
        self.assertIn('MINIMUM="${SDK_COVERAGE_MINIMUM:-90}"', _read("scripts/bash/coverage/sdk_coverage.sh"))

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
