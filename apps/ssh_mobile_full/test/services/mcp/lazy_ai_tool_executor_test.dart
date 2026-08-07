import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/mcp/lazy_ai_tool_executor.dart';

class MockToolExecutor implements AiToolExecutor {
  int callCount = 0;

  @override
  Future<List<AiTool>> tools() async {
    callCount++;
    return const [];
  }

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    callCount++;
    return const [];
  }

  @override
  Future<AiToolApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    callCount++;
    return null;
  }

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    callCount++;
    return 'success';
  }

  @override
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) {
    return const AiCommandReview.readOnly();
  }
}

void main() {
  group('LazyAiToolExecutor Tests', () {
    test('does not call factory until tools or execute is called', () async {
      int factoryCount = 0;
      late MockToolExecutor mockExecutor;

      final lazyExecutor = LazyAiToolExecutor(() {
        factoryCount++;
        mockExecutor = MockToolExecutor();
        return mockExecutor;
      });

      expect(lazyExecutor.isCreated, isFalse);
      expect(factoryCount, equals(0));

      final tools = await lazyExecutor.tools();

      expect(lazyExecutor.isCreated, isTrue);
      expect(factoryCount, equals(1));
      expect(tools, isEmpty);

      await lazyExecutor.tools();
      expect(factoryCount, equals(1));
    });
  });
}
