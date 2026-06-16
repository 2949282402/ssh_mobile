import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../../../services/ssh_service.dart';

class TerminalViewModel extends ChangeNotifier {
  final SshService _sshService;

  bool _ctrlActive = false;
  bool _altActive = false;
  double _fontSize = 13.0;
  String? _activeSessionId;

  TerminalViewModel({
    required SshService sshService,
  }) : _sshService = sshService {
    _sshService.addListener(notifyListeners);
  }

  @override
  void dispose() {
    _sshService.removeListener(notifyListeners);
    super.dispose();
  }

  bool get ctrlActive => _ctrlActive;
  bool get altActive => _altActive;
  double get fontSize => _fontSize;
  String? get activeSessionId => _activeSessionId;

  // 代理 SSH 终端会话列表
  List<SshSession> get sessions => _sshService.sessions;
  int get sessionCount => _sshService.sessions.length;

  void toggleCtrl() {
    _ctrlActive = !_ctrlActive;
    notifyListeners();
  }

  void toggleAlt() {
    _altActive = !_altActive;
    notifyListeners();
  }

  void setCtrlActive(bool active) {
    if (_ctrlActive == active) return;
    _ctrlActive = active;
    notifyListeners();
  }

  void setAltActive(bool active) {
    if (_altActive == active) return;
    _altActive = active;
    notifyListeners();
  }

  void setFontSize(double size) {
    final clamped = size.clamp(10.0, 24.0);
    if (_fontSize == clamped) return;
    _fontSize = clamped;
    notifyListeners();
  }

  void changeFontSize(double delta) {
    setFontSize(_fontSize + delta);
  }

  void setActiveSessionId(String? id) {
    if (_activeSessionId == id) return;
    _activeSessionId = id;
    notifyListeners();
  }

  Future<void> disconnectSession(String sessionId) async {
    await _sshService.disconnectSession(sessionId);
  }

  Future<void> disconnectAll() async {
    final ids = _sshService.sessions.map((s) => s.id).toList();
    for (final id in ids) {
      await _sshService.disconnectSession(id);
    }
  }
}
