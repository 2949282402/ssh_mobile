最新更新时间：2026-08-11

# ssh_mobile_network_native 维护约束

## 允许修改范围

允许修改 Dart FFI facade、native asset hook、平台构建配置、Rust 协议绑定和对应
测试；协议字节、状态枚举和构建目标变化必须同步 Network Transport 合约。Realtime
command/event 的类型化 API 必须继续隐藏 Rust handle、Socket 和 WebRTC 内部对象。

## 禁止依赖

不得依赖 Feature、App Shell、Flutter UI 或 Dart 全局 Service；Dart 只通过受控
FFI handle 调用 Rust，不得在这里复制业务层 LAN/SSH/SFTP 实现。

## Public API 修改要求

公共入口为 `package:ssh_mobile_network_native/ssh_mobile_network_native.dart`。
修改 FFI 状态、命令、事件或 hook 行为时，必须同步 `network_transport`、平台
构建文档和 Dart/Rust 测试。

## 数据库约束

本 Package 不拥有数据库；配对凭据、Token 和业务历史由上层安全存储或 Feature
Module 管理，native runtime 不得持久化秘密。

## 资源释放规则

`NativeNetworkRuntime` 的 Owner 必须负责 isolate 停止、Rust handle destroy 和
重复释放保护；生命周期顺序保持 `Running -> Stopping -> Stopped -> Destroyed`，
停止后拒绝新命令。

## 必须运行的测试

```bash
dart analyze
dart test
cargo fmt --all -- --check
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
```
