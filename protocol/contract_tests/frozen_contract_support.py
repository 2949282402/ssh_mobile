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


_RUST_MOD = re.compile(
    r"^\s*(?P<attrs>(?:#\[[^\]]*\]\s*)*)"
    r"(?:pub(?:\([^)]*\))?\s+)?mod\s+(?P<name>[A-Za-z0-9_]+)\s*;",
    re.MULTILINE,
)
_RUST_PATH_ATTR = re.compile(r"#\[\s*path\s*=\s*[\"']([^\"']+)[\"']\s*\]")
_RUST_INCLUDE = re.compile(
    r"^\s*include!\s*\(\s*[\"']([^\"']+)[\"']\s*\)\s*;",
    re.MULTILINE,
)
_DART_PART = re.compile(
    r"""^\s*part\s+['"]([^'"]+)['"]\s*;""",
    re.MULTILINE,
)


def _rust_module_declarations(source: str) -> list[tuple[str, str | None, bool]]:
    """Return ``(name, path_attribute, is_test_only)`` for each file module."""
    declarations: list[tuple[str, str | None, bool]] = []
    pending_attrs: list[str] = []
    for line in source.splitlines():
        stripped = line.strip()
        if stripped.startswith("#[") and stripped.endswith("]"):
            pending_attrs.append(stripped)
            continue
        match = _RUST_MOD.search(line)
        if match is None:
            if stripped:
                pending_attrs = []
            continue
        attrs = list(pending_attrs)
        attrs.extend(re.findall(r"#\[[^\]]*\]", match.group("attrs") or ""))
        pending_attrs = []
        path_attr: str | None = None
        for attr in attrs:
            path_match = _RUST_PATH_ATTR.search(attr)
            if path_match is not None:
                path_attr = path_match.group(1)
        declarations.append(
            (
                match.group("name"),
                path_attr,
                any("cfg(test)" in attr for attr in attrs),
            )
        )
    return declarations


def _resolve_rust_module(
    source_file: Path,
    name: str,
    path_attr: str | None,
) -> Path | None:
    """Resolve a Rust module file from its declaration and ``#[path]``."""
    if path_attr is not None:
        candidate = source_file.parent / path_attr
        return candidate.resolve() if candidate.is_file() else None
    if source_file.name in {"lib.rs", "main.rs", "mod.rs"}:
        module_root = source_file.parent
    else:
        module_root = source_file.with_suffix("")
    flat = module_root / f"{name}.rs"
    if flat.is_file():
        return flat.resolve()
    nested = module_root / name / "mod.rs"
    if nested.is_file():
        return nested.resolve()
    return None


def _rust_tree(entry: Path) -> list[Path]:
    """Return every Rust file reachable through ``mod`` and ``include!``."""
    results: list[Path] = []
    seen: set[Path] = set()
    pending = [entry.resolve()]
    while pending:
        path = pending.pop(0)
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        results.append(path)
        source = path.read_text(encoding="utf-8")
        for name, path_attr, is_test_only in _rust_module_declarations(source):
            if is_test_only:
                continue
            child = _resolve_rust_module(path, name, path_attr)
            if child is not None:
                pending.append(child)
        for include_path in _RUST_INCLUDE.findall(source):
            child = (path.parent / include_path).resolve()
            if child.is_file():
                pending.append(child)
    return results


def _dart_tree(entry: Path) -> list[Path]:
    """Return the entrypoint and every Dart ``part`` file it reaches."""
    results: list[Path] = []
    seen: set[Path] = set()
    pending = [entry.resolve()]
    while pending:
        path = pending.pop(0)
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        results.append(path)
        source = path.read_text(encoding="utf-8")
        for part_path in _DART_PART.findall(source):
            child = (path.parent / part_path).resolve()
            if child.is_file():
                pending.append(child)
    return results


def _source_paths(path: Path) -> list[Path]:
    """Return a source tree plus any extracted Rust test sidecar tree."""
    paths: list[Path] = []
    src_root = (
        next((parent for parent in path.parents if parent.name == "src"), None)
        if path.suffix == ".rs"
        else None
    )
    if path.is_file():
        if path.suffix == ".rs":
            paths.extend(_rust_tree(path))
        elif path.suffix == ".dart":
            paths.extend(_dart_tree(path))
        else:
            paths.append(path)
    if src_root is None:
        return list(dict.fromkeys(paths))

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
            paths.extend(_rust_tree(sidecar) if sidecar.suffix == ".rs" else [sidecar])
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


__all__ = [
    "MANIFEST_PATH",
    "MATRIX_PATH",
    "ROOT",
    "REQUIRED_CASE_IDS",
    "Path",
    "_load_json",
    "_load_matrix",
    "_production_sources",
    "_read",
    "_read_with_tests",
    "_source_paths",
    "_without_comments",
    "json",
    "os",
    "re",
    "struct",
]
