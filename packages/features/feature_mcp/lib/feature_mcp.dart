// MCP Feature 的唯一公共入口；调用方不得导入本 Package 的 src/。
library;

export 'src/application/mcp_approval_queue.dart';
export 'src/application/lazy_mcp_tool_executor.dart';
export 'src/application/mcp_ai_tool_adapter.dart';
export 'src/application/mcp_http_server.dart';
export 'src/application/mcp_json_rpc.dart';
export 'src/application/mcp_lifecycle_handler.dart';
export 'src/application/mcp_module.dart';
export 'src/application/mcp_port_probe.dart';
export 'src/application/mcp_server_controller.dart';
export 'src/application/mcp_tool_exposure_policy.dart';
export 'src/application/mcp_tool_handler.dart';
export 'src/data/database/mcp_database.dart' hide McpActivityRecord;
export 'src/data/repositories/mcp_activity_repository.dart';
export 'src/domain/mcp_activity.dart';
export 'src/domain/mcp_auth_guard.dart';
export 'src/domain/mcp_config_templates.dart';
export 'src/domain/mcp_invocation_policy.dart';
export 'src/domain/mcp_ports.dart';
export 'src/domain/mcp_server_settings.dart';
export 'src/features/mcp_console/viewmodels/mcp_console_viewmodel.dart';
export 'src/features/mcp_console/viewmodels/mcp_settings_viewmodel.dart';
export 'src/features/mcp_console/views/mcp_activity_screen.dart';
export 'src/features/mcp_console/views/mcp_approval_queue_screen.dart';
export 'src/features/mcp_console/views/mcp_console_screen.dart';
export 'src/features/mcp_console/views/mcp_settings_screen.dart';
export 'src/presentation/mcp_feature_scope.dart';
