import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../domain/mcp_ports.dart';

enum McpApprovalState { pending, processing }

/// 供页面展示的审批快照；不包含原始 arguments 或执行回调。
class McpApprovalSnapshot {
  final String id;
  final McpApprovalRequest request;
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
  final McpApprovalRequest request;
  final DateTime createdAt;
  final Future<String> Function() executeApproved;
  final Completer<String> completer = Completer<String>();
  Timer? timeout;
  McpApprovalState state = McpApprovalState.pending;
  bool rejected = false;

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
/// by the injected tool executor's secret policy.
class McpApprovalQueue extends ChangeNotifier {
  static const int defaultMaxPending = 32;
  static const Duration defaultPendingTimeout = Duration(minutes: 10);

  final int maxPending;
  final Duration? pendingTimeout;
  final McpLoggerPort? logger;
  final List<_PendingMcpApproval> _pending = [];
  int _nextId = 0;

  McpApprovalQueue({
    this.maxPending = defaultMaxPending,
    this.pendingTimeout = defaultPendingTimeout,
    this.logger,
  }) : assert(maxPending > 0);

  List<McpApprovalSnapshot> get pending =>
      List.unmodifiable(_pending.map((item) => item.snapshot));

  Future<String> enqueue({
    required McpApprovalRequest request,
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

    // Bound how long an un-reviewed request may park the caller's tools/call
    // request. On expiry the item is rejected and the caller gets an explicit
    // approval_timeout error instead of a permanently hanging request.
    final timeout = pendingTimeout;
    if (timeout != null) {
      pending.timeout = Timer(timeout, () => _timeoutExpired(pending));
    }

    try {
      return await pending.completer.future;
    } finally {
      if (_pending.remove(pending)) {
        notifyListeners();
      }
    }
  }

  void _timeoutExpired(_PendingMcpApproval pending) {
    if (pending.state != McpApprovalState.pending || pending.rejected) {
      return;
    }
    if (_pending.remove(pending)) {
      notifyListeners();
    }
    _complete(
      pending,
      jsonEncode({
        'error': 'approval_timeout',
        'tool': pending.request.toolName,
      }),
    );
  }

  Future<void> approve(String id) async {
    final pending = _find(id);
    if (pending == null ||
        pending.state != McpApprovalState.pending ||
        pending.rejected) {
      return;
    }

    pending.state = McpApprovalState.processing;
    notifyListeners();
    try {
      final result = await pending.executeApproved();
      _complete(pending, result);
    } catch (_) {
      logger?.warning(
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
    if (pending == null ||
        pending.state != McpApprovalState.pending ||
        pending.rejected) {
      return;
    }
    pending.rejected = true;
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
    pending.timeout?.cancel();
    if (pending.completer.isCompleted) return;
    pending.completer.complete(result);
  }
}
