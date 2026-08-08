import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:feature_mcp/feature_mcp.dart';

McpApprovalRequest _request(String toolName) {
  return McpApprovalRequest(
    toolName: toolName,
    approvalType: 'remote_write',
    connectionId: 'server-1',
    connectionName: 'Server 1',
    command: 'echo test',
    reason: 'test approval',
  );
}

void main() {
  test('enqueue parks the request until approve runs the closure', () async {
    final queue = McpApprovalQueue();
    var executed = false;
    final future = queue.enqueue(
      request: _request('run_command'),
      executeApproved: () async {
        executed = true;
        return 'ok';
      },
    );

    expect(queue.pending, hasLength(1));
    expect(queue.pending.single.request.toolName, 'run_command');
    expect(executed, isFalse);

    await queue.approve(queue.pending.single.id);
    expect(await future, 'ok');
    expect(executed, isTrue);
    expect(queue.pending, isEmpty);
    queue.dispose();
  });

  test(
    'reject completes the request with approval_rejected without executing',
    () async {
      final queue = McpApprovalQueue();
      var executed = false;
      final future = queue.enqueue(
        request: _request('run_command'),
        executeApproved: () async {
          executed = true;
          return 'ok';
        },
      );

      queue.reject(queue.pending.single.id);
      final result = jsonDecode(await future) as Map;
      expect(result['error'], 'approval_rejected');
      expect(executed, isFalse);
      expect(queue.pending, isEmpty);
      queue.dispose();
    },
  );

  test(
    'queue full returns approval_queue_full and keeps pending at the cap',
    () async {
      final queue = McpApprovalQueue(maxPending: 2);
      final futures = <Future<String>>[
        queue.enqueue(request: _request('a'), executeApproved: () async => 'a'),
        queue.enqueue(request: _request('b'), executeApproved: () async => 'b'),
      ];
      expect(queue.pending, hasLength(2));

      final overflow = await queue.enqueue(
        request: _request('c'),
        executeApproved: () async => 'c',
      );
      final result = jsonDecode(overflow) as Map;
      expect(result['error'], 'approval_queue_full');
      expect(queue.pending, hasLength(2));

      queue.rejectAll();
      // reject() completes the parked futures synchronously, but the awaiting
      // enqueue() removes the items in a microtask, so await them first.
      final results = await Future.wait(futures);
      expect(queue.pending, isEmpty);
      for (final value in results) {
        expect(jsonDecode(value)['error'], 'approval_rejected');
      }
      queue.dispose();
    },
  );

  test(
    'rejectAll clears pending items but leaves processing items running',
    () async {
      final queue = McpApprovalQueue(maxPending: 4);
      final gate = Completer<String>();
      final first = queue.enqueue(
        request: _request('a'),
        executeApproved: () async => gate.future,
      );
      await pumpEventQueue();
      // approve() marks the item processing and awaits executeApproved (stuck on
      // the gate), so the item stays in the queue with state processing.
      final approveFuture = queue.approve(queue.pending.single.id);
      await pumpEventQueue();
      expect(queue.pending.single.state, McpApprovalState.processing);

      final second = queue.enqueue(
        request: _request('b'),
        executeApproved: () async => 'b',
      );
      queue.rejectAll();
      expect(jsonDecode(await second)['error'], 'approval_rejected');
      expect(queue.pending.single.state, McpApprovalState.processing);

      gate.complete('ok');
      expect(await first, 'ok');
      await approveFuture;
      expect(queue.pending, isEmpty);
      queue.dispose();
    },
  );

  test('approve is idempotent after a request is already resolved', () async {
    final queue = McpApprovalQueue();
    final future = queue.enqueue(
      request: _request('run_command'),
      executeApproved: () async => 'ok',
    );
    final id = queue.pending.single.id;
    await queue.approve(id);
    // A second approve on the same id is a no-op and must not double-execute.
    await queue.approve(id);
    expect(await future, 'ok');
    expect(queue.pending, isEmpty);
    queue.dispose();
  });

  test('pendingTimeout rejects an un-reviewed request', () async {
    final queue = McpApprovalQueue(
      pendingTimeout: const Duration(milliseconds: 20),
    );
    var executed = false;
    final future = queue.enqueue(
      request: _request('run_command'),
      executeApproved: () async {
        executed = true;
        return 'ok';
      },
    );

    final result = jsonDecode(await future) as Map;
    expect(result['error'], 'approval_timeout');
    expect(executed, isFalse);
    expect(queue.pending, isEmpty);
    queue.dispose();
  });
}
