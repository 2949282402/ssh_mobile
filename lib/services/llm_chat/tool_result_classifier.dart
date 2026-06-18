part of '../llm_chat_service.dart';

enum ToolResultQuality {
  useful,
  empty,
  partial,
  error,
  permissionDenied,
  approvalRejected,
  unsafeBlocked,
  loopBlocked,
  planModeBlocked,
  cacheHit,
}

class ToolResultClassifier {
  const ToolResultClassifier();

  static ToolResultQuality classify({
    required String toolName,
    required String resultJson,
    required String outcome,
    required bool approvalRequired,
    required bool approved,
    required bool cacheHit,
    required bool dedupBlocked,
  }) {
    if (dedupBlocked || outcome == 'loop_guard_blocked') {
      return ToolResultQuality.loopBlocked;
    }
    if (outcome == 'blocked_in_plan_mode') {
      return ToolResultQuality.planModeBlocked;
    }
    if (outcome == 'approval_rejected') {
      return ToolResultQuality.approvalRejected;
    }
    if (cacheHit || outcome == 'cache_hit') {
      return ToolResultQuality.cacheHit;
    }
    if (outcome == 'execution_error' || outcome == 'tool_error') {
      return ToolResultQuality.error;
    }

    final trimmed = resultJson.trim();
    if (trimmed.isEmpty) {
      return ToolResultQuality.empty;
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is String && error.trim().isNotEmpty) {
          final errLower = error.toLowerCase();
          if (errLower.contains('permission denied') ||
              errLower.contains('unauthorized') ||
              errLower.contains('forbidden') ||
              errLower.contains('权限不足')) {
            return ToolResultQuality.permissionDenied;
          }
          return ToolResultQuality.error;
        }
      }

      if (decoded is List && decoded.isEmpty) {
        return ToolResultQuality.empty;
      }
      if (decoded is Map && decoded.isEmpty) {
        return ToolResultQuality.empty;
      }

      return ToolResultQuality.useful;
    } catch (_) {
      return ToolResultQuality.useful;
    }
  }

  static String? getSystemHint(
      String toolName, ToolResultQuality quality, AppLanguage language) {
    final isEn = language == AppLanguage.en;
    switch (quality) {
      case ToolResultQuality.empty:
        return isEn
            ? 'System Hint: The tool "$toolName" returned an empty result or output. '
                'If this was a diagnostic command, verify parameters or check the target status. '
                'Please try a different query parameter or verify state before continuing.'
            : '系统提示：工具 "$toolName" 返回了空结果。请核对查询参数或检查目标状态。 '
                '请在继续之前尝试不同的查询条件，避免重复无意义的调用。';
      case ToolResultQuality.error:
        return isEn
            ? 'System Hint: The tool "$toolName" execution failed with an error. '
                'Check parameters, inspect diagnostic logs, and resolve the root cause. '
                'Do not repeat the exact same failing command without modifications.'
            : '系统提示：工具 "$toolName" 执行发生错误。请检查参数、核对诊断日志并排查根本原因。 '
                '在调整方案之前，请勿重复执行完全相同的失败命令。';
      case ToolResultQuality.permissionDenied:
        return isEn
            ? 'System Hint: Permission denied for tool "$toolName". '
                'Inform the user about the restriction and request selecting a different server or checking privileges.'
            : '系统提示：工具 "$toolName" 权限不足。请告知用户此权限限制，并引导用户检查权限或选择其他可用的服务器。';
      case ToolResultQuality.approvalRejected:
        return isEn
            ? 'System Hint: The user rejected this action. Stop requesting the same operation.'
            : '系统提示：用户拒绝了该敏感操作审批。请停止重复请求执行相同的操作。';
      case ToolResultQuality.loopBlocked:
        return isEn
            ? 'System Hint: Loop guard has blocked this repeating tool call. Please summarize the current findings and complete the conversation.'
            : '系统提示：循环保护机制已阻断了此重复工具调用。请整理并总结当前已获取的诊断发现，完成本次对话。';
      default:
        return null;
    }
  }
}
