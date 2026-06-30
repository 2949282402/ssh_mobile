part of '../ai_tool_service.dart';

class ClientToolsProvider implements AiToolProvider {
  final StorageService storageService;
  final ClientSystemToolAdapter clientSystemToolService;
  final ClientWebViewAdapter clientWebViewService;
  final String? clientWebViewSessionId;
  final ToolSecretPolicy secretPolicy;
  final SkillDomainService skillDomainService;

  const ClientToolsProvider({
    required this.storageService,
    required this.clientSystemToolService,
    required this.clientWebViewService,
    this.clientWebViewSessionId,
    required this.secretPolicy,
    required this.skillDomainService,
  });

  @override
  Future<List<AiTool>> getTools(AiToolService service) async {
    final searchSettings = await storageService.loadAiConnectionSettings();
    return _getClientTools(this, service, searchSettings);
  }

  @override
  Future<String?> execute(
    AiToolService service,
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    switch (name) {
      case 'web_search':
        return _webSearch(this, service, arguments);
      case 'client_get_time':
        return jsonEncode(clientSystemToolService.getClientTime());
      case 'client_get_device_info':
        return jsonEncode(clientSystemToolService.getClientDeviceInfo());
      case 'client_get_network_info':
        return jsonEncode(await clientSystemToolService.getNetworkInfo());
      case 'client_get_battery_status':
        return jsonEncode(await clientSystemToolService.getBatteryStatus());
      case 'client_get_permission_status':
        return jsonEncode(await clientSystemToolService.getPermissionStatus());
      case 'client_open_app_settings':
        return jsonEncode(await clientSystemToolService.openAppSettings());
      case 'client_set_clipboard':
        return _clientSetClipboard(this, service, arguments);
      case 'client_save_experience_skill':
        return _clientSaveExperienceSkill(this, service, arguments,
            approvedWrite: approvedWrite);
      case 'client_list_skills':
        return _clientListSkills(this, service, arguments);
      case 'client_update_skill':
        return _clientUpdateSkill(this, service, arguments,
            approvedWrite: approvedWrite);
      case 'client_set_alarm':
        return _clientSetAlarm(this, service, arguments);
      case 'client_list_alarms':
        return jsonEncode(await clientSystemToolService.listAlarms());
      case 'client_cancel_alarm':
        return _clientCancelAlarm(this, service, arguments);
      case 'client_query_logs':
        return _clientQueryLogs(this, service, arguments);
      case 'client_delete_log_entries':
        return _clientDeleteLogEntries(this, service, arguments,
            approvedWrite: approvedWrite);
      case 'client_clear_logs':
        return _clientClearLogs(this, service, arguments,
            approvedWrite: approvedWrite);
      case 'client_export_app_backup':
        return _clientExportAppBackup(this, service, arguments);
      case 'client_import_app_backup':
        return _clientImportAppBackup(this, service, arguments,
            approvedWrite: approvedWrite);
      case 'client_webview_get_page_text':
        return _clientWebViewGetPageText(this, service, arguments);
      case 'client_webview_get_state':
        return _clientWebViewGetState(this, service, arguments);
      case 'client_webview_navigate':
        return _clientWebViewNavigate(this, service, arguments);
      case 'app_get_operational_settings':
        return _appGetOperationalSettings(this, service, arguments);
      case 'app_update_operational_settings':
        return _appUpdateOperationalSettings(this, service, arguments,
            approvedWrite: approvedWrite);
      case 'app_clear_secret_cache':
        return _appClearSecretCache(this, service, arguments);
      case 'client_set_plan_mode':
        return _clientSetPlanMode(this, service, arguments);
      case 'client_task_create':
        return _clientTaskCreate(this, service, arguments);
      case 'client_task_update':
        return _clientTaskUpdate(this, service, arguments);
      case 'client_task_retry':
        return _clientTaskRetry(this, service, arguments);
      case 'client_task_skip':
        return _clientTaskSkip(this, service, arguments,
            approvedWrite: approvedWrite);
      default:
        return null;
    }
  }


}
