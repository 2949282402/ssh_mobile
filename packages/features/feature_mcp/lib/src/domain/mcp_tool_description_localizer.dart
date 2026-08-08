import 'mcp_ports.dart';

/// Supplies the user-facing Chinese copy for the built-in MCP tool catalog.
///
/// The English description remains owned by [McpTool]. Keeping the Chinese
/// copy here avoids changing the provider-facing tool schema or duplicating a
/// hard-coded tool list in a widget. Unknown/future tools still get a safe
/// Chinese category fallback until their dedicated copy is added.
/// MCP 控制台工具目录的本地化文案，不改变传给外部客户端的英文 schema。
class McpToolDescriptionLocalizer {
  static const Map<String, String> _chineseDescriptions = {
    'web_search': '在当前聊天绑定的客户端 WebView 中搜索公开网页并返回引用链接。',
    'client_get_time': '在 SSH Mobile 客户端读取系统时间、UTC 时间、时区和区域设置。',
    'client_get_device_info': '在客户端读取操作系统、平台、区域、时区、主机名和 CPU 信息。',
    'client_get_network_info': '在客户端读取网络连接、传输方式、Wi-Fi、代理和 VPN 状态。',
    'client_get_battery_status': '在客户端读取电量、充电、省电模式和电池优化状态。',
    'client_get_permission_status': '在客户端读取通知、后台服务和电池优化权限状态。',
    'client_check_runtime_health': '检查客户端是否适合长时间 Agent 执行、SSH 保活、SFTP 传输或监控采样。',
    'client_open_app_settings': '打开系统应用设置页面，以便用户授予通知、电池或后台权限。',
    'client_set_clipboard': '将文本复制到 SSH Mobile 客户端剪贴板。',
    'client_save_experience_skill': '将总结后的用户经验保存为本地 AI Skill，供后续对话复用。',
    'client_list_skills': '列出可供后续对话加载或复用的本地 AI 经验 Skill。',
    'client_update_skill': '按 ID 更新已保存的本地 AI 经验 Skill。',
    'client_set_alarm': '设置客户端提醒或闹钟。',
    'client_list_alarms': '列出当前应用进程创建的客户端提醒。',
    'client_cancel_alarm': '取消由客户端提醒工具创建的应用内提醒。',
    'client_query_logs': '读取当前客户端最近的脱敏应用日志，用于 SSH、SFTP、LLM 和后台诊断。',
    'client_get_log_counts': '按日志级别返回当前客户端的脱敏日志数量。',
    'client_delete_log_entries': '按 ID 删除当前客户端的指定日志记录。',
    'client_clear_logs': '清空当前客户端的全部日志记录。',
    'client_export_app_backup': '在客户端导出不含凭据的应用备份文件，并返回摘要元数据。',
    'client_import_app_backup': '通过客户端文件选择器导入应用备份；凭据字段会被忽略。',
    'client_webview_get_page_text': '读取当前聊天绑定 WebView 页面中的可见纯文本。',
    'client_webview_get_state': '读取当前聊天绑定 WebView 的页面状态。',
    'client_webview_navigate': '在当前聊天 WebView 中执行打开、返回、前进或刷新操作。',
    'app_get_operational_settings': '读取影响工具和服务器操作的应用设置，不会返回 API Key。',
    'app_update_operational_settings': '更新影响工具和服务器操作的应用设置，并改变本地应用状态。',
    'app_clear_secret_cache': '清除保存的 SSH 凭据和当前 LLM API Key 的内存秘密缓存。',
    'client_set_plan_mode': '切换当前聊天的 Plan Mode。',
    'client_task_create': '为当前请求的聊天内 TODO 执行计划创建一个步骤。',
    'client_task_update': '更新聊天内 TODO 步骤的执行状态和输出日志。',
    'client_task_retry': '将执行计划中的失败步骤重置为待执行，以便重试。',
    'client_task_skip': '跳过执行计划中的待执行或失败步骤，并要求提供理由。',
    'ssh_list_sessions': '列出当前 SSH 终端会话及其元数据，不返回原始终端输出。',
    'ssh_open_session': '使用已保存的服务器凭据打开新的 SSH 终端会话。',
    'ssh_ensure_session_connected': '确保现有 SSH 终端会话保持连接。',
    'ssh_rename_session': '修改 SSH 终端会话的显示名称。',
    'ssh_close_session': '关闭一个 SSH 终端会话。',
    'ssh_close_server_sessions': '关闭某个服务器连接的全部 SSH 终端会话。',
    'ssh_list_terminal_history': '按元数据列出保存的终端历史记录，不返回原始终端输出。',
    'ssh_delete_terminal_history_record': '按会话 ID 删除一条保存的终端历史记录。',
    'sftp_list_dir': '通过独立 SFTP 列出远程目录；包含秘密的路径会被阻止。',
    'sftp_get_entry_info': '通过独立 SFTP 读取远程路径的元数据；包含秘密的路径会被阻止。',
    'sftp_read_text': '在用户审批后读取小型远程文本文件；二进制、大文件和敏感路径会被拒绝。',
    'sftp_download_file': '通过独立 SFTP 下载远程文件并保存到运行 SSH Mobile 的客户端设备。',
    'sftp_write_text': '通过独立 SFTP 创建或替换远程文本文件。',
    'sftp_upload_local_file': '选择客户端本地文件并通过独立 SFTP 上传到远程路径。',
    'sftp_create_directory': '通过独立 SFTP 创建远程目录。',
    'sftp_rename_entry': '通过独立 SFTP 重命名或移动远程文件或目录。',
    'sftp_delete_entry': '通过独立 SFTP 删除远程文件或空目录。',
    'list_servers': '列出 SSH Mobile 中保存的服务器连接。',
    'get_server_details': '读取指定服务器连接的详细配置，不返回密码或私钥。',
    'update_server_metadata': '更新已保存服务器的非凭据元数据。',
    'delete_server': '删除已保存的服务器连接。',
    'reorder_servers': '调整已保存服务器在列表中的顺序。',
    'detect_os': '检测目标服务器的操作系统和平台信息。',
    'run_command': '在目标服务器上执行一次性 SSH 命令，并遵守命令和敏感路径限制。',
    'get_server_status': '读取目标服务器的状态和基础运行信息。',
    'generate_ops_report': '根据服务器诊断结果生成运维报告。',
    'inspect_service_health': '检查目标服务器上的服务健康状态。',
    'collect_incident_context': '收集目标服务器的事件诊断上下文。',
    'compare_server_states': '比较多个服务器的状态快照。',
    'list_playbooks': '列出已保存的 Playbook。',
    'create_playbook': '创建一个可复用的 Playbook。',
    'run_playbook': '执行一个已保存的 Playbook。',
    'get_playbook_status': '读取 Playbook 的执行状态。',
    'monitor_get_state': '读取当前服务器监控的选择和运行状态。',
    'monitor_set_selected_servers': '设置监控要跟踪的服务器集合。',
    'monitor_clear_selection': '清除监控的服务器选择。',
    'monitor_start': '启动服务器监控采样。',
    'monitor_stop': '停止服务器监控采样。',
    'monitor_stop_for_connection': '停止指定服务器连接的监控采样。',
    'monitor_set_interval': '设置监控采样间隔。',
    'monitor_set_history_window': '设置监控历史窗口大小。',
    'monitor_get_health': '读取服务器监控健康摘要。',
    'monitor_get_samples': '读取服务器监控采样数据。',
    'monitor_get_alerts': '读取服务器监控告警。',
    'monitor_get_ports': '读取服务器端口使用情况。',
    'monitor_get_applications': '读取服务器应用性能信息。',
  };

  static String descriptionFor(McpTool tool, {required bool english}) {
    if (english) return tool.description;
    return _chineseDescriptions[tool.name] ?? _fallback(tool.name);
  }

  static String _fallback(String toolName) {
    if (toolName.startsWith('client_') || toolName == 'web_search') {
      return '在 SSH Mobile 客户端执行的工具：$toolName。';
    }
    if (toolName.startsWith('sftp_')) {
      return '通过独立 SFTP 执行的远程文件工具：$toolName。';
    }
    if (toolName.startsWith('ssh_')) {
      return '执行 SSH 会话或终端操作的工具：$toolName。';
    }
    if (toolName.startsWith('monitor_')) {
      return '执行服务器监控操作的工具：$toolName。';
    }
    return 'MCP 工具：$toolName。';
  }
}
