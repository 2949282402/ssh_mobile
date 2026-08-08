// App Shell 旧路径的兼容实现。
//
// AI 工具的新实现位于 feature_ai；SSH、SFTP 和服务目录等尚未迁移的
// App Service 仍依赖旧 StorageService 类型，因此这里保留其原有边界，
// 避免把 App 实现反向引入 Feature Package。
import 'dart:async';

import 'connection_target_binding.dart';
import 'storage_service.dart';

/// 远程执行目标范围校验失败时返回的结构化异常。
class RemoteTargetScopeException implements Exception {
  final String code;
  final String connectionId;
  final String message;

  const RemoteTargetScopeException._({
    required this.code,
    required this.connectionId,
    required this.message,
  });

  factory RemoteTargetScopeException.notBound(String connectionId) {
    return RemoteTargetScopeException._(
      code: 'connection_not_bound',
      connectionId: connectionId,
      message: 'Connection is not bound to this remote execution scope.',
    );
  }

  factory RemoteTargetScopeException.notFound(String connectionId) {
    return RemoteTargetScopeException._(
      code: 'connection_not_found',
      connectionId: connectionId,
      message: 'Connection config not found',
    );
  }

  factory RemoteTargetScopeException.targetChanged(String connectionId) {
    return RemoteTargetScopeException._(
      code: 'approval_target_changed',
      connectionId: connectionId,
      message:
          'The saved connection target changed after it was selected. '
          'Review the updated target before retrying.',
    );
  }

  @override
  String toString() => '$code: $message (connectionId=$connectionId)';
}

/// 携带一次远程执行所授权的不可变连接集合。
class RemoteTargetScope {
  static final Object _bindingsZoneKey = Object();

  const RemoteTargetScope._();

  static Map<String, ConnectionTargetBinding>? get currentBindings {
    return Zone.current[_bindingsZoneKey]
        as Map<String, ConnectionTargetBinding>?;
  }

  static R run<R>(
    Map<String, ConnectionTargetBinding> bindings,
    R Function() callback,
  ) {
    final snapshot = <String, ConnectionTargetBinding>{};
    for (final entry in bindings.entries) {
      if (entry.key != entry.value.id) {
        throw ArgumentError.value(
          entry.key,
          'bindings',
          'Binding map keys must match binding ids.',
        );
      }
      snapshot[entry.key] = entry.value;
    }
    return runZoned(
      callback,
      zoneValues: {
        _bindingsZoneKey: Map<String, ConnectionTargetBinding>.unmodifiable(
          snapshot,
        ),
      },
    );
  }

  /// 在网络边界解析当前保存的目标与凭据，并拒绝越权或过期绑定。
  static Future<ConnectionRuntimeTarget> resolveIfBound(
    StorageService storage,
    String connectionId,
  ) async {
    final normalizedId = connectionId.trim();
    final scopedBindings = currentBindings;
    final binding = scopedBindings == null
        ? storage.captureConnectionTargetBindings([normalizedId])[normalizedId]
        : scopedBindings[normalizedId];

    if (binding == null) {
      if (scopedBindings != null) {
        throw RemoteTargetScopeException.notBound(normalizedId);
      }
      throw RemoteTargetScopeException.notFound(normalizedId);
    }

    final target = await storage.resolveConnectionTarget(binding);
    if (target != null) return target;

    if (storage.getConnection(normalizedId) == null) {
      throw RemoteTargetScopeException.notFound(normalizedId);
    }
    throw RemoteTargetScopeException.targetChanged(normalizedId);
  }
}
