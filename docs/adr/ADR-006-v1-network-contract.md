> 最新更新时间：2026-08-07

# ADR-006：开发阶段统一 v1 网络契约

## 背景

SSH Mobile 的 Rust、FFI、Flutter、LAN pairing、WebShare 和 Relay 已进入同一
开发阶段网络调用链。此阶段不需要旧客户端迁移，也不应因为不同实现的完成
时间不同而保留第二套 API、旧协议或静默降级路径。

## 决策

- 所有当前网络 wire protocol、LAN wire protocol、Relay device protocol 和
  native ABI 均保持 v1；不引入 v2/v3/v4，也不实现版本 fallback。
- Flutter 公共网络命令统一返回 `NetworkResult<T>`。网络失败使用稳定的
  `NetworkErrorCode`，UI 不解析错误消息字符串。
- 公共事件使用类型化 `NetworkEvent`。native `CommandResultEvent` 只在
  `NativeNetworkService` 内部用于 commandId 关联，不暴露给业务层。
- command accepted 不代表连接或文件传输完成；最终状态必须由类型化 peer、route、
  transfer 或 relay 事件报告。
- Relay enrollment、凭据安全存储和配置读取由 Dart 负责；Relay 数据面由 Rust
  负责，并保持 offer/chunk 的端到端加密、接收审批、hash 校验和完成确认。
- WebShare 固定使用 HTTPS；浏览器不支持安全上下文或所需 WebCrypto 时，入口必须
  禁止发送，不得自动改用明文 HTTP。
- 不保留旧 transport、Dart Relay 数据面、`/v1/control` 或协议降级兼容包装。

## 后果

协议升级必须在未来一次明确的开发阶段变更中整体完成，并同步更新 Rust、FFI、
Dart codec、Relay 和测试 golden 数据。本决策降低当前调用链的分支数量，但旧
客户端、旧 Relay 凭据和旧 wire 数据不再受支持；开发环境需要重新 enrollment。

## 验收

固定字节 golden、round-trip、accepted 与终态事件分离、runtime 生命周期、Relay
加密完整性、LAN v1 错误响应和静态旧符号审计必须全部通过，才可修改本 ADR 的
当前实现状态。
