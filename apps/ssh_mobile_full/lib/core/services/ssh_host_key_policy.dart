// SSH Host Key 策略兼容层。
//
// 唯一实现位于 ssh_core；本文件只提供 App 侧兼容的 `SshHostKeyPolicy`，默认
// 使用 `AppLogService.instance` 记录日志，其它类型直接 re-export ssh_core。

import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../../services/app_log_service.dart';

export 'package:ssh_core/ssh_core.dart'
    show
        SshHostKeyConfirmation,
        SshHostKeyMismatchException,
        SshHostKeyPromptRequest,
        SshHostKeyRejectedException,
        SshHostKeyTrustPersister,
        SshHostKeyUntrustedException;

/// App 侧 Host Key 校验策略；默认日志走 [AppLogService.instance]。
class SshHostKeyPolicy extends ssh_core.SshHostKeyPolicy {
  /// 创建 App 侧 Host Key 策略。
  SshHostKeyPolicy({super.onUnknownHostKey, super.persistTrust, super.now})
    : super(logger: AppLogService.instance);
}
