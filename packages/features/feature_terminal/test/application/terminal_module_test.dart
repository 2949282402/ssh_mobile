import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_core/app_core.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:ssh_core/ssh_core.dart';

import '../fakes/terminal_test_fakes.dart';

void main() {
  test(
    'TerminalModule shares initialization and owns the database lifecycle',
    () async {
      final manager = FakeSshSessionManager(FakeTerminalCapability());
      final database = TerminalDatabase.forTesting(NativeDatabase.memory());
      final module = TerminalModule(databaseFactory: () => database);

      await module.register(
        ModuleContext.fromMap(<Type, Object>{SshSessionManager: manager}),
      );
      expect(module.sshSessionManager, same(manager));
      expect(module.state, ModuleState.registered);

      final firstInitialization = module.initialize();
      expect(identical(firstInitialization, module.initialize()), isTrue);
      await firstInitialization;
      expect(module.state, ModuleState.initialized);
      expect(module.database, same(database));
      expect(module.historyRepository, isA<TerminalHistoryRepository>());

      await module.activate();
      expect(module.state, ModuleState.active);
      await module.deactivate();
      expect(module.state, ModuleState.inactive);

      final firstDispose = module.dispose();
      expect(identical(firstDispose, module.dispose()), isTrue);
      await firstDispose;
      expect(module.state, ModuleState.disposed);
      expect(() => module.database, throwsStateError);
    },
  );

  test('dispose cancels a late initializer and closes its database', () async {
    final manager = FakeSshSessionManager(FakeTerminalCapability());
    final database = TerminalDatabase.forTesting(NativeDatabase.memory());
    final databaseReady = Completer<TerminalDatabase>();
    final module = TerminalModule(databaseFactory: () => databaseReady.future);
    await module.register(
      ModuleContext.fromMap(<Type, Object>{SshSessionManager: manager}),
    );

    final activation = module.activate();
    final initialization = module.initialize();
    final disposal = module.dispose();
    final activationExpectation = expectLater(activation, throwsStateError);
    final initializationExpectation = expectLater(
      initialization,
      throwsStateError,
    );
    expect(module.state, ModuleState.disposed);
    databaseReady.complete(database);

    await initializationExpectation;
    await activationExpectation;
    await disposal;
    expect(module.state, ModuleState.disposed);
    expect(() => module.database, throwsStateError);
    expect(database.isDisposed, isTrue);
  });
}
