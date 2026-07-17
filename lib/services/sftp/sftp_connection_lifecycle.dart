part of 'sftp_service_io.dart';

extension _SftpConnectionLifecycle on SftpService {
  Future<void> _connect(
    _SftpSession session,
    ConnectionRuntimeTarget target, {
    dynamic onUnknownHostKey,
  }) async {
    final config = target.config;
    final credentials = SshCredentials(
      password: target.password,
      privateKey: target.privateKey,
    );
    try {
      final client = await _clientFactory.connectClient(
        config,
        credentials: credentials,
        onUnknownHostKey: onUnknownHostKey,
      );
      if (!session.isCurrent(_sessions)) {
        client.close();
        return;
      }
      session.client = client;
      final sftp = await client.sftp().timeout(const Duration(seconds: 15));
      if (!session.isCurrent(_sessions)) {
        sftp.close();
        client.close();
        return;
      }
      session.sftp = sftp;
      session.state = SftpConnectionState.connected;
      AppLogService.instance.info(
        'SFTP connected',
        details: 'connection=${config.name} host=${config.host}:${config.port}',
      );
      notify();
      await _openLastKnownPath(session);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'SFTP connect failed',
        error: e,
        stackTrace: stackTrace,
        details: 'connection=${config.name}',
      );
      session.close();
      session.client = null;
      session.sftp = null;
      session.state = SftpConnectionState.error;
      session.errorMessage = 'SFTP connection failed: $e';
      notify();
    }
  }
}
