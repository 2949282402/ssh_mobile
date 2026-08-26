import 'dart:convert';

import 'package:network_sdk/network_sdk.dart';

import 'lan_peer_trust.dart';

const Object _lanPeerUnset = Object();

/// Device type enumeration.
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

/// A point-in-time observation received from LAN discovery.
///
/// This type deliberately contains only dynamic discovery data.  In
/// particular, it has no certificate, access token, public-key, or `trusted`
/// field.  Those values belong to [LanPeerTrustRecord] and are never inferred
/// from mDNS/UDP advertisements.
final class LanDiscoveredPeer {
  const LanDiscoveredPeer({
    required this.deviceId,
    required this.alias,
    required this.ip,
    required this.controlPort,
    this.advertisedNativePort,
    required this.os,
    this.deviceType = LanDeviceType.desktop,
    required this.lastSeen,
  });

  final String deviceId;
  final String alias;
  final String ip;
  final int controlPort;
  final int? advertisedNativePort;
  final LanDeviceType deviceType;
  final String os;
  final DateTime lastSeen;

  LanDiscoveredPeer copyWith({
    String? deviceId,
    String? alias,
    String? ip,
    int? controlPort,
    Object? advertisedNativePort = _lanPeerUnset,
    LanDeviceType? deviceType,
    String? os,
    DateTime? lastSeen,
  }) {
    return LanDiscoveredPeer(
      deviceId: deviceId ?? this.deviceId,
      alias: alias ?? this.alias,
      ip: ip ?? this.ip,
      controlPort: controlPort ?? this.controlPort,
      advertisedNativePort: identical(advertisedNativePort, _lanPeerUnset)
          ? this.advertisedNativePort
          : advertisedNativePort as int?,
      deviceType: deviceType ?? this.deviceType,
      os: os ?? this.os,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'deviceId': deviceId,
    'alias': alias,
    'ip': ip,
    'controlPort': controlPort,
    if (advertisedNativePort != null)
      'advertisedNativePort': advertisedNativePort,
    'deviceType': deviceType.toJson(),
    'os': os,
    'lastSeen': lastSeen.toIso8601String(),
  };

  factory LanDiscoveredPeer.fromJson(Map<String, dynamic> json) {
    final deviceId = json['deviceId'];
    final alias = json['alias'];
    final ip = json['ip'];
    final controlPort = json['controlPort'];
    final os = json['os'];
    final deviceType = json['deviceType'];
    final lastSeen = json['lastSeen'];
    if (deviceId is! String || deviceId.trim().isEmpty) {
      throw const FormatException('Missing V2 LAN peer deviceId.');
    }
    if (alias is! String || ip is! String || os is! String) {
      throw const FormatException('Invalid V2 LAN peer discovery fields.');
    }
    if (controlPort is! num ||
        controlPort.toInt() < 1 ||
        controlPort.toInt() > 65535) {
      throw const FormatException('Invalid V2 LAN peer controlPort.');
    }
    if (deviceType is! String ||
        !LanDeviceType.values.any((value) => value.name == deviceType)) {
      throw const FormatException('Invalid V2 LAN peer deviceType.');
    }
    if (lastSeen is! String) {
      throw const FormatException('Missing V2 LAN peer lastSeen.');
    }
    final parsedLastSeen = DateTime.tryParse(lastSeen);
    if (parsedLastSeen == null) {
      throw const FormatException('Invalid V2 LAN peer lastSeen.');
    }
    return LanDiscoveredPeer(
      deviceId: deviceId,
      alias: alias,
      ip: ip,
      controlPort: controlPort.toInt(),
      advertisedNativePort: (json['advertisedNativePort'] as num?)?.toInt(),
      deviceType: LanDeviceType.fromJson(deviceType),
      os: os,
      lastSeen: parsedLastSeen,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LanDiscoveredPeer &&
      other.deviceId == deviceId &&
      other.alias == alias &&
      other.ip == ip &&
      other.controlPort == controlPort &&
      other.advertisedNativePort == advertisedNativePort &&
      other.deviceType == deviceType &&
      other.os == os &&
      other.lastSeen == lastSeen;

  @override
  int get hashCode => Object.hash(
    deviceId,
    alias,
    ip,
    controlPort,
    advertisedNativePort,
    deviceType,
    os,
    lastSeen,
  );
}

/// Reachability is an observation and is independent from trust.
enum LanPeerReachability { unknown, online, offline }

/// Route availability presented by the network layer for one peer.
///
/// This is intentionally separate from [LanPeerTrustRecord.authorization]:
/// authorization says what is allowed, while this type says what is currently
/// available.  A route can be unavailable while its authorization remains
/// persisted, for example when a peer leaves the LAN or the Relay disconnects.
final class LanPeerRouteState {
  const LanPeerRouteState({
    this.directAvailable = false,
    this.relayAvailable = false,
    this.activeRoute,
    this.endpoint,
    this.updatedAt,
  });

  final bool directAvailable;
  final bool relayAvailable;
  final NetworkRouteType? activeRoute;
  final String? endpoint;
  final DateTime? updatedAt;

  bool get isAvailable => directAvailable || relayAvailable;

  /// Presentation aliases make the authorization/availability distinction
  /// explicit at call sites while keeping the model compact.
  bool get localDirectAvailable => directAvailable;
  bool get relayRouteAvailable => relayAvailable;

  LanPeerRouteState copyWith({
    bool? directAvailable,
    bool? relayAvailable,
    Object? activeRoute = _lanPeerUnset,
    Object? endpoint = _lanPeerUnset,
    Object? updatedAt = _lanPeerUnset,
  }) => LanPeerRouteState(
    directAvailable: directAvailable ?? this.directAvailable,
    relayAvailable: relayAvailable ?? this.relayAvailable,
    activeRoute: identical(activeRoute, _lanPeerUnset)
        ? this.activeRoute
        : activeRoute as NetworkRouteType?,
    endpoint: identical(endpoint, _lanPeerUnset)
        ? this.endpoint
        : endpoint as String?,
    updatedAt: identical(updatedAt, _lanPeerUnset)
        ? this.updatedAt
        : updatedAt as DateTime?,
  );
}

/// Presentation projection of the independent LAN peer state domains.
///
/// `trust != null && discovery == null` is a valid, first-class trusted
/// offline state.  Discovery records may disappear without deleting trust;
/// route availability can also disappear without changing either one.
final class LanPeerViewState {
  LanPeerViewState({
    String? peerId,
    this.trust,
    this.discovery,
    LanPeerReachability? reachability,
    this.route = const LanPeerRouteState(),
  }) : peerId = peerId ?? trust?.deviceId ?? discovery?.deviceId ?? '',
       reachability =
           reachability ??
           (discovery != null
               ? LanPeerReachability.online
               : trust != null
               ? LanPeerReachability.offline
               : LanPeerReachability.unknown);

  final String peerId;
  final LanPeerTrustRecord? trust;
  final LanDiscoveredPeer? discovery;
  final LanPeerReachability reachability;
  final LanPeerRouteState route;

  String get deviceId => peerId;
  bool get isTrusted => trust != null;
  bool get isDiscovered => discovery != null;
  bool get isOnline => reachability == LanPeerReachability.online;
  bool get isOffline => reachability == LanPeerReachability.offline;
  bool get isTrustedOffline => isTrusted && !isDiscovered;
  bool get canUseRoute => route.isAvailable;

  String get displayAlias => discovery?.alias ?? peerId;
  String? get ip => discovery?.ip;
  int? get controlPort => discovery?.controlPort;
  int? get advertisedNativePort => discovery?.advertisedNativePort;

  LanPeerViewState copyWith({
    Object? peerId = _lanPeerUnset,
    Object? trust = _lanPeerUnset,
    Object? discovery = _lanPeerUnset,
    LanPeerReachability? reachability,
    LanPeerRouteState? route,
  }) => LanPeerViewState(
    peerId: identical(peerId, _lanPeerUnset) ? this.peerId : peerId as String?,
    trust: identical(trust, _lanPeerUnset)
        ? this.trust
        : trust as LanPeerTrustRecord?,
    discovery: identical(discovery, _lanPeerUnset)
        ? this.discovery
        : discovery as LanDiscoveredPeer?,
    reachability: reachability ?? this.reachability,
    route: route ?? this.route,
  );
}

/// A short-lived navigation and protocol request for pairing two LAN devices.
class LanPairingRequest {
  final LanPeerViewState peer;
  final String sessionId;
  final bool isIncoming;
  final DateTime expiresAt;

  const LanPairingRequest({
    required this.peer,
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

/// Classifies an attachment into a stable [LanPayloadType] (image, video, audio, or file).
LanPayloadType classifyAttachment({
  required String fileName,
  String? mimeType,
}) {
  if (mimeType != null && mimeType.isNotEmpty) {
    final lower = mimeType.toLowerCase();
    if (lower.startsWith('image/')) return LanPayloadType.image;
    if (lower.startsWith('video/')) return LanPayloadType.video;
    if (lower.startsWith('audio/')) return LanPayloadType.audio;
  }
  final dotIndex = fileName.lastIndexOf('.');
  if (dotIndex == -1 || dotIndex == fileName.length - 1) {
    return LanPayloadType.file;
  }
  final ext = fileName.substring(dotIndex + 1).toLowerCase();
  const imageExts = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
    'svg',
    'ico',
  };
  const videoExts = {
    'mp4',
    'mkv',
    'avi',
    'mov',
    'wmv',
    'flv',
    'webm',
    'm4v',
    '3gp',
  };
  const audioExts = {'mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a', 'wma', 'opus'};

  if (imageExts.contains(ext)) return LanPayloadType.image;
  if (videoExts.contains(ext)) return LanPayloadType.video;
  if (audioExts.contains(ext)) return LanPayloadType.audio;
  return LanPayloadType.file;
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
