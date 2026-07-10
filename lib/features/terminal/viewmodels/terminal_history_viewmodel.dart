import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../../services/ssh_service.dart';
import '../../../services/storage_service.dart';

class TerminalHistoryViewModel extends ChangeNotifier {
  final SshService _sshService;

  late Future<List<TerminalHistoryRecord>> recordsFuture;

  TerminalHistoryViewModel({required this._sshService}) {
    reload();
  }

  void reload() {
    recordsFuture = _sshService.loadTerminalHistoryRecords();
    notifyListeners();
  }

  Future<void> deleteRecord(String sessionId) async {
    await _sshService.removeTerminalHistoryRecord(sessionId);
    reload();
  }

  Future<void> copyCleanupCommand(String command) async {
    await Clipboard.setData(ClipboardData(text: command));
  }
}
