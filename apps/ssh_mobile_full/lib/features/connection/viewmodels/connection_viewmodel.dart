import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:feature_connection/feature_connection.dart' as feature;

import '../../../app/connection_feature_adapters.dart';
import '../../../services/app_log_service.dart';
import '../../../services/performance_monitor_service.dart';
import '../../../services/sftp_service.dart';
import '../../../services/ssh_service.dart';

/// 旧 App 路径的 Connection ViewModel 转发包装器。
///
/// 真实实现位于 `feature_connection`；本文件只保留旧导入路径，并要求
/// 调用方显式注入 Core Repository，避免重新创建统一存储依赖。
@Deprecated('Import ConnectionViewModel from package:feature_connection')
class ConnectionViewModel extends feature.ConnectionViewModel {
  /// 创建兼容包装器，所有基础设施均由调用方注入。
  ConnectionViewModel({
    required connection_core.ConnectionRepository connectionRepository,
    required connection_core.CredentialRepository credentialRepository,
    required connection_core.HostKeyRepository hostKeyRepository,
    feature.ConnectionRuntimePort? runtimePort,
    feature.ConnectionVerificationPort? verificationPort,
    SshService? sshService,
    SftpService? sftpService,
    PerformanceMonitorService? performanceService,
    SshService Function()? sshServiceFactory,
    SftpService Function()? sftpServiceFactory,
    PerformanceMonitorService Function()? performanceServiceFactory,
  }) : super(
         connectionRepository: connectionRepository,
         credentialRepository: credentialRepository,
         hostKeyRepository: hostKeyRepository,
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
               credentialRepository: credentialRepository,
               hostKeyRepository: hostKeyRepository,
               logger: AppLogService.instance,
             ),
       );
}
