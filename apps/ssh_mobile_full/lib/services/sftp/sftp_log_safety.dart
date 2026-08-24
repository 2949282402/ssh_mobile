import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// SFTP 诊断日志的稳定、不可逆上下文编码。
///
/// 远程/本地路径和底层异常文本都可能包含用户名、密钥位置或 Token，因此日志
/// 只记录操作名、稳定错误码、不可逆路径摘要和非敏感计数。
abstract final class SftpLogSafety {
  static String pathHash(String path) =>
      sha256.convert(utf8.encode(path)).toString();

  static String errorCode(Object error) => switch (error) {
    TimeoutException() => 'timeout',
    FileSystemException() => 'filesystem_error',
    FormatException() => 'invalid_format',
    ArgumentError() => 'invalid_argument',
    StateError() => 'invalid_state',
    _ => 'operation_failed',
  };

  static String details({
    required String operation,
    String? connectionId,
    String? path,
    String? destinationPath,
    int? bytes,
    int? maxBytes,
    bool? directory,
    Object? error,
  }) {
    final fields = <String>[
      'operation=$operation',
      if (connectionId != null) 'connectionId=$connectionId',
      if (path != null) 'pathHash=${pathHash(path)}',
      if (destinationPath != null)
        'destinationPathHash=${pathHash(destinationPath)}',
      if (bytes != null) 'bytes=$bytes',
      if (maxBytes != null) 'maxBytes=$maxBytes',
      if (directory != null) 'directory=$directory',
      if (error != null) 'code=${errorCode(error)}',
    ];
    return fields.join(' ');
  }
}
