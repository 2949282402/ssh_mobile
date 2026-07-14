import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

export 'sftp/sftp_service_stub.dart'
    if (dart.library.io) 'sftp/sftp_service_io.dart';

enum SftpConnectionState { disconnected, connecting, connected, loading, error }

class SftpEntry {
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
}

class SftpPathInfo {
  final String path;
  final bool isDirectory;
  final bool isLink;
  final int? size;
  final String sizeLabel;
  final DateTime? modifiedAt;

  const SftpPathInfo({
    required this.path,
    required this.isDirectory,
    required this.isLink,
    required this.size,
    required this.sizeLabel,
    required this.modifiedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'type': isDirectory ? 'directory' : 'file',
      'isDirectory': isDirectory,
      'isLink': isLink,
      'size': size,
      'sizeLabel': sizeLabel,
      'modifiedAt': modifiedAt?.toIso8601String(),
    };
  }
}

enum SftpTransferDirection { upload, download }

class SftpTransferCancelledException implements Exception {
  final String message;
  const SftpTransferCancelledException([
    this.message = 'Transfer cancelled by user',
  ]);

  @override
  String toString() => 'SftpTransferCancelledException: $message';
}

class SftpTextSizeLimitException implements Exception {
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

class SftpTransferState {
  final String id;
  final String name;
  final int totalBytes;
  final bool isUpload;
  final int bytesTransferred;
  final bool isCancelled;
  final bool isError;
  final String? errorMessage;

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

  double get progress => totalBytes > 0 ? bytesTransferred / totalBytes : 0.0;

  SftpTransferState copyWith({
    int? bytesTransferred,
    bool? isCancelled,
    bool? isError,
    String? errorMessage,
  }) {
    return SftpTransferState(
      id: id,
      name: name,
      totalBytes: totalBytes,
      isUpload: isUpload,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      isCancelled: isCancelled ?? this.isCancelled,
      isError: isError ?? this.isError,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SftpTransferState &&
        other.id == id &&
        other.name == name &&
        other.totalBytes == totalBytes &&
        other.isUpload == isUpload &&
        other.bytesTransferred == bytesTransferred &&
        other.isCancelled == isCancelled &&
        other.isError == isError &&
        other.errorMessage == errorMessage;
  }

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

abstract interface class SftpClientAdapter {
  String? get connectionId;
  String? get connectionName;
  String get currentPath;
  SftpConnectionState get state;
  String? get errorMessage;
  int get entriesRevision;
  List<SftpEntry> get entries;
  bool get isConnected;
  bool get isBusy;
  SftpTransferState? get activeTransfer;
  bool get hasActiveTransfer;

  bool isConnectionBusy(String connectionId);

  bool isConnectionOpen(String connectionId);

  Future<void> connect(String connectionId, {dynamic onUnknownHostKey});

  Future<void> refresh();

  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  });

  Future<void> uploadFile({
    required String localPath,
    required String filename,
  });

  Future<void> deleteEntry(SftpEntry entry, {required String confirmedName});

  Future<List<SftpEntry>> listDirectoryForConnection(
    String connectionId,
    String path,
  );

  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes,
  });

  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes,
  });

  Future<void> downloadFile(
    SftpEntry entry, {
    required String localPath,
    int maxBytes,
  });

  Future<SftpPathInfo> statPathForConnection({
    required String connectionId,
    required String path,
  });

  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes,
  });

  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes,
  });

  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  });

  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  });

  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  });

  Future<void> openPath(String path);

  Future<void> openParent();

  Future<void> disconnect({bool notify = true});

  Future<void> disconnectConnection(
    String connectionId, {
    bool notify = true,
    bool forgetPath = false,
  });

  Future<void> disconnectAll({bool notify = true});

  void cancelActiveTransfer();
}
