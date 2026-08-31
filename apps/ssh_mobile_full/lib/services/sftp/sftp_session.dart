part of 'sftp_service_io.dart';

/// Owns one connection's SSH/SFTP handles and browse state.
///
/// The service keeps the session in its connection registry. Closing a
/// session is idempotent from the owner's perspective and marks it stale so
/// late connection callbacks cannot publish handles back into the registry.
class _SftpSession {
  final String connectionId;
  final String connectionName;
  final ConnectionTargetBinding? targetBinding;
  SSHClient? client;
  SftpClient? sftp;
  String currentPath;
  SftpConnectionState state = SftpConnectionState.disconnected;
  String? errorMessage;
  List<SftpEntry> entries = const [];
  int entriesRevision = 0;
  bool _closed = false;

  _SftpSession({
    required this.connectionId,
    required this.connectionName,
    required this.currentPath,
    this.targetBinding,
  });

  String get targetFingerprint {
    final binding = targetBinding;
    if (binding == null) {
      throw StateError('SFTP session has no bound remote target');
    }
    return binding.fingerprint;
  }

  void close() {
    _closed = true;
    sftp?.close();
    client?.close();
  }

  bool isCurrent(Map<String, _SftpSession> sessions) {
    return !_closed && identical(sessions[connectionId], this);
  }
}
