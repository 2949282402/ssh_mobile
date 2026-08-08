import 'dart:async';

import 'package:feature_ai/src/domain/ai_compat.dart';

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

/// Carries the immutable connection set authorized for one remote execution.
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

  /// Resolves the current saved target and credentials at the networking edge.
  ///
  /// Outside a scope this captures the current saved target for ordinary UI
  /// operations. Inside a scope, connection ids absent from the authorized map
  /// fail closed and stale bindings cannot silently route to an edited server.
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
