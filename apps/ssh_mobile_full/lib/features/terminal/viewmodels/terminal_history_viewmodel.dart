import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../../services/ssh_service.dart';
import '../../../services/storage_service.dart';

class TerminalHistoryViewModel extends ChangeNotifier {
  final Future<List<TerminalHistoryRecord>> Function() _loadRecords;
  final Future<void> Function(String sessionId) _removeRecord;
  final Future<void> Function(String command) _copyCommand;
  final Set<String> _deletingSessionIds = <String>{};

  Future<void> _deleteQueue = Future<void>.value();
  bool _disposed = false;

  late Future<List<TerminalHistoryRecord>> recordsFuture;

  TerminalHistoryViewModel({required SshService sshService})
    : this._(
        loadRecords: sshService.loadTerminalHistoryRecords,
        removeRecord: sshService.removeTerminalHistoryRecord,
        copyCommand: _copyToClipboard,
      );

  TerminalHistoryViewModel._({
    required this._loadRecords,
    required this._removeRecord,
    required this._copyCommand,
  }) {
    reload();
  }

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

  bool isDeleting(String sessionId) => _deletingSessionIds.contains(sessionId);

  void reload() {
    if (_disposed) return;
    recordsFuture = Future<List<TerminalHistoryRecord>>.sync(_loadRecords);
    notifyListeners();
  }

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

  Future<void> copyCleanupCommand(String command) async {
    await _copyCommand(command);
  }

  static Future<void> _copyToClipboard(String command) async {
    await Clipboard.setData(ClipboardData(text: command));
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
