import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../../services/ssh_service.dart';
import '../../../services/app_settings.dart';

class TerminalWindowsViewModel extends ChangeNotifier {
  final SshService _sshService;
  final AppSettings _appSettings;

  final Set<String> _selectedSessionIds = {};
  bool _selectionMode = false;
  String? connectionId;

  TerminalWindowsViewModel({
    required this._sshService,
    required this._appSettings,
  }) {
    _sshService.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _sshService.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    notifyListeners();
  }

  // Getters
  List<SshSession> get sessions {
    return _sshService.sessions
        .where(
          (session) =>
              connectionId == null || session.connectionId == connectionId,
        )
        .toList();
  }

  Set<String> get selectedSessionIds => _selectedSessionIds;
  bool get selectionMode => _selectionMode;
  AppLanguage get language => _appSettings.language;

  void toggleSelection(String sessionId) {
    if (_selectedSessionIds.contains(sessionId)) {
      _selectedSessionIds.remove(sessionId);
    } else {
      _selectedSessionIds.add(sessionId);
    }
    _selectionMode = _selectedSessionIds.isNotEmpty;
    notifyListeners();
  }

  void selectAll() {
    _selectionMode = true;
    _selectedSessionIds
      ..clear()
      ..addAll(sessions.map((s) => s.id));
    notifyListeners();
  }

  void clearSelection() {
    _selectionMode = false;
    _selectedSessionIds.clear();
    notifyListeners();
  }

  Future<void> closeSession(String sessionId) async {
    await _sshService.disconnectSession(sessionId);
    _selectedSessionIds.remove(sessionId);
    if (_selectedSessionIds.isEmpty) {
      _selectionMode = false;
    }
    notifyListeners();
  }

  Future<void> closeSelectedSessions() async {
    final ids = _selectedSessionIds.toList();
    clearSelection();
    for (final id in ids) {
      await _sshService.disconnectSession(id);
    }
  }

  Future<void> copyCleanupCommand(String command) async {
    await Clipboard.setData(ClipboardData(text: command));
  }
}
