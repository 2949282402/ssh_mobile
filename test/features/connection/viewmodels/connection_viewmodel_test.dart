import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/connection/viewmodels/connection_viewmodel.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;
  late SshService sshService;
  late SftpService sftpService;
  late PerformanceMonitorService performanceService;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = StorageService();
    await storageService.init();

    sshService = SshService(storageService);
    sftpService = SftpService(storageService);
    performanceService = PerformanceMonitorService(sshService, storageService);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    storageService.dispose();
  });

  group('ConnectionViewModel Tests', () {
    test('Initialization and fetchConnections', () async {
      final viewModel = ConnectionViewModel(
        connectionRepository: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceService: performanceService,
      );

      expect(viewModel.connections, isEmpty);
      expect(viewModel.isLoading, isFalse);

      final config = ConnectionConfig(
        id: 'conn_1',
        name: 'Test Server',
        host: '127.0.0.1',
        port: 22,
        username: 'test',
        authMethod: AuthMethod.password,
      );
      await storageService.addConnection(config);

      await viewModel.fetchConnections();
      expect(viewModel.connections, hasLength(1));
      expect(viewModel.connections.first.name, equals('Test Server'));
    });

    test(
      'deleteConnectionWithCleanup triggers disconnects and deletes',
      () async {
        final viewModel = ConnectionViewModel(
          connectionRepository: storageService,
          sshService: sshService,
          sftpService: sftpService,
          performanceService: performanceService,
        );

        final config = ConnectionConfig(
          id: 'conn_1',
          name: 'Test Server',
          host: '127.0.0.1',
          port: 22,
          username: 'test',
          authMethod: AuthMethod.password,
        );
        await storageService.addConnection(config);
        await viewModel.fetchConnections();
        expect(viewModel.connections, hasLength(1));

        await viewModel.deleteConnectionWithCleanup('conn_1');

        await viewModel.fetchConnections();
        expect(viewModel.connections, isEmpty);
      },
    );

    test('deleteConnectionsWithCleanup batch delete', () async {
      final viewModel = ConnectionViewModel(
        connectionRepository: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceService: performanceService,
      );

      final config1 = ConnectionConfig(
        id: 'conn_1',
        name: 'Server 1',
        host: '127.0.0.1',
        port: 22,
        username: 'test',
        authMethod: AuthMethod.password,
      );
      final config2 = ConnectionConfig(
        id: 'conn_2',
        name: 'Server 2',
        host: '127.0.0.2',
        port: 22,
        username: 'test',
        authMethod: AuthMethod.password,
      );
      await storageService.addConnection(config1);
      await storageService.addConnection(config2);
      await viewModel.fetchConnections();
      expect(viewModel.connections, hasLength(2));

      await viewModel.deleteConnectionsWithCleanup(['conn_1', 'conn_2']);
      await viewModel.fetchConnections();
      expect(viewModel.connections, isEmpty);
    });

    test(
      'openTerminalSession handle error or returns null/session id',
      () async {
        final viewModel = ConnectionViewModel(
          connectionRepository: storageService,
          sshService: sshService,
          sftpService: sftpService,
          performanceService: performanceService,
        );

        final sessionId = await viewModel.openTerminalSession(
          'conn_1',
          'my_window',
        );
        expect(sessionId, isNull);
        expect(viewModel.errorMessage, isNotNull);
      },
    );
  });
}
