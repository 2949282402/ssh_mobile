import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feature_developer/feature_developer.dart';

void main() {
  test('module snapshot exposes initialized and active flags', () {
    const registered = DeveloperModuleSnapshot(
      id: 'feature_ai',
      state: ModuleState.registered,
    );
    const active = DeveloperModuleSnapshot(
      id: 'feature_terminal',
      state: ModuleState.active,
    );
    const inactive = DeveloperModuleSnapshot(
      id: 'feature_sftp',
      state: ModuleState.inactive,
    );
    const disposed = DeveloperModuleSnapshot(
      id: 'feature_mcp',
      state: ModuleState.disposed,
    );

    expect(registered.initialized, isFalse);
    expect(registered.active, isFalse);
    expect(active.initialized, isTrue);
    expect(active.active, isTrue);
    expect(inactive.initialized, isTrue);
    expect(inactive.active, isFalse);
    expect(disposed.initialized, isFalse);
    expect(disposed.active, isFalse);
  });

  test('diagnostics snapshot freezes collection values', () {
    final snapshot = DeveloperDiagnosticsSnapshot(
      capturedAt: DateTime(2026, 8, 9),
      modules: const [
        DeveloperModuleSnapshot(
          id: 'feature_playbook',
          state: ModuleState.active,
        ),
      ],
      ssh: const DeveloperSshSnapshot(
        activeSessions: 1,
        idleSessions: 0,
        leaseCount: 1,
      ),
      network: const DeveloperNetworkSnapshot(
        activeConnections: 0,
        nativeHandles: 1,
      ),
      databases: const [
        DeveloperDatabaseSnapshot(
          moduleId: 'feature_playbook',
          databaseName: 'playbook.db',
          opened: true,
        ),
      ],
      resources: const DeveloperResourceSnapshot(
        activeTimers: 1,
        activeSubscriptions: 2,
      ),
    );

    expect(snapshot.modules, hasLength(1));
    expect(snapshot.databases.single.opened, isTrue);
    expect(
      () => snapshot.modules.add(
        const DeveloperModuleSnapshot(
          id: 'feature_ai',
          state: ModuleState.registered,
        ),
      ),
      throwsUnsupportedError,
    );
  });
}
