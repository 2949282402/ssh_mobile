import 'package:flutter_test/flutter_test.dart';
import 'package:feature_mcp/feature_mcp.dart';

class MockToolExecutor implements McpToolExecutor {
  int callCount = 0;

  @override
  Future<List<McpTool>> tools() async {
    callCount++;
    return const [];
  }

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    callCount++;
    return const [];
  }

  @override
  Future<McpApprovalRequest?> approvalRequestFor(
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
}

void main() {
  group('LazyMcpToolExecutor', () {
    test('does not call factory until tools or execute is called', () async {
      int factoryCount = 0;
      late MockToolExecutor mockExecutor;

      final lazyExecutor = LazyMcpToolExecutor(() {
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
