import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Registry 只持有 descriptor，并按需创建 Module', () {
    final context = ModuleContext.fromMap(<Type, Object>{String: 'context'});
    final descriptor = ModuleDescriptor(
      id: 'demo',
      metadata: <String, Object?>{'owner': 'test'},
      routeContributions: <ModuleRouteContribution>[
        ModuleRouteContribution(
          routeName: '/demo',
          metadata: <String, Object?>{'scope': 'route'},
        ),
      ],
      factory: (moduleContext) => _FakeModule(moduleContext),
    );
    final registry = ModuleRegistry()..register(descriptor);

    expect(registry.contains('demo'), isTrue);
    expect(registry.descriptors, hasLength(1));
    expect(
      registry.descriptorFor('demo').routeContributions.single.routeName,
      '/demo',
    );
    expect(
      () => descriptor.metadata['owner'] = 'other',
      throwsUnsupportedError,
    );

    final first = registry.create('demo', context);
    final second = registry.create('demo', context);
    expect(first, isA<_FakeModule>());
    expect(identical(first, second), isFalse);
    expect((first as _FakeModule).context.require<String>(), 'context');
  });

  test('相同 id 的不同 descriptor 会被拒绝', () {
    final registry = ModuleRegistry();
    registry.register(
      ModuleDescriptor(
        id: 'duplicate',
        factory: (_) => _FakeModule(const ModuleContext.empty()),
      ),
    );

    expect(
      () => registry.register(
        ModuleDescriptor(
          id: 'duplicate',
          factory: (_) => _FakeModule(const ModuleContext.empty()),
        ),
      ),
      throwsStateError,
    );
  });
}

final class _FakeModule implements AppModule {
  _FakeModule(this.context);

  final ModuleContext context;

  @override
  String get id => 'demo';

  @override
  ModuleState state = ModuleState.registered;

  @override
  Future<void> register(ModuleContext context) async {}

  @override
  Future<void> initialize() async {
    state = ModuleState.initialized;
  }

  @override
  Future<void> activate() async {
    state = ModuleState.active;
  }

  @override
  Future<void> deactivate() async {
    state = ModuleState.inactive;
  }

  @override
  Future<void> dispose() async {
    state = ModuleState.disposed;
  }
}
