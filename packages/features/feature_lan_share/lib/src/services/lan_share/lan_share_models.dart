import 'dart:convert';

import 'package:network_sdk/network_sdk.dart';

/// Device type enumeration
enum LanDeviceType {
  mobile,
  desktop,
  webBrowser;

  String toJson() => name;

  static LanDeviceType fromJson(String value) {
    return LanDeviceType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => LanDeviceType.mobile,
    );
  }
}

/// Discovered LAN device entity
class LanDevice {
  final String id;
  final String alias;
  final String ip;
  final int port;
  final int? nativePort;
  final LanDeviceType deviceType;
  final String osName;
  final String? certFingerprint;
  final bool isTrusted;
  final DateTime lastSeen;

  const LanDevice({
    required this.id,
    required this.alias,
    required this.ip,
    required this.port,
    this.nativePort,
    required this.deviceType,
    required this.osName,
    this.certFingerprint,
    this.isTrusted = false,
    required this.lastSeen,
  });

  LanDevice copyWith({
    String? id,
    String? alias,
    String? ip,
    int? port,
    int? nativePort,
    LanDeviceType? deviceType,
    String? osName,
    String? certFingerprint,
    bool? isTrusted,
    DateTime? lastSeen,
  }) {
    return LanDevice(
      id: id ?? this.id,
      alias: alias ?? this.alias,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      nativePort: nativePort ?? this.nativePort,
      deviceType: deviceType ?? this.deviceType,
      osName: osName ?? this.osName,
      certFingerprint: certFingerprint ?? this.certFingerprint,
      isTrusted: isTrusted ?? this.isTrusted,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'alias': alias,
    'ip': ip,
    'port': port,
    if (nativePort != null) 'nativePort': nativePort,
    'deviceType': deviceType.toJson(),
    'osName': osName,
    'certFingerprint': certFingerprint,
    'isTrusted': isTrusted,
    'lastSeen': lastSeen.toIso8601String(),
  };

  factory LanDevice.fromJson(Map<String, dynamic> json) {
    return LanDevice(
      id: json['id'] as String? ?? '',
      alias: json['alias'] as String? ?? 'Unknown Device',
      ip: json['ip'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 53317,
      nativePort: (json['nativePort'] as num?)?.toInt(),
      deviceType: LanDeviceType.fromJson(json['deviceType'] as String? ?? ''),
      osName: json['osName'] as String? ?? 'Unknown OS',
      certFingerprint: json['certFingerprint'] as String?,
      isTrusted: json['isTrusted'] as bool? ?? false,
      lastSeen: json['lastSeen'] != null
          ? DateTime.tryParse(json['lastSeen'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

/// A short-lived navigation and protocol request for pairing two LAN devices.
class LanPairingRequest {
  final LanDevice device;
  final String sessionId;
  final bool isIncoming;
  final DateTime expiresAt;

  const LanPairingRequest({
    required this.device,
    required this.sessionId,
    required this.isIncoming,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class LanRecallRequest {
  final String senderDeviceId;
  final String messageId;

  const LanRecallRequest({
    required this.senderDeviceId,
    required this.messageId,
  });
}

/// Payload type for LAN transfers
enum LanPayloadType {
  text,
  image,
  video,
  audio,
  file,
  directory,
  clipboard,
  sftpRelay;

  String toJson() => name;

  static LanPayloadType fromJson(String value) {
    return LanPayloadType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => LanPayloadType.file,
    );
  }
}

/// Transfer status state
enum LanTransferStatus {
  pending,
  connecting,
  transferring,
  completed,
  failed,
  cancelled,
  recalled;

  String toJson() => name;

  static LanTransferStatus fromJson(String value) {
    return LanTransferStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => LanTransferStatus.pending,
    );
  }
}

/// Entry item within a multi-file or directory manifest
class FileManifestEntry {
  final String relativePath;
  final int size;
  final String? sha256;

  const FileManifestEntry({
    required this.relativePath,
    required this.size,
    this.sha256,
  });

  Map<String, dynamic> toJson() => {
    'relativePath': relativePath,
    'size': size,
    'sha256': sha256,
  };

  factory FileManifestEntry.fromJson(Map<String, dynamic> json) {
    return FileManifestEntry(
      relativePath: json['relativePath'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      sha256: json['sha256'] as String?,
    );
  }
}

/// Directory or multi-file payload manifest
class FileManifest {
  final int totalFiles;
  final int totalSize;
  final List<FileManifestEntry> entries;

  const FileManifest({
    required this.totalFiles,
    required this.totalSize,
    required this.entries,
  });

  Map<String, dynamic> toJson() => {
    'totalFiles': totalFiles,
    'totalSize': totalSize,
    'entries': entries.map((e) => e.toJson()).toList(),
  };

  factory FileManifest.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'] as List<dynamic>? ?? [];
    return FileManifest(
      totalFiles: (json['totalFiles'] as num?)?.toInt() ?? 0,
      totalSize: (json['totalSize'] as num?)?.toInt() ?? 0,
      entries: rawEntries
          .map((e) => FileManifestEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  String encodeJson() => jsonEncode(toJson());

  factory FileManifest.decodeJson(String source) {
    return FileManifest.fromJson(jsonDecode(source) as Map<String, dynamic>);
  }
}

/// Transfer record / message model
class LanMessage {
  final String id;
  final String senderId;
  final String senderAlias;
  final String receiverId;
  final LanPayloadType payloadType;
  final String? textContent;
  final String? fileName;
  final int fileSize;
  final String? localPath;
  final FileManifest? manifest;
  final LanTransferStatus status;
  final NetworkRouteType? routeType;
  final int bytesTransferred;
  final DateTime createdAt;
  final bool isIncoming;
  final bool isRecalled;
  final String? sftpServerId;
  final String? sftpRemotePath;

  const LanMessage({
    required this.id,
    required this.senderId,
    required this.senderAlias,
    required this.receiverId,
    required this.payloadType,
    this.textContent,
    this.fileName,
    this.fileSize = 0,
    this.localPath,
    this.manifest,
    this.status = LanTransferStatus.pending,
    this.routeType,
    this.bytesTransferred = 0,
    required this.createdAt,
    required this.isIncoming,
    this.isRecalled = false,
    this.sftpServerId,
    this.sftpRemotePath,
  });

  double get progress =>
      fileSize > 0 ? (bytesTransferred / fileSize).clamp(0.0, 1.0) : 0.0;

  LanMessage copyWith({
    String? id,
    String? senderId,
    String? senderAlias,
    String? receiverId,
    LanPayloadType? payloadType,
    String? textContent,
    String? fileName,
    int? fileSize,
    String? localPath,
    FileManifest? manifest,
    LanTransferStatus? status,
    NetworkRouteType? routeType,
    int? bytesTransferred,
    DateTime? createdAt,
    bool? isIncoming,
    bool? isRecalled,
    String? sftpServerId,
    String? sftpRemotePath,
  }) {
    return LanMessage(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      senderAlias: senderAlias ?? this.senderAlias,
      receiverId: receiverId ?? this.receiverId,
      payloadType: payloadType ?? this.payloadType,
      textContent: textContent ?? this.textContent,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      localPath: localPath ?? this.localPath,
      manifest: manifest ?? this.manifest,
      status: status ?? this.status,
      routeType: routeType ?? this.routeType,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      createdAt: createdAt ?? this.createdAt,
      isIncoming: isIncoming ?? this.isIncoming,
      isRecalled: isRecalled ?? this.isRecalled,
      sftpServerId: sftpServerId ?? this.sftpServerId,
      sftpRemotePath: sftpRemotePath ?? this.sftpRemotePath,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'senderId': senderId,
    'senderAlias': senderAlias,
    'receiverId': receiverId,
    'payloadType': payloadType.toJson(),
    'textContent': textContent,
    'fileName': fileName,
    'fileSize': fileSize,
    'localPath': localPath,
    'manifest': manifest?.toJson(),
    'status': status.toJson(),
    'routeType': routeType?.name,
    'bytesTransferred': bytesTransferred,
    'createdAt': createdAt.toIso8601String(),
    'isIncoming': isIncoming,
    'isRecalled': isRecalled,
    'sftpServerId': sftpServerId,
    'sftpRemotePath': sftpRemotePath,
  };

  factory LanMessage.fromJson(Map<String, dynamic> json) {
    return LanMessage(
      id: json['id'] as String? ?? '',
      senderId: json['senderId'] as String? ?? '',
      senderAlias: json['senderAlias'] as String? ?? '',
      receiverId: json['receiverId'] as String? ?? '',
      payloadType: LanPayloadType.fromJson(
        json['payloadType'] as String? ?? '',
      ),
      textContent: json['textContent'] as String?,
      fileName: json['fileName'] as String?,
      fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
      localPath: json['localPath'] as String?,
      manifest: json['manifest'] != null
          ? FileManifest.fromJson(json['manifest'] as Map<String, dynamic>)
          : null,
      status: LanTransferStatus.fromJson(json['status'] as String? ?? ''),
      routeType: networkRouteTypeFromJson(json['routeType'] as String?),
      bytesTransferred: (json['bytesTransferred'] as num?)?.toInt() ?? 0,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      isIncoming: json['isIncoming'] as bool? ?? false,
      isRecalled: json['isRecalled'] as bool? ?? false,
      sftpServerId: json['sftpServerId'] as String?,
      sftpRemotePath: json['sftpRemotePath'] as String?,
    );
  }
}

NetworkRouteType? networkRouteTypeFromJson(String? value) {
  if (value == null || value.isEmpty) return null;
  for (final route in NetworkRouteType.values) {
    if (route.name == value) return route;
  }
  return null;
}
