最新更新时间：2026-08-28

# App Shell Services 分类

`lib/services/` 不再是新业务 Feature 的实现目录。Step24 之后保留在这里的
代码只有 App Scope 基础设施、App 适配器，或仍被旧 App 调用面使用的兼容桥；
新的业务实现必须进入对应的 `packages/features/`、`packages/core/` 或
`packages/infrastructure/` 公共入口。

兼容入口的逐模块引用基线、门禁状态、保留的 App Shell 适配器和删除条件
统一记录在 [`docs/architecture/COMPATIBILITY_MIGRATION_INVENTORY.md`](../../../../docs/architecture/COMPATIBILITY_MIGRATION_INVENTORY.md)。
Connection、Terminal、SFTP、Monitoring、System Admin、LAN Share、Playbook、
RAG 和 Network 的旧 Feature/业务入口已经完成零引用收口；剩余文件均是明确
登记的 App Scope 后端或适配边界，不能再作为新业务实现目的地。

## 分类与 Owner

- App Scope 基础设施：`app_bootstrap_coordinator.dart`、`app_settings.dart` 与
  `app_strings.dart`、`background_service.dart`、
  `conditional_app_lifecycle_coordinator.dart`、`display_mode_service.dart`、
  `native_memory_service.dart`、`shortcut_command_service.dart`，以及
  `app_log_*`、`app_log_database/**` 和 `telemetry/**`。这些资源由 AppRuntime 或 App Shell
  持有并负责释放；`AppLogDatabase` 是独立的 `app_logs` 诊断数据库。
  `AppCrashTelemetryBridge` 只拥有进程级错误 handler 包装，`TelemetryLogSink`
  独立借用 TelemetryClient；两者在本地 SQLite durable write 完成后再异步 flush，
  不改变 AppLogDatabase 的 Owner。
  `AppLogService.databaseOpen` 和 `activeTimerCount` 只供生命周期诊断读取，
  不改变数据库绑定或关闭 Owner。
- App 能力适配器：`ai_storage_adapter.dart` 与 `ai_storage/**`、
  `client_system_tool_service.dart`、`client_health_advisor.dart`、
  `server_catalog_service.dart`、`server_diagnostics_service.dart`、
  `connection_target_binding.dart`、`remote_target_scope.dart`、
  `remote_command_decoder.dart`、`terminal_session_metadata_store.dart`、
  `sftp_backend_adapters.dart`、`sftp_io_backend_adapters.dart`、
  `network_sdk_adapters.dart`。
  它们只把 App-owned Repository、Secure Storage、SSH 或日志能力转换为
  Feature Port，不拥有 Feature 数据库。
- 仍保留的协议/基础设施后端：`ssh_service.dart` 与 `ssh/**`、
  `sftp_service.dart` 与 `sftp/**`、`sftp_path_history_store.dart`、
  `server_diagnostics_service.dart`、`server_status_probe.dart`、
  `terminal_history_service*.dart`，以及 `network/**` 中登记的 Network Protocol V2
  codec/service/identity。它们不是 Feature UI 或业务 Owner，只能由 App Shell
  适配器和组合测试使用；Playbook、RAG、Monitoring、System Admin、LAN Share
  和 Network Relay 的旧业务 facade 已删除。`SshService`
  的会话、Lease、Pool idle Timer 和后台订阅计数也只是诊断读取面，不改变
  其仍由 AppRuntime/SSH Manager 统一关闭的 Owner 关系。
- 旧协议适配：`network/**`。LAN Feature 已有独立实现和 Module；`network/**`
  仅承载 App Scope Network Protocol V2 协议调用面。`network_service.dart` 只保留
  `NetworkService` 兼容入口和组合根；命令协调、事件路由、Runtime 生命周期、
  Peer、Relay、Route projection、Transfer 分别由相邻的
  `network_service_*` 内部 part 所有。新的 `network_transport` 负责
  Runtime/Handle Facade，不复制或重写 TCP/UDP/QUIC/WebShare 协议。
- SSH 前后台在 session registry 之外统一使用 attempt owner 和 per-session
  generation：失败或被新建连取代的 socket/client/shell/runtime 会逆序释放；
  App Scope 关闭会等待建连、重连、后台事件订阅、Session Pool 与 native stream
  connector 收敛，迟到回调不得重新登记资源。
- `BackgroundServiceLifecycle` 串行化前台服务 start/stop 与 power lock 所有权；
  native `startService` 返回 `false` 或抛错时立即释放已获取 lock，stop 即使 ACK、
  subscription 或其他清理失败也继续尝试释放。
- 内部拆分文件：被 `part of` 或条件导出引用的文件不是独立 Service，必须
  与其主库一起维护，不能按“零直接引用”误删。

## Step24 清理结果

以下三个旧 Feature 导出入口在仓库生产代码和测试中均无引用，已删除：

- `agent_model_profile.dart`
- `llm_provider/llm_api_format.dart`
- `multi_agent_coordinator.dart`

`tool_secret_policy.dart` 仍被旧 App Service 通过相对路径导入，因此保留为
`feature_ai` 的兼容导出；它不拥有安全策略实现。

后续改动必须先通过对应的公共 Contract/Capability 和兼容清单守卫；不得把
已删除的旧 Feature 入口恢复为 facade，也不得新增 `packages/core/common_services/`。
