// 测试用 App 存储组合器。
//
// 该夹具只用于把旧测试场景接到当前的 AppAiStorageAdapter、Connection
// Repository、Playbook Repository 和终端元数据 Owner。它不恢复生产中的
// 统一存储门面，也不创建共享业务数据库；每个测试实例都拥有独立的
// 内存 Repository 和显式的关闭路径。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:drift/native.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_playbook/feature_playbook.dart' as playbook;
import 'package:feature_rag/feature_rag.dart' as rag;
import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ai_storage_adapter.dart';
import 'package:ssh_mobile/services/connection_target_binding.dart';
import 'package:ssh_mobile/services/remote_target_scope.dart';
import 'package:ssh_mobile/app/sftp_backend_adapters.dart';
import 'package:ssh_mobile/services/ssh_service.dart'
    hide TerminalHistoryRecord;
import 'package:ssh_mobile/services/terminal_session_metadata_store.dart';
import 'package:ssh_mobile/app/monitoring_feature_adapters.dart';
import 'package:ssh_mobile/app/playbook_feature_adapters.dart';

part 'test_storage_adapter_connections.dart';
part 'test_storage_adapter_ai.dart';
part 'test_storage_adapter_session.dart';
part 'test_storage_adapter_lifecycle.dart';
part 'test_storage_adapter_rag.dart';
part 'test_storage_adapter_factories.dart';
part 'test_storage_adapter_repositories.dart';

/// Shared construction state for the test storage facade.
abstract class _TestStorageAdapterBase extends ChangeNotifier
    implements playbook.PlaybookRepository {
  /// Creates isolated in-memory repositories for one test fixture.
  _TestStorageAdapterBase({
    Object? database,
    Object Function()? databaseFactory,
    Future<void> Function()? initializationCheckpoint,
  }) {
    assert(database == null || databaseFactory == null);
    final connections = _TestConnectionRepository();
    final credentials = _TestCredentialRepository();
    final hostKeys = _TestHostKeyRepository(connections);
    final playbooks = _TestPlaybookRepository();
    final terminalMetadata = TerminalSessionMetadataStore();
    connectionRepository = connections;
    credentialRepository = credentials;
    hostKeyRepository = hostKeys;
    playbookRepository = playbooks;
    terminalMetadataStore = terminalMetadata;
    _delegate = AppAiStorageAdapter(
      connectionRepository: connectionRepository,
      credentialRepository: credentialRepository,
      hostKeyRepository: hostKeyRepository,
      playbookRepository: playbookRepository,
      aiModule: ai.AiModule(),
      terminalMetadataStore: terminalMetadataStore,
      initializationCheckpoint: initializationCheckpoint,
    );
    _delegate.attachAiRepositoryLoader(_loadDefaultAiRepository);
  }

  late final ConnectionRepository connectionRepository;
  late final CredentialRepository credentialRepository;
  late final HostKeyRepository hostKeyRepository;
  late final playbook.PlaybookRepository playbookRepository;
  late final TerminalSessionMetadataStore terminalMetadataStore;
  final InMemorySftpPathHistoryStore sftpPathHistory =
      InMemorySftpPathHistoryStore();
  late final AppAiStorageAdapter _delegate;
  final List<ai.AiDatabase> _ownedAiDatabases = [];
  final List<TestRagService> _ownedRagServices = [];

  /// 真实 AI Port 视图，供测试显式注入 Feature。
  ai.AiStoragePort get aiStoragePort =>
      _TestAiStoragePort(this as TestStorageAdapter);

  /// 真实 App AI 适配器，供仍处于 App Shell 的旧 RAG 兼容服务使用。
  AppAiStorageAdapter get aiStorage => _delegate;

  Future<void> get initFuture => _delegate.initFuture;
  bool get initialized => _delegate.initialized;
  bool get powerGuideSeen => _delegate.powerGuideSeen;
  List<ConnectionConfig> get connections => _delegate.connections;
  ConnectionConfig? getConnection(String id) => _delegate.getConnection(id);
  List<int> get secretCacheTtlOptionsMinutes =>
      _delegate.secretCacheTtlOptionsMinutes;
  bool get isSecretCacheEnabled => _delegate.isSecretCacheEnabled;
  int get secretCacheTtlMinutes => _delegate.secretCacheTtlMinutes;
  Duration get secretCacheTtl => _delegate.secretCacheTtl;

  Future<ai.AiRepository> _loadDefaultAiRepository() async {
    final database = ai.AiDatabase.forTesting(NativeDatabase.memory());
    _ownedAiDatabases.add(database);
    return ai.DriftAiRepository(database, const _TestAiTextProtection());
  }
}

/// Public facade retaining the historical test helper API.
class TestStorageAdapter extends _TestStorageAdapterBase
    with
        _TestStorageAdapterConnections,
        _TestStorageAdapterAi,
        _TestStorageAdapterSession,
        _TestStorageAdapterLifecycle {
  TestStorageAdapter({
    super.database,
    super.databaseFactory,
    super.initializationCheckpoint,
  });
}
