import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('按显式类型注册、读取和移除 Capability', () {
    final registry = CapabilityRegistry();
    final capability = _DemoCapability();

    registry.register<_DemoCapability>(capability);

    expect(registry.contains<_DemoCapability>(), isTrue);
    expect(registry.require<_DemoCapability>(), same(capability));
    expect(registry.remove<_DemoCapability>(), same(capability));
    expect(registry.maybeGet<_DemoCapability>(), isNull);
  });

  test('不同实例不能静默覆盖同一 Capability 类型', () {
    final registry = CapabilityRegistry()
      ..register<_DemoCapability>(_DemoCapability());

    expect(
      () => registry.register<_DemoCapability>(_DemoCapability()),
      throwsStateError,
    );
  });
}

final class _DemoCapability {}
