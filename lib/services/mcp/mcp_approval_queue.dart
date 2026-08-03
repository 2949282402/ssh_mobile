import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ai_tool_service.dart';
import '../app_log_service.dart';

enum McpApprovalState { pending, processing }

class McpApprovalSnapshot {
  final String id;
  final AiToolApprovalRequest request;
  final DateTime createdAt;
  final McpApprovalState state;

  const McpApprovalSnapshot({
    required this.id,
    required this.request,
    required this.createdAt,
    required this.state,
  });
}

class _PendingMcpApproval {
  final String id;
  final AiToolApprovalRequest request;
  final DateTime createdAt;
  final Future<String> Function() executeApproved;
  final Completer<String> completer = Completer<String>();
  McpApprovalState state = McpApprovalState.pending;

  _PendingMcpApproval({
    required this.id,
    required this.request,
    required this.createdAt,
    required this.executeApproved,
  });

  McpApprovalSnapshot get snapshot => McpApprovalSnapshot(
    id: id,
    request: request,
    createdAt: createdAt,
    state: state,
  );
}

/// In-memory approval bridge for write-capable requests coming from the local
/// MCP server. Tool arguments and execution callbacks never leave memory or
/// become part of the UI snapshot; the approval preview is already produced
/// by [AiToolService]'s secret policy.
class McpApprovalQueue extends ChangeNotifier {
  static const int defaultMaxPending = 32;

  final int maxPending;
  final List<_PendingMcpApproval> _pending = [];
  int _nextId = 0;

  McpApprovalQueue({this.maxPending = defaultMaxPending})
    : assert(maxPending > 0);

  List<McpApprovalSnapshot> get pending =>
      List.unmodifiable(_pending.map((item) => item.snapshot));

  Future<String> enqueue({
    required AiToolApprovalRequest request,
    required Future<String> Function() executeApproved,
  }) async {
    if (_pending.length >= maxPending) {
      return jsonEncode({
        'error': 'approval_queue_full',
        'tool': request.toolName,
      });
    }

    final pending = _PendingMcpApproval(
      id: 'mcp-approval-${DateTime.now().microsecondsSinceEpoch}-${_nextId++}',
      request: request,
      createdAt: DateTime.now(),
      executeApproved: executeApproved,
    );
    _pending.add(pending);
    notifyListeners();

    try {
      return await pending.completer.future;
    } finally {
      if (_pending.remove(pending)) {
        notifyListeners();
      }
    }
  }

  Future<void> approve(String id) async {
    final pending = _find(id);
    if (pending == null || pending.state != McpApprovalState.pending) return;

    pending.state = McpApprovalState.processing;
    notifyListeners();
    try {
      final result = await pending.executeApproved();
      _complete(pending, result);
    } catch (_) {
      AppLogService.instance.warning(
        'MCP approved tool execution failed',
        details: 'tool=${pending.request.toolName}',
      );
      _complete(
        pending,
        jsonEncode({
          'error': 'mcp_approval_execution_failed',
          'tool': pending.request.toolName,
        }),
      );
    }
  }

  void reject(String id) {
    final pending = _find(id);
    if (pending == null || pending.state != McpApprovalState.pending) return;
    _complete(
      pending,
      jsonEncode({
        'error': 'approval_rejected',
        'tool': pending.request.toolName,
      }),
    );
  }

  void rejectAll() {
    for (final pending in List<_PendingMcpApproval>.of(_pending)) {
      if (pending.state == McpApprovalState.pending) {
        reject(pending.id);
      }
    }
  }

  _PendingMcpApproval? _find(String id) {
    for (final pending in _pending) {
      if (pending.id == id) return pending;
    }
    return null;
  }

  void _complete(_PendingMcpApproval pending, String result) {
    if (pending.completer.isCompleted) return;
    pending.completer.complete(result);
  }
}
