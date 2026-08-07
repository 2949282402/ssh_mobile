// SFTP Module 生命周期测试。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_core/app_core.dart';
import 'package:feature_sftp/feature_sftp.dart';
import 'package:ssh_core/ssh_core.dart';

import '../fakes/sftp_test_fakes.dart';

void main() {
  test('SftpModule shares initialization and owns sftp.db', () async {
    final manager = FakeSshSessionManager();
    final backend = FakeSftpBackend();
    final database = SftpDatabase.forTesting(NativeDatabase.memory());
    final module = SftpModule(databaseFactory: () => database);

    await module.register(
      ModuleContext.fromMap(<Type, Object>{
        SshSessionManager: manager,
        SftpBackend: backend,
      }),
    );
    expect(module.state, ModuleState.registered);

    final firstInitialization = module.initialize();
    expect(identical(firstInitialization, module.initialize()), isTrue);
    await firstInitialization;
    expect(module.state, ModuleState.initialized);
    expect(module.service, isA<SftpService>());

    await module.activate();
    expect(module.state, ModuleState.active);
    await module.service.connect('connection-1');
    await module.service.openPath('/srv');
    expect(manager.ensureInitializedCalls, 1);
    expect(
      (await module.service.loadRecentPaths()).map((record) => record.path),
      contains('/srv'),
    );

    await module.deactivate();
    expect(module.state, ModuleState.inactive);

    final firstDispose = module.dispose();
    expect(identical(firstDispose, module.dispose()), isTrue);
    await firstDispose;
    expect(module.state, ModuleState.disposed);
    expect(() => module.database, throwsStateError);
    expect(() => module.service, throwsStateError);
  });
}
