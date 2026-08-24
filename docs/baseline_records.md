> 最新更新时间：2026-08-19

# Network V1 Baseline Record

> 用途：Transport Network V2 破坏性重构（设计文档 `SSH_Mobile_传输网络架构重构设计_Main基线版.md`）的 Step 0 基线冻结记录。重构期间任何门禁回归都以此记录为对照。

## 冻结提交与标签

- 基线提交：`83fbcfb2a319da79cd1f00fcf440eb3f43ebc919`（`Merge pull request #45 from hejulian2004/feat/relay-control-plane`）
- 基线标签：`network-v1-final`
- 集成分支：`refactor/transport-network-v2`（从 `network-v1-final` 创建，承载全部 v2 工作流合并）

## 基线测试盘点（v1 状态）

### Rust（`native/network_core` workspace，10 crates）

| crate | 测试位置 | 覆盖 |
|---|---|---|
| network-core | `src/tests.rs`（2630 行，16 集成测试）+ 各模块内联（crypto 12 / crypto_handshake 12 / relay 15 / delivery 19 / peer 17 / connection 9 / session 9 / realtime 8 / commands 3 / task_supervisor 2 / channel 1） | Relay E2EE 握手、runtime delivery/TTL、TCP/WebSocket fallback、TCP→QUIC migration |
| network-nat | discovery 57 / exchange 162 / path_manager 314 / stun 90 | 候选发现、交换、路径管理、STUN |
| network-transfer | manager 414 / receiver 202 | 文件传输、接收 |
| network-quic | channel 99 / endpoint 133 / file_stream 127 / peer_session 325 | QUIC 通道/端点/文件流 |
| network-relay | client.rs 1035（16 测试，含 `binary_frame_matches_the_current_dart_and_go_contract`） | 控制帧编解码、presence/discovery 事件 |
| network-protocol | lib.rs 629 | wire round-trip |
| network-webrtc | driver 281（2，含 1 `#[ignore]` 需 coturn）/ peer 423 / qos 292 / signaling 193 | WebRTC |
| network-ffi | lib.rs 229（3 C-ABI 测试） | FFI 生命周期/实时协议 |
| network-identity | （0 测试） | — |

门禁：`cargo fmt --all -- --check`、`cargo clippy --workspace --all-targets --locked -- -D warnings`、`cargo test --workspace --locked`（CI job `native-network-quality`）。

### Go Relay（`relay`，module github.com/ssh-mobile/relay）

- 13 个测试文件：config、discovery_control（控制面/discovery/presence）、fix_package_a/b/c、hardening、multi_instance（两实例）、mysql_store（16）、redis_cache（10）、server（10，含 `TestDartWireContractEndToEnd`）、storage（12，memory==redis parity）、wave1_hardening（8）、wave2_contract（8）。
- 门禁：`gofmt`、`go test ./...`、`go test -race ./...`、`go vet ./...`、`govulncheck`（CI job `relay-quality`，配 MySQL 8.4 + Redis 7 服务；`RELAY_TEST_MYSQL_DSN`/`RELAY_TEST_REDIS_URL` 未设时相关测试 t.Skip）。

### Dart / Flutter

- 224 个测试文件：apps/ssh_mobile_full 137、apps/ssh_mobile_terminal 1、packages 80、test/tool 6。
- 网络 SDK：network_sdk_contract_test、network_runtime_test、ssh_mobile_network_native_test（ABI/lifecycle/realtime protobuf round-trip）、app network_protocol_v2_codec_test + transfer_transport_test。
- 门禁：`melos format/analyze/test`（SDK scope + workspace scope）、`flutter analyze --no-fatal-infos`、`flutter test --coverage` + `check_coverage.dart --minimum=35`（CI job `analyze-and-test`）。

### CI（`.github/workflows/flutter.yml`）

- 12 个手写 job（无 matrix）：Rust native-network-quality、Go relay-quality、sdk-dart-quality、workspace-quality、analyze-and-test、android/windows/macos/ios/terminal 平台构建等。
- 任何分支 push 触发全矩阵。

## 基线判定

PR #45（= 本基线提交）已通过全部 CI 门禁合并。重构期间以「集成分支每个合并点全绿 + 全矩阵最终绿」为验收对照；本地 WSL 仅跑可复现门禁（Rust/Go/Dart 非平台构建），平台构建以 GitHub Actions 为准。
