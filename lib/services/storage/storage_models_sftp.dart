part of '../storage_service.dart';

class SftpRecentPathRecord {
  final String id;
  final String connectionId;
  final String path;
  final DateTime visitedAt;

  const SftpRecentPathRecord({
    required this.id,
    required this.connectionId,
    required this.path,
    required this.visitedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'connectionId': connectionId,
      'path': path,
      'visitedAt': visitedAt.toIso8601String(),
    };
  }

  factory SftpRecentPathRecord.fromJson(Map<String, dynamic> json) {
    return SftpRecentPathRecord(
      id: json['id'] as String? ?? _traceUuid.v4(),
      connectionId: json['connectionId'] as String? ?? '',
      path: json['path'] as String? ?? '.',
      visitedAt: DateTime.tryParse(json['visitedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class SftpFavoritePathRecord {
  final String id;
  final String connectionId;
  final String path;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  const SftpFavoritePathRecord({
    required this.id,
    required this.connectionId,
    required this.path,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  SftpFavoritePathRecord copyWith({
    String? name,
    DateTime? updatedAt,
  }) {
    return SftpFavoritePathRecord(
      id: id,
      connectionId: connectionId,
      path: path,
      name: name ?? this.name,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'connectionId': connectionId,
      'path': path,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory SftpFavoritePathRecord.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    return SftpFavoritePathRecord(
      id: json['id'] as String? ?? _traceUuid.v4(),
      connectionId: json['connectionId'] as String? ?? '',
      path: json['path'] as String? ?? '.',
      name: json['name'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? now,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? now,
    );
  }
}
