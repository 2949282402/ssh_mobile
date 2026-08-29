"""Regression tests for recursive Rust-source discovery in frozen checks."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

try:
    from .frozen_contract_support import (
        ROOT,
        _read_with_tests,
        _dart_tree,
        _rust_module_declarations,
        _rust_tree,
        _source_paths,
    )
except ImportError:
    from frozen_contract_support import (
        ROOT,
        _read_with_tests,
        _dart_tree,
        _rust_module_declarations,
        _rust_tree,
        _source_paths,
    )


class RustSourceDiscoveryTest(unittest.TestCase):
    def test_module_declarations_capture_path_attrs_and_test_only_modules(self) -> None:
        source = (
            "mod commands;\n"
            "#[cfg(test)]\n"
            '#[path = "tests/commands.rs"]\n'
            "mod tests;\n"
        )
        self.assertEqual(
            _rust_module_declarations(source),
            [
                ("commands", None, False),
                ("tests", "tests/commands.rs", True),
            ],
        )

    def test_rust_tree_follows_mods_includes_and_path_attributes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            lib = root / "lib.rs"
            commands = root / "commands.rs"
            wire = root / "commands" / "wire.rs"
            test_mod = root / "tests" / "commands.rs"
            split = root / "tests" / "commands" / "split.rs"
            wire.parent.mkdir()
            split.parent.mkdir(parents=True)

            lib.write_text(
                "mod commands;\n"
                "#[cfg(test)]\n"
                '#[path = "tests/commands.rs"]\n'
                "mod tests;\n",
                encoding="utf-8",
            )
            commands.write_text("mod wire;\n", encoding="utf-8")
            wire.write_text("pub peer_id: String,\n", encoding="utf-8")
            test_mod.write_text('include!("commands/split.rs");\n', encoding="utf-8")
            split.write_text(
                "#[test]\n"
                "fn direct_candidates_are_ranked_before_the_staggered_race() {}\n",
                encoding="utf-8",
            )

            production_resolved = {
                path.resolve() for path in _rust_tree(lib)
            }
            self.assertIn(commands.resolve(), production_resolved)
            self.assertIn(wire.resolve(), production_resolved)
            self.assertNotIn(test_mod.resolve(), production_resolved)

            test_tree = _rust_tree(test_mod)
            test_resolved = {path.resolve() for path in test_tree}
            self.assertIn(split.resolve(), test_resolved)
            combined = "\n".join(
                path.read_text(encoding="utf-8") for path in test_tree
            )
            self.assertIn(
                "direct_candidates_are_ranked_before_the_staggered_race",
                combined,
            )

    def test_dart_tree_follows_part_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            codec = root / "codec.dart"
            wire = root / "wire.dart"
            codec.write_text("part 'wire.dart';\n", encoding="utf-8")
            wire.write_text(
                "peerId = utf8.decode(reader.bytes(field.wireType));\n",
                encoding="utf-8",
            )
            paths = _dart_tree(codec)
            self.assertIn(wire.resolve(), {path.resolve() for path in paths})
            combined = "\n".join(
                path.read_text(encoding="utf-8") for path in paths
            )
            self.assertIn(
                "peerId = utf8.decode(reader.bytes(field.wireType));",
                combined,
            )

    def test_source_paths_expand_current_split_layout(self) -> None:
        attempt_paths = {
            path.resolve()
            for path in _source_paths(
                ROOT
                / "native/network_core/crates/network-core/src/connect/connectivity_attempt.rs"
            )
        }
        self.assertIn(
            (
                ROOT
                / "native/network_core/crates/network-core/src/connect/connectivity_attempt/candidate_snapshot_policy.rs"
            ).resolve(),
            attempt_paths,
        )
        self.assertIn(
            (
                ROOT
                / "native/network_core/crates/network-core/src/tests/connectivity_attempt/candidate_and_relay_gates.rs"
            ).resolve(),
            attempt_paths,
        )

        supervisor_paths = {
            path.resolve()
            for path in _source_paths(
                ROOT
                / "native/network_core/crates/network-core/src/connect/peer_supervisor.rs"
            )
        }
        self.assertIn(
            (
                ROOT
                / "native/network_core/crates/network-core/src/tests/connect/peer_supervisor/lifecycle_and_retry.rs"
            ).resolve(),
            supervisor_paths,
        )

    def test_read_with_tests_reaches_split_markers(self) -> None:
        supervisor = _read_with_tests(
            "native/network_core/crates/network-core/src/connect/peer_supervisor.rs"
        )
        self.assertIn("mailbox_and_resource_limits_are_bounded", supervisor)
        attempt = _read_with_tests(
            "native/network_core/crates/network-core/src/connect/connectivity_attempt.rs"
        )
        self.assertIn("update_remote_candidate_cache", attempt)
        self.assertIn(
            "direct_candidates_are_ranked_before_the_staggered_race",
            attempt,
        )
        codec = _read_with_tests(
            "apps/ssh_mobile_full/lib/services/network/network_protocol_v2_codec.dart"
        )
        self.assertIn(
            "peerId = utf8.decode(reader.bytes(field.wireType));",
            codec,
        )


if __name__ == "__main__":
    unittest.main()
