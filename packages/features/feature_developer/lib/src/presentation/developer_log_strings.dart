import 'package:app_core/app_core.dart';

/// Developer Log 页面文案；Feature 自己持有展示文本，不依赖 App Shell 的总文案表。
final class DeveloperLogStrings {
  /// 创建指定语言的开发者日志文案。
  const DeveloperLogStrings(this.language);

  /// 当前页面语言。
  final AppLanguage language;

  /// 复制筛选结果成功提示。
  String get copiedFilteredLogs =>
      language == AppLanguage.en ? 'Filtered logs copied' : '已复制当前筛选日志';

  /// 删除选中日志成功提示。
  String selectedLogsDeleted(int count) =>
      language == AppLanguage.en ? '$count deleted' : '已删除 $count 条日志';

  /// 清空日志成功提示。
  String get logsCleared =>
      language == AppLanguage.en ? 'Logs cleared' : '已清空日志';

  /// 复制单条日志成功提示。
  String get copiedSingleLog =>
      language == AppLanguage.en ? 'Log copied' : '已复制单条日志';

  /// 复制单条日志操作提示。
  String get copySingleLog =>
      language == AppLanguage.en ? 'Copy this log' : '复制单条日志';

  /// 取消操作。
  String get cancel => language == AppLanguage.en ? 'Cancel' : '取消';

  /// 复制选中日志。
  String get copySelectedLogs =>
      language == AppLanguage.en ? 'Copy Selected' : '复制选中日志';

  /// 复制筛选日志。
  String get copyFilteredLogs =>
      language == AppLanguage.en ? 'Copy filtered logs' : '复制当前筛选日志';

  /// 删除选中日志。
  String get deleteSelectedLogs =>
      language == AppLanguage.en ? 'Delete Selected' : '删除选中日志';

  /// 清空日志。
  String get clearLogs => language == AppLanguage.en ? 'Clear logs' : '清空日志';

  /// 页面标题。
  String get developerLogs =>
      language == AppLanguage.en ? 'Developer logs' : '开发日志';

  /// 日志分组标题。
  String get logs => language == AppLanguage.en ? 'Logs' : '日志';

  /// 没有日志时的提示。
  String get noLogs => language == AppLanguage.en ? 'No logs' : '暂无日志';

  /// 当前级别没有日志时的提示。
  String get noLogsForLevel =>
      language == AppLanguage.en ? 'No logs for this level' : '当前等级暂无日志';

  /// 展开长日志。
  String get expandFullLog =>
      language == AppLanguage.en ? 'Tap to expand full log' : '点击展开完整日志';

  /// 当前选中数量。
  String selectedLogs(int count) =>
      language == AppLanguage.en ? '$count selected' : '已选择 $count 条日志';
}
