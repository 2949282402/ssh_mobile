part of 'native_realtime_protocol.dart';

/// Correlates registered commands with exactly one terminal result.
///
/// A native worker may retry or duplicate an event at a transport boundary,
/// but a public command must complete at most once. Call [register] before
/// submitting a command, pass every decoded event through [filterEvent], and
/// call [cancel] when queue acceptance fails or the owner cancels the command.
/// Unknown and duplicate command results are dropped. Pending registrations
/// are bounded so a missing result cannot grow this guard without limit.
final class NativeCommandResultGuard {
  /// Creates a guard with a bounded number of in-flight command IDs.
  NativeCommandResultGuard({
    this.maxPendingCommands = _maxPendingCommandResults,
  }) : assert(maxPendingCommands > 0) {
    if (maxPendingCommands <= 0) {
      throw ArgumentError.value(
        maxPendingCommands,
        'maxPendingCommands',
        'Must be positive.',
      );
    }
  }

  /// Maximum number of commands that may await a terminal result.
  final int maxPendingCommands;
  final Set<String> _pendingCommandIds = <String>{};

  /// Number of commands still waiting for a terminal result.
  int get pendingCount => _pendingCommandIds.length;

  /// Registers [commandId] before queue submission.
  ///
  /// Returns `false` for a duplicate ID or when the bounded pending budget is
  /// exhausted. The caller must not submit a command when registration fails.
  bool register(String commandId) {
    if (commandId.isEmpty ||
        utf8.encode(commandId).length > _maxCommandIdBytes) {
      throw ArgumentError.value(
        commandId,
        'commandId',
        'Must contain 1-$_maxCommandIdBytes bytes.',
      );
    }
    if (_pendingCommandIds.contains(commandId) ||
        _pendingCommandIds.length >= maxPendingCommands) {
      return false;
    }
    _pendingCommandIds.add(commandId);
    return true;
  }

  /// Cancels a command that will not produce a terminal result.
  void cancel(String commandId) => _pendingCommandIds.remove(commandId);

  /// Keeps non-result events and admits only the first result for a registered
  /// command. Returns `null` for unknown or duplicate command results.
  NativeNetworkEvent? filterEvent(NativeNetworkEvent event) {
    final commandId = switch (event) {
      NativeCommandResultEvent() => event.commandId,
      NativeCommandResultV2Event() => event.commandId,
      _ => null,
    };
    if (commandId == null) return event;
    if (!_pendingCommandIds.remove(commandId)) return null;
    return event;
  }

  /// Drops all pending registrations during owner shutdown.
  void clear() => _pendingCommandIds.clear();
}
