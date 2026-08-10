import 'package:app_core/app_core.dart';
import 'package:drift/native.dart';
import 'package:feature_sftp/feature_sftp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';

import '../fakes/sftp_test_fakes.dart';

void main() {
  test('SftpViewModel exposes the Module-owned service state', () async {
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
    await module.initialize();
    await module.activate();

    final viewModel = SftpViewModel(module.service);
    expect(viewModel.connectionId, isNull);
    expect(viewModel.currentPath, equals('.'));
    expect(viewModel.state, equals(SftpConnectionState.disconnected));
    expect(viewModel.entries, isEmpty);
    expect(viewModel.isConnected, isFalse);
    expect(viewModel.isBusy, isFalse);
    expect(viewModel.activeTransfer, isNull);
    expect(viewModel.hasActiveTransfer, isFalse);
    expect(viewModel.isConnectionBusy('conn_1'), isFalse);
    expect(viewModel.isConnectionOpen('conn_1'), isFalse);

    expect(() => viewModel.disconnect(), returnsNormally);
    expect(() => viewModel.refresh(), returnsNormally);
    expect(() => viewModel.cancelActiveTransfer(), returnsNormally);

    viewModel.dispose();
    await module.dispose();
  });
}
