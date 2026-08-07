import 'dart:async';

import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:feature_connection/feature_connection.dart' as feature;

import '../../../app/connection_feature_adapters.dart';
import '../../../services/performance_monitor_service.dart';
import '../../../services/sftp_service.dart';
import '../../../services/ssh_service.dart';
import '../../../services/storage_service.dart';

/// 旧 App 路径的兼容包装器。
///
/// ConnectionViewModel 的真实实现已经迁移到 `feature_connection`。这个
/// 包装器只为尚未同步改造的测试和旧 Screen 保留原构造参数，并将旧
/// StorageService/SSH Service 适配到 Feature 的公开 Contract；新的业务代码
/// 应直接导入 `package:feature_connection/feature_connection.dart`。
@Deprecated('Import ConnectionViewModel from package:feature_connection')
class ConnectionViewModel extends feature.ConnectionViewModel {
  ConnectionViewModel({
    required connection_core.ConnectionRepository connectionRepository,
    connection_core.CredentialRepository? credentialRepository,
    connection_core.HostKeyRepository? hostKeyRepository,
    feature.ConnectionRuntimePort? runtimePort,
    feature.ConnectionVerificationPort? verificationPort,
    StorageService? legacyStorage,
    SshService? sshService,
    SftpService? sftpService,
    PerformanceMonitorService? performanceService,
    SshService Function()? sshServiceFactory,
    SftpService Function()? sftpServiceFactory,
    PerformanceMonitorService Function()? performanceServiceFactory,
  }) : super(
         connectionRepository: connectionRepository,
         credentialRepository:
             credentialRepository ??
             _legacyCredentialRepository(
               _resolveLegacyStorage(connectionRepository, legacyStorage),
             ),
         hostKeyRepository:
             hostKeyRepository ??
             _resolveHostKeyRepository(connectionRepository),
         runtimePort:
             runtimePort ??
             AppConnectionRuntimeAdapter(
               sshServiceFactory:
                   sshServiceFactory ??
                   (sshService != null ? () => sshService : null),
               sftpServiceFactory:
                   sftpServiceFactory ??
                   (sftpService != null ? () => sftpService : null),
               performanceServiceFactory:
                   performanceServiceFactory ??
                   (performanceService != null
                       ? () => performanceService
                       : null),
             ),
         verificationPort:
             verificationPort ??
             AppConnectionVerificationAdapter(
               _resolveLegacyStorage(connectionRepository, legacyStorage),
             ),
       ) {
    _legacyStorage = _tryResolveLegacyStorage(
      connectionRepository,
      legacyStorage,
    );
    _legacyStorage?.addListener(_onLegacyStorageChanged);
  }

  StorageService? _legacyStorage;

  void _onLegacyStorageChanged() {
    unawaited(fetchConnections());
  }

  @override
  void dispose() {
    _legacyStorage?.removeListener(_onLegacyStorageChanged);
    super.dispose();
  }
}

StorageService _resolveLegacyStorage(
  connection_core.ConnectionRepository repository,
  StorageService? explicit,
) {
  final resolved = _tryResolveLegacyStorage(repository, explicit);
  if (resolved == null) {
    throw ArgumentError(
      'A legacy StorageService is required by the compatibility constructor.',
    );
  }
  return resolved;
}

StorageService? _tryResolveLegacyStorage(
  connection_core.ConnectionRepository repository,
  StorageService? explicit,
) => explicit ?? (repository is StorageService ? repository : null);

connection_core.HostKeyRepository _resolveHostKeyRepository(
  connection_core.ConnectionRepository repository,
) {
  if (repository is connection_core.HostKeyRepository) {
    return repository as connection_core.HostKeyRepository;
  }
  throw ArgumentError(
    'A HostKeyRepository is required by the compatibility constructor.',
  );
}

connection_core.CredentialRepository _legacyCredentialRepository(
  StorageService storage,
) => _StorageCredentialRepository(storage);

/// 旧 StorageService 的凭据兼容实现。
///
/// 旧 ConnectionRepository 会在 add/update 时保存配置中的运行时凭据，
/// 因此这里的写入和删除由旧结构 Repository 完成，避免在兼容层再复制一套
/// Secure Storage Key 规则。新 App 根则使用双写的完整适配器。
final class _StorageCredentialRepository
    implements connection_core.CredentialRepository {
  _StorageCredentialRepository(this._storage);

  final StorageService _storage;

  @override
  Future<String?> getPassword(String connectionId) =>
      _storage.getPassword(connectionId);

  @override
  Future<String?> getPrivateKey(String connectionId) =>
      _storage.getPrivateKey(connectionId);

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) async {
    // StorageService 已在 add/update 时由 ConnectionRepository 写入。
  }

  @override
  Future<void> deleteCredentials(String connectionId) async {
    // StorageService 已在 deleteConnection(s) 时由 ConnectionRepository 清理。
  }
}
