// SFTP Feature 的业务模型。
//
// 这些模型不持有 Flutter Controller、SSH Client 或数据库句柄，便于
// Repository、ViewModel 和 App Shell Port 独立测试。

import 'dart:typed_data';

/// SFTP 连接页面的状态。
enum SftpConnectionState { disconnected, connecting, connected, loading, error }

/// 远程目录中的一个文件或目录条目。
final class SftpEntry {
  /// 创建目录条目快照。
  const SftpEntry({
    required this.connectionId,
    required this.name,
    required this.path,
    required this.lowerName,
    required this.isDirectory,
    required this.isLink,
    required this.sizeLabel,
    this.size,
    this.modifiedAt,
    this.modifiedLabel,
  });

  final String connectionId;
  final String name;
  final String path;
  final String lowerName;
  final bool isDirectory;
  final bool isLink;
  final int? size;
  final String sizeLabel;
  final DateTime? modifiedAt;
  final String? modifiedLabel;
}

/// 远端路径元数据。
final class SftpPathInfo {
  /// 创建路径元数据快照。
  const SftpPathInfo({
    required this.path,
    required this.isDirectory,
    required this.isLink,
    required this.size,
    required this.sizeLabel,
    required this.modifiedAt,
  });

  final String path;
  final bool isDirectory;
  final bool isLink;
  final int? size;
  final String sizeLabel;
  final DateTime? modifiedAt;

  /// 为工具调用和诊断输出生成不含凭据的 JSON。
  Map<String, dynamic> toJson() => {
    'path': path,
    'type': isDirectory ? 'directory' : 'file',
    'isDirectory': isDirectory,
    'isLink': isLink,
    'size': size,
    'sizeLabel': sizeLabel,
    'modifiedAt': modifiedAt?.toIso8601String(),
  };
}

/// 传输方向。
enum SftpTransferDirection { upload, download }

/// 用户主动取消传输时抛出的异常。
final class SftpTransferCancelledException implements Exception {
  /// 创建取消异常。
  const SftpTransferCancelledException([
    this.message = 'Transfer cancelled by user',
  ]);

  final String message;

  @override
  String toString() => 'SftpTransferCancelledException: $message';
}

/// 文本编辑内容超过调用方限制时抛出的异常。
final class SftpTextSizeLimitException implements Exception {
  /// 创建文本大小限制异常。
  const SftpTextSizeLimitException({
    required this.actualBytes,
    required this.maxBytes,
  });

  final int actualBytes;
  final int maxBytes;

  @override
  String toString() =>
      'SftpTextSizeLimitException: text is $actualBytes bytes, '
      'limit is $maxBytes bytes';
}

/// 远端文件读取超过内存上限时抛出的异常。
final class SftpFileSizeLimitException extends StateError {
  /// 创建有界读取异常；读取端会在超过上限的第一个 chunk 处停止。
  SftpFileSizeLimitException({
    required this.observedBytes,
    required this.maxBytes,
  }) : super(
         'SFTP file exceeds the in-memory read limit '
         '($observedBytes bytes > $maxBytes bytes).',
       );

  final int observedBytes;
  final int maxBytes;
}

/// 当前传输的有界进度快照。
final class SftpTransferState {
  /// 创建传输进度。
  const SftpTransferState({
    required this.id,
    required this.name,
    required this.totalBytes,
    required this.isUpload,
    this.bytesTransferred = 0,
    this.isCancelled = false,
    this.isError = false,
    this.errorMessage,
  });

  final String id;
  final String name;
  final int totalBytes;
  final bool isUpload;
  final int bytesTransferred;
  final bool isCancelled;
  final bool isError;
  final String? errorMessage;

  /// 返回 0 到 1 之间的展示进度。
  double get progress => totalBytes > 0 ? bytesTransferred / totalBytes : 0.0;

  /// 创建更新进度后的不可变快照。
  SftpTransferState copyWith({
    int? bytesTransferred,
    bool? isCancelled,
    bool? isError,
    String? errorMessage,
  }) => SftpTransferState(
    id: id,
    name: name,
    totalBytes: totalBytes,
    isUpload: isUpload,
    bytesTransferred: bytesTransferred ?? this.bytesTransferred,
    isCancelled: isCancelled ?? this.isCancelled,
    isError: isError ?? this.isError,
    errorMessage: errorMessage ?? this.errorMessage,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SftpTransferState &&
          other.id == id &&
          other.name == name &&
          other.totalBytes == totalBytes &&
          other.isUpload == isUpload &&
          other.bytesTransferred == bytesTransferred &&
          other.isCancelled == isCancelled &&
          other.isError == isError &&
          other.errorMessage == errorMessage;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    totalBytes,
    isUpload,
    bytesTransferred,
    isCancelled,
    isError,
    errorMessage,
  );
}

/// 最近访问的远程路径。
final class SftpRecentPathRecord {
  /// 创建最近路径记录。
  const SftpRecentPathRecord({
    required this.id,
    required this.connectionId,
    required this.path,
    required this.visitedAt,
  });

  final String id;
  final String connectionId;
  final String path;
  final DateTime visitedAt;
}

/// 用户收藏的远程路径。
final class SftpFavoritePathRecord {
  /// 创建收藏路径记录。
  const SftpFavoritePathRecord({
    required this.id,
    required this.connectionId,
    required this.path,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String connectionId;
  final String path;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 更新展示名称而不改变收藏身份和路径。
  SftpFavoritePathRecord copyWith({String? name, DateTime? updatedAt}) =>
      SftpFavoritePathRecord(
        id: id,
        connectionId: connectionId,
        path: path,
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// App Shell 提供给 SFTP UI 的最小连接信息。
final class SftpConnectionInfo {
  /// 创建连接展示快照；不包含密码和私钥。
  const SftpConnectionInfo({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
}

/// 兼容工具层所需的字节类型标记，集中说明传输 API 以二进制为边界。
typedef SftpBytes = Uint8List;
