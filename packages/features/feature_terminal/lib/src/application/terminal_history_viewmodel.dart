// Terminal 历史页面的 Route Scope ViewModel。
//
// 它只协调注入的 TerminalHistoryRepository 和页面状态，不直接访问 SSH
// 或统一 Storage；删除操作串行化，确保用户连续点击不会产生竞态。

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/terminal_models.dart';
import '../domain/terminal_ports.dart';

/// 终端历史页面状态。
final class TerminalHistoryViewModel extends ChangeNotifier {
  /// 使用历史 Repository 创建 ViewModel。
  TerminalHistoryViewModel({required TerminalHistoryRepository repository})
    : _loadRecords = repository.loadRecords,
      _removeRecord = repository.removeRecord,
      _copyCommand = _copyToClipboard {
    reload();
  }

  TerminalHistoryViewModel._({
    required this._loadRecords,
    required this._removeRecord,
    required this._copyCommand,
  }) {
    reload();
  }

  final Future<List<TerminalHistoryRecord>> Function() _loadRecords;
  final Future<void> Function(String sessionId) _removeRecord;
  final Future<void> Function(String command) _copyCommand;
  final Set<String> _deletingSessionIds = <String>{};
  Future<void> _deleteQueue = Future<void>.value();
  bool _disposed = false;

  /// 当前一次加载 Future，页面使用 FutureBuilder 展示状态。
  late Future<List<TerminalHistoryRecord>> recordsFuture;

  /// 为测试注入纯函数 Repository，避免真实数据库和平台依赖。
  @visibleForTesting
  factory TerminalHistoryViewModel.forTesting({
    required Future<List<TerminalHistoryRecord>> Function() loadRecords,
    required Future<void> Function(String sessionId) removeRecord,
    Future<void> Function(String command)? copyCommand,
  }) => TerminalHistoryViewModel._(
    loadRecords: loadRecords,
    removeRecord: removeRecord,
    copyCommand: copyCommand ?? _copyToClipboard,
  );

  /// 某记录是否正在删除。
  bool isDeleting(String sessionId) => _deletingSessionIds.contains(sessionId);

  /// 重新加载历史记录。
  void reload() {
    if (_disposed) return;
    recordsFuture = Future<List<TerminalHistoryRecord>>.sync(_loadRecords);
    notifyListeners();
  }

  /// 串行删除一条记录。
  Future<void> deleteRecord(String sessionId) {
    if (_disposed || !_deletingSessionIds.add(sessionId)) {
      return Future<void>.value();
    }
    notifyListeners();

    final operation = _deleteQueue.then((_) async {
      await _removeRecord(sessionId);
      reload();
    });
    _deleteQueue = operation.catchError((_) {});

    return operation.whenComplete(() {
      _deletingSessionIds.remove(sessionId);
      if (!_disposed) notifyListeners();
    });
  }

  /// 复制安全清理命令。
  Future<void> copyCleanupCommand(String command) => _copyCommand(command);

  static Future<void> _copyToClipboard(String command) {
    return Clipboard.setData(ClipboardData(text: command));
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
