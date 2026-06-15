part of '../sftp_service.dart';

enum SftpConnectionState {
  disconnected,
  connecting,
  connected,
  loading,
  error,
}

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
