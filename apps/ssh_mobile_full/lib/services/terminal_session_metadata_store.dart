import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_log_service.dart';

/// SSH/Terminal 共享的窗口元数据；不包含密码、私钥或终端原始输出。
final class RestorableTmuxSession {
  /// 创建可恢复的 tmux 窗口快照。
  const RestorableTmuxSession({
    required this.sessionId,
    required this.connectionId,
    required this.displayName,
    required this.tmuxSessionName,
    required this.fontSize,
    required this.updatedAt,
  });

  final String sessionId;
  final String connectionId;
  final String displayName;
  final String tmuxSessionName;
  final double fontSize;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'connectionId': connectionId,
    'displayName': displayName,
    'tmuxSessionName': tmuxSessionName,
    'fontSize': fontSize,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory RestorableTmuxSession.fromJson(Map<String, dynamic> json) {
    return RestorableTmuxSession(
      sessionId: json['sessionId'] as String? ?? '',
      connectionId: json['connectionId'] as String? ?? '',
      displayName: json['displayName'] as String? ?? 'SSH',
      tmuxSessionName: json['tmuxSessionName'] as String? ?? 'ssh_mobile',
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 14,
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// Terminal 历史页需要的窗口状态摘要。
final class TerminalHistoryRecord {
  /// 创建终端历史记录。
  const TerminalHistoryRecord({
    required this.sessionId,
    required this.connectionId,
    required this.connectionName,
    required this.displayName,
    required this.tmuxSessionName,
    required this.state,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  final String sessionId;
  final String connectionId;
  final String connectionName;
  final String displayName;
  final String? tmuxSessionName;
  final String state;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'connectionId': connectionId,
    'connectionName': connectionName,
    'displayName': displayName,
    'tmuxSessionName': tmuxSessionName,
    'state': state,
    'errorMessage': errorMessage,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory TerminalHistoryRecord.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    return TerminalHistoryRecord(
      sessionId: json['sessionId'] as String? ?? '',
      connectionId: json['connectionId'] as String? ?? '',
      connectionName: json['connectionName'] as String? ?? 'SSH',
      displayName: json['displayName'] as String? ?? 'SSH',
      tmuxSessionName: json['tmuxSessionName'] as String?,
      state: json['state'] as String? ?? 'disconnected',
      errorMessage: json['errorMessage'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? now,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? now,
    );
  }
}

/// Terminal 元数据的 App Scope Owner。
///
/// tmux 恢复信息是跨 SSH 与 AI 的小型状态，不属于 Connection 数据库，也
/// 不应再回流到统一存储。该类只管理两个 SharedPreferences 键，并在关闭时
/// 等待挂起写入完成，避免窗口元数据丢失。
final class TerminalSessionMetadataStore {
  /// SharedPreferences 中的稳定键名。
  static const restorableSessionsKey = 'terminal_restorable_tmux_sessions';
  static const historyRecordsKey = 'terminal_history_records';

  SharedPreferences? _prefs;
  List<RestorableTmuxSession>? _restorableCache;
  List<TerminalHistoryRecord>? _historyCache;
  Future<void>? _initializeFuture;
  Future<void> _writeTail = Future<void>.value();
  bool _writePending = false;
  bool _disposed = false;

  /// 初始化偏好存储；重复调用复用同一个 Future。
  Future<void> initialize() => _initializeFuture ??= _load();

  /// 提供与旧 SSH 初始化调用面一致的只读 Future。
  Future<void> get initFuture => initialize();

  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    _restorableCache = _decodeRestorable(
      _prefs!.getString(restorableSessionsKey),
    );
    _historyCache = _decodeHistory(_prefs!.getString(historyRecordsKey));
  }

  Future<List<RestorableTmuxSession>> loadRestorableTmuxSessions() async {
    await initialize();
    return List.unmodifiable(_restorableCache ?? const []);
  }

  Future<void> saveRestorableTmuxSession(RestorableTmuxSession session) async {
    await initialize();
    final next = [..._restorableCache ?? const []]
      ..removeWhere((item) => item.sessionId == session.sessionId)
      ..add(session);
    _restorableCache = List.unmodifiable(next);
    await _persist(restorableSessionsKey, next.map((item) => item.toJson()));
  }

  Future<void> removeRestorableTmuxSession(String sessionId) async {
    await initialize();
    final next = [..._restorableCache ?? const []]
      ..removeWhere((item) => item.sessionId == sessionId);
    _restorableCache = List.unmodifiable(next);
    await _persist(restorableSessionsKey, next.map((item) => item.toJson()));
  }

  Future<void> removeRestorableTmuxSessionsForConnection(
    String connectionId,
  ) async {
    await initialize();
    final next = [..._restorableCache ?? const []]
      ..removeWhere((item) => item.connectionId == connectionId);
    _restorableCache = List.unmodifiable(next);
    await _persist(restorableSessionsKey, next.map((item) => item.toJson()));
  }

  Future<void> clearRestorableTmuxSessions() async {
    await initialize();
    _restorableCache = const [];
    await _enqueue(() => _prefs!.remove(restorableSessionsKey));
  }

  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords() async {
    await initialize();
    return List.unmodifiable(_historyCache ?? const []);
  }

  Future<void> saveTerminalHistoryRecord(TerminalHistoryRecord record) async {
    await initialize();
    final next = [..._historyCache ?? const []]
      ..removeWhere((item) => item.sessionId == record.sessionId)
      ..add(record)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _historyCache = List.unmodifiable(next);
    await _persist(historyRecordsKey, next.map((item) => item.toJson()));
  }

  Future<void> removeTerminalHistoryRecord(String sessionId) async {
    await initialize();
    final next = [..._historyCache ?? const []]
      ..removeWhere((item) => item.sessionId == sessionId);
    _historyCache = List.unmodifiable(next);
    await _persist(historyRecordsKey, next.map((item) => item.toJson()));
  }

  Future<void> replaceTerminalHistoryRecords(
    Iterable<TerminalHistoryRecord> records,
  ) async {
    await initialize();
    final next = records.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _historyCache = List.unmodifiable(next);
    await _persist(historyRecordsKey, next.map((item) => item.toJson()));
  }

  /// 等待当前写入队列结束并释放本地引用。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_writePending) await _writeTail;
    _prefs = null;
    _restorableCache = null;
    _historyCache = null;
  }

  Future<void> _persist(String key, Iterable<Map<String, dynamic>> values) {
    final encoded = jsonEncode(values.toList(growable: false));
    return _enqueue(() => _prefs!.setString(key, encoded));
  }

  Future<void> _enqueue(Future<bool> Function() write) {
    _writePending = true;
    final next = _writeTail.catchError((_) {}).then((_) async {
      if (_disposed || _prefs == null) return;
      await write();
    });
    _writeTail = next.then<void>((_) {}, onError: (_, _) {});
    final tail = _writeTail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_writeTail, tail)) _writePending = false;
      }),
    );
    return next;
  }

  List<RestorableTmuxSession> _decodeRestorable(String? value) {
    final decoded = _decodeList(value);
    return [
      for (final item in decoded)
        if (item is Map<String, dynamic>) RestorableTmuxSession.fromJson(item),
    ];
  }

  List<TerminalHistoryRecord> _decodeHistory(String? value) {
    final decoded = _decodeList(value);
    return [
      for (final item in decoded)
        if (item is Map<String, dynamic>) TerminalHistoryRecord.fromJson(item),
    ];
  }

  List<dynamic> _decodeList(String? value) {
    if (value == null || value.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(value);
      return decoded is List ? decoded : const [];
    } catch (error, stackTrace) {
      AppLogService.instance.warning(
        'Terminal metadata decode failed',
        details: '$error\n$stackTrace',
      );
      return const [];
    }
  }
}
