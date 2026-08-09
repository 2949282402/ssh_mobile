最新更新时间：2026-08-09

# App Shell Services 分类

`lib/services/` 不再是新业务 Feature 的实现目录。Step24 之后保留在这里的
代码只有 App Scope 基础设施、App 适配器，或仍被旧 App 调用面使用的兼容桥；
新的业务实现必须进入对应的 `packages/features/`、`packages/core/` 或
`packages/infrastructure/` 公共入口。

## 分类与 Owner

- App Scope 基础设施：`app_bootstrap_coordinator.dart`、`app_settings.dart` 与
  `app_strings.dart`、`background_service.dart`、
  `conditional_app_lifecycle_coordinator.dart`、`display_mode_service.dart`、
  `native_memory_service.dart`、`shortcut_command_service.dart`，以及
  `app_log_*` 和 `app_log_database/**`。这些资源由 AppRuntime 或 App Shell
  持有并负责释放；`AppLogDatabase` 是独立的 `app_logs` 诊断数据库。
- App 能力适配器：`ai_storage_adapter.dart` 与 `ai_storage/**`、
  `client_system_tool_service.dart`、`client_health_advisor.dart`、
  `server_catalog_service.dart`、`server_diagnostics_service.dart`、
  `connection_target_binding.dart`、`remote_target_scope.dart`、
  `remote_command_decoder.dart`、`terminal_session_metadata_store.dart`。
  它们只把 App-owned Repository、Secure Storage、SSH 或日志能力转换为
  Feature Port，不拥有 Feature 数据库。
- 兼容桥：`ssh_service.dart` 与 `ssh/**`、`sftp_service.dart` 与 `sftp/**`、
  `sftp_path_history_store.dart`、`performance_monitor_*.dart`、
  `server_status_probe.dart`、`system_admin_service.dart`、
  `playbook_service.dart`、`rag_service.dart`、`terminal_history_service*.dart`。
  SSH、SFTP、Monitoring、System Admin、Playbook、RAG 和 Terminal 的真实
  Owner 已分别进入 `ssh_core` 或对应 Feature；这些旧入口仍被 App Shell、
  旧页面或测试调用，因此当前只能作为非 Owner 兼容表面保留。
- 旧协议适配：`network/**`、`relay/**` 和 `lan_share/**`。LAN Feature 已有
  独立实现和 Module；这些文件仍承载现有 native v1 协议调用面。新的
  `network_transport` 只负责 App Scope Runtime/Handle Facade，不在本 Step
  复制或重写旧 TCP/UDP/QUIC/WebShare 协议。
- 内部拆分文件：被 `part of` 或条件导出引用的文件不是独立 Service，必须
  与其主库一起维护，不能按“零直接引用”误删。

## Step24 清理结果

以下三个旧 Feature 导出入口在仓库生产代码和测试中均无引用，已删除：

- `agent_model_profile.dart`
- `llm_provider/llm_api_format.dart`
- `multi_agent_coordinator.dart`

`tool_secret_policy.dart` 仍被旧 App Service 通过相对路径导入，因此保留为
`feature_ai` 的兼容导出；它不拥有安全策略实现。

后续迁移应先为兼容桥补齐对应的公共 Contract/Capability，再删除桥接文件；
不得以批量删除替代 Feature 迁移，也不得新增 `packages/core/common_services/`。
