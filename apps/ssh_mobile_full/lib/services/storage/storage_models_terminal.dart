part of '../storage_service.dart';

class RestorableTmuxSession {
  final String sessionId;
  final String connectionId;
  final String displayName;
  final String tmuxSessionName;
  final double fontSize;
  final DateTime updatedAt;

  const RestorableTmuxSession({
    required this.sessionId,
    required this.connectionId,
    required this.displayName,
    required this.tmuxSessionName,
    required this.fontSize,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'connectionId': connectionId,
      'displayName': displayName,
      'tmuxSessionName': tmuxSessionName,
      'fontSize': fontSize,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory RestorableTmuxSession.fromJson(Map<String, dynamic> json) {
    return RestorableTmuxSession(
      sessionId: json['sessionId'] as String,
      connectionId: json['connectionId'] as String,
      displayName: json['displayName'] as String? ?? 'SSH',
      tmuxSessionName: json['tmuxSessionName'] as String? ?? 'ssh_mobile',
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 14,
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class TerminalHistoryRecord {
  final String sessionId;
  final String connectionId;
  final String connectionName;
  final String displayName;
  final String? tmuxSessionName;
  final String state;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

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

  String? get tmuxKillCommand {
    final name = tmuxSessionName;
    if (name == null || name.isEmpty) return null;
    return "tmux kill-session -t ${_shellQuote(name)}";
  }

  Map<String, dynamic> toJson() {
    return {
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
  }

  factory TerminalHistoryRecord.fromJson(Map<String, dynamic> json) {
    return TerminalHistoryRecord(
      sessionId: json['sessionId'] as String,
      connectionId: json['connectionId'] as String? ?? '',
      connectionName: json['connectionName'] as String? ?? 'SSH',
      displayName: json['displayName'] as String? ?? 'SSH',
      tmuxSessionName: json['tmuxSessionName'] as String?,
      state: json['state'] as String? ?? 'disconnected',
      errorMessage: json['errorMessage'] as String?,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }
}
