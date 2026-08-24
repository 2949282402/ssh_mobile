// MCP Module 初始化与释放代次测试。

import 'package:app_core/app_core.dart';
import 'package:drift/native.dart';
import 'package:feature_mcp/feature_mcp.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/mcp_test_fakes.dart';

void main() {
  test('dispose wins an activation continuation already in flight', () async {
    final module = McpModule(
      databaseFactory: () => McpDatabase.forTesting(NativeDatabase.memory()),
    );
    await module.register(
      ModuleContext.fromMap({
        McpSettingsPort: FakeMcpSettingsPort(),
        McpLoggerPort: const FakeMcpLogger(),
        McpToolRuntimePort: _FakeToolRuntime(),
      }),
    );

    final activation = module.activate();
    final disposal = module.dispose();
    await Future.wait<void>([activation.catchError((_) {}), disposal]);

    expect(module.state, ModuleState.disposed);
    await expectLater(module.initialize(), throwsStateError);
  });
}

final class _FakeToolRuntime implements McpToolRuntimePort {
  @override
  McpToolExecutor createToolExecutor() => FakeMcpToolExecutor();
}
