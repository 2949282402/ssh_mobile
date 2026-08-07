最新更新时间：2026-08-08

# ssh_core

`ssh_core` 是 SSH Mobile 的 App Scope SSH 基础设施包，提供：

- `SshSessionManager`、`SshSessionLease` 和引用计数 Session Pool；
- Desktop/移动端 Runtime Adapter 契约；
- SSH Client、Host Key 校验和一次性命令执行边界；
- 非敏感远端目标绑定与安全凭据运行时模型。

## 依赖边界

本包只依赖 `app_core`、`connection_core` 和 `dartssh2`。它不依赖
`StorageService`、任何 Feature、Flutter 页面或平台 Background Service。
密码、私钥不进入目标绑定、日志和序列化数据；持久化通过
`CredentialRepository`、`HostKeyRepository` 等契约注入。

## 生命周期

`AppRuntime` 创建唯一的 `SshSessionManager`。Feature 通过
`SshSessionManager.acquire` 获取租约，并在页面离开时调用
`SshSessionLease.release`。Feature 不得关闭共享 Session；Pool 只在引用归零并
经过 idle timeout 后关闭输出流。App 退出时由 Runtime 调用 `close`。

当前应用仍保留 `SshService` 作为旧 Terminal/Background API 兼容层；该入口与
App Runtime 的 SSH Manager 使用同一 Owner，后续 Terminal Pilot 会逐步替换旧
方法面，避免一次迁移删除现有会话行为。
