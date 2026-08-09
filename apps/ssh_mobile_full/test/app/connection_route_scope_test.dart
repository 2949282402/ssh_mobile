/// 验证 App Shell 的 Connection 路由 Scope 只管理路由级 ViewModel。
library;

import 'package:connection_core/connection_core.dart';
import 'package:feature_connection/feature_connection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:ssh_mobile/app/connection_route_scope.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  testWidgets('creates and injects a Connection ViewModel at route scope', (
    tester,
  ) async {
    final settings = AppSettings();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppSettings>.value(
        value: settings,
        child: MaterialApp(
          home: AppConnectionRouteScope(
            connectionRepository: _FakeConnectionRepository(),
            credentialRepository: _FakeCredentialRepository(),
            hostKeyRepository: _FakeConnectionRepository(),
            runtimePort: _FakeRuntimePort(),
            verificationPort: _FakeVerificationPort(),
            child: Builder(
              builder: (context) {
                final viewModel = context.read<ConnectionViewModel>();
                final strings = context.read<ConnectionStrings>();
                final uiAdapter = context.read<ConnectionUiAdapter>();
                return Column(
                  children: [
                    Text(
                      viewModel.isLoading ? 'loading' : 'ready',
                      key: const ValueKey('connection-route-view-model'),
                    ),
                    Text(
                      strings.language.name,
                      key: const ValueKey('connection-route-strings'),
                    ),
                    Text(
                      uiAdapter.runtimeType.toString(),
                      key: const ValueKey('connection-route-ui-adapter'),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('connection-route-view-model')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('connection-route-strings')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('connection-route-ui-adapter')),
      findsOneWidget,
    );
  });

  testWidgets('reuses a supplied ViewModel without taking ownership', (
    tester,
  ) async {
    final settings = AppSettings();
    addTearDown(settings.dispose);
    final repository = _FakeConnectionRepository();
    final viewModel = ConnectionViewModel(
      connectionRepository: repository,
      credentialRepository: _FakeCredentialRepository(),
      hostKeyRepository: repository,
      runtimePort: _FakeRuntimePort(),
      verificationPort: _FakeVerificationPort(),
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppSettings>.value(
        value: settings,
        child: MaterialApp(
          home: AppConnectionRouteScope(
            connectionRepository: repository,
            credentialRepository: _FakeCredentialRepository(),
            hostKeyRepository: repository,
            runtimePort: _FakeRuntimePort(),
            verificationPort: _FakeVerificationPort(),
            viewModel: viewModel,
            child: Builder(
              builder: (context) => Text(
                identical(context.read<ConnectionViewModel>(), viewModel)
                    ? 'same'
                    : 'different',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('same'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await viewModel.fetchConnections();
    expect(viewModel.connections, isEmpty);
  });
}

final class _FakeConnectionRepository
    implements ConnectionRepository, HostKeyRepository {
  final List<ConnectionConfig> _connections = [];

  @override
  List<ConnectionConfig> get connections => List.unmodifiable(_connections);

  @override
  Future<void> initialize() async {}

  @override
  Future<List<ConnectionConfig>> loadConnections() async => connections;

  @override
  Future<void> addConnection(ConnectionConfig config) async {
    _connections.add(config);
  }

  @override
  Future<void> updateConnection(ConnectionConfig config) async {}

  @override
  Future<void> deleteConnection(String id) async {}

  @override
  Future<void> deleteConnections(List<String> ids) async {}

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {}

  @override
  ConnectionConfig? getConnection(String id) => null;

  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) async {}
}

final class _FakeCredentialRepository implements CredentialRepository {
  @override
  Future<String?> getPassword(String connectionId) async => null;

  @override
  Future<String?> getPrivateKey(String connectionId) async => null;

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) async {}

  @override
  Future<void> deleteCredentials(String connectionId) async {}
}

final class _FakeRuntimePort implements ConnectionRuntimePort {
  @override
  String? get errorMessage => null;

  @override
  Future<int> activeWindowCount(String connectionId) async => 0;

  @override
  Future<void> disconnectSessionsForConnection(String connectionId) async {}

  @override
  Future<void> cleanupConnectionResources(String connectionId) async {}

  @override
  Future<String?> openTerminalSession(
    String connectionId,
    String windowName, {
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) async => null;
}

final class _FakeVerificationPort implements ConnectionVerificationPort {
  @override
  Future<ConnectionVerificationResult> verify(
    ConnectionConfig config, {
    required String? password,
    required String? privateKey,
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) async => const ConnectionVerificationResult();
}
