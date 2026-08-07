part of 'sftp_screen.dart';

class _SftpConnectionStatusSnapshot {
  final bool selected;
  final bool busy;
  final bool connected;

  const _SftpConnectionStatusSnapshot({
    required this.selected,
    required this.busy,
    required this.connected,
  });

  factory _SftpConnectionStatusSnapshot.from(
    SftpViewModel service,
    String? connectionId,
  ) {
    if (connectionId == null || connectionId.isEmpty) {
      return const _SftpConnectionStatusSnapshot(
        selected: false,
        busy: false,
        connected: false,
      );
    }
    return _SftpConnectionStatusSnapshot(
      selected: service.connectionId == connectionId,
      busy: service.isConnectionBusy(connectionId),
      connected: service.isConnectionOpen(connectionId),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _SftpConnectionStatusSnapshot &&
        other.selected == selected &&
        other.busy == busy &&
        other.connected == connected;
  }

  @override
  int get hashCode => Object.hash(selected, busy, connected);
}

class _SftpPaneStatusSnapshot {
  final String? connectionId;
  final String currentPath;
  final SftpConnectionState state;
  final String? errorMessage;
  final SftpTransferState? activeTransfer;

  const _SftpPaneStatusSnapshot({
    required this.connectionId,
    required this.currentPath,
    required this.state,
    required this.errorMessage,
    required this.activeTransfer,
  });

  factory _SftpPaneStatusSnapshot.from(SftpViewModel service) {
    return _SftpPaneStatusSnapshot(
      connectionId: service.connectionId,
      currentPath: service.currentPath,
      state: service.state,
      errorMessage: service.errorMessage,
      activeTransfer: service.activeTransfer,
    );
  }

  bool get isBusy =>
      state == SftpConnectionState.connecting ||
      state == SftpConnectionState.loading;

  @override
  bool operator ==(Object other) {
    return other is _SftpPaneStatusSnapshot &&
        other.connectionId == connectionId &&
        other.currentPath == currentPath &&
        other.state == state &&
        other.errorMessage == errorMessage &&
        other.activeTransfer == activeTransfer;
  }

  @override
  int get hashCode => Object.hash(
    connectionId,
    currentPath,
    state,
    errorMessage,
    activeTransfer,
  );
}

class _SftpEntriesSnapshot {
  final String? connectionId;
  final int entriesRevision;
  final List<SftpEntry> entries;

  const _SftpEntriesSnapshot({
    required this.connectionId,
    required this.entriesRevision,
    required this.entries,
  });

  factory _SftpEntriesSnapshot.from(SftpViewModel service) {
    return _SftpEntriesSnapshot(
      connectionId: service.connectionId,
      entriesRevision: service.entriesRevision,
      entries: service.entries,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _SftpEntriesSnapshot &&
        other.connectionId == connectionId &&
        other.entriesRevision == entriesRevision;
  }

  @override
  int get hashCode => Object.hash(connectionId, entriesRevision);
}
