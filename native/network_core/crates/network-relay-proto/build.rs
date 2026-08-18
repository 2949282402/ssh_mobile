//! prost-build codegen for the frozen relay.v2 wire contract.
//!
//! The .proto lives outside the workspace crate tree, at
//! `protocol/proto/relay/v2/relay_v2.proto` relative to the repository root.
//! Build scripts run with the package root as the working directory
//! (`native/network_core/crates/network-relay-proto`), so the relative path
//! up to the repository root is `../../../../`. This cross-crate path is
//! fragile and is guarded by an existence assertion here and by a unit test in
//! `src/lib.rs`.
//!
//! protoc is provided by `protoc-bin-vendored` so no system protoc is needed
//! and the build is reproducible in CI.

use std::path::Path;

fn main() {
    // Path to the frozen contract relative to this crate's root.
    const PROTO_DIR: &str = "../../../../protocol/proto/relay/v2";
    const PROTO_FILE: &str = "../../../../protocol/proto/relay/v2/relay_v2.proto";

    println!("cargo:rerun-if-changed={PROTO_FILE}");
    assert!(
        Path::new(PROTO_FILE).exists(),
        "relay v2 proto missing at {PROTO_FILE}; the frozen contract \
         must be checked in at protocol/proto/relay/v2/relay_v2.proto"
    );

    let protoc = protoc_bin_vendored::protoc_bin_path()
        .expect("vendored protoc must be extracted for this platform");

    let mut config = prost_build::Config::new();
    config.protoc_executable(protoc);
    config
        .compile_protos(&[PROTO_FILE], &[PROTO_DIR])
        .expect("prost-build failed to compile relay.v2 relay_v2.proto");
}
