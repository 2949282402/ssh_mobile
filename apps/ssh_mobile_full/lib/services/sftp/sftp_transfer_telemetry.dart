part of 'sftp_service_io.dart';

/// Records transfer lifecycle spans without coupling SFTP success/failure to
/// the telemetry storage boundary.
extension SftpServiceTransferTelemetry on SftpService {
  void _startTransferTelemetry(String transferId, SftpTransferState transfer) {
    final client = telemetryClient;
    if (client == null) return;
    final traceId = _telemetryTransferTraceIds[transferId] ??=
        newTelemetryTraceId();
    _telemetryTransferStartedAt[transferId] = DateTime.now();
    unawaited(
      client.record(
        event: TelemetryEvents.sftpTransferStarted,
        traceId: traceId,
        properties: {
          'direction': transfer.isUpload ? 'upload' : 'download',
          'file_size_bytes': transfer.totalBytes,
        },
      ),
    );
  }

  void _completeTransferTelemetry(
    String transferId,
    SftpTransferState transfer,
  ) {
    final client = telemetryClient;
    if (client == null) return;
    final traceId = _telemetryTransferTraceIds.remove(transferId);
    final startedAt = _telemetryTransferStartedAt.remove(transferId);
    unawaited(
      client.record(
        event: TelemetryEvents.sftpTransferCompleted,
        traceId: traceId,
        properties: {
          'direction': transfer.isUpload ? 'upload' : 'download',
          'bytes_transferred': transfer.bytesTransferred,
          'duration_ms': telemetryElapsedMs(startedAt),
        },
      ),
    );
  }

  Future<void> _failTransferTelemetry(
    String transferId,
    SftpTransferState transfer, {
    required TelemetryErrorCodeDefinition errorCode,
    required String stage,
    String? errorMessage,
  }) async {
    final client = telemetryClient;
    if (client == null) return;
    final traceId = _telemetryTransferTraceIds.remove(transferId);
    _telemetryTransferStartedAt.remove(transferId);
    try {
      // The business failure owns timely error propagation and cleanup. The
      // client still durably queues healthy writes, while a blocked storage
      // boundary is allowed to drain independently after this bounded wait.
      await client
          .record(
            event: TelemetryEvents.sftpTransferFailed,
            traceId: traceId,
            errorCode: errorCode,
            errorMessage: errorMessage,
            properties: {
              'direction': transfer.isUpload ? 'upload' : 'download',
              'bytes_transferred': transfer.bytesTransferred,
              'stage': stage,
            },
          )
          .timeout(_telemetryFailureTimeout);
    } on Object {
      // Telemetry storage failure must not replace the original SFTP error.
    }
  }

  /// Maps transfer failures to the registered, stable SFTP error codes.
  TelemetryErrorCodeDefinition _mapSftpErrorCode(
    Object error, {
    required bool isUpload,
  }) {
    final message = error.toString().toLowerCase();
    if (message.contains('permission') ||
        message.contains('denied') ||
        message.contains('access')) {
      return TelemetryErrorCodes.sftpPermissionDenied;
    }
    if (message.contains('not found') ||
        message.contains('no such file') ||
        message.contains('exists')) {
      return TelemetryErrorCodes.sftpFileNotFound;
    }
    if (message.contains('quota') ||
        message.contains('no space') ||
        message.contains('full')) {
      return TelemetryErrorCodes.sftpQuotaExceeded;
    }
    if (message.contains('cancel') || message.contains('abort')) {
      return TelemetryErrorCodes.sftpTransferAborted;
    }
    return TelemetryErrorCodes.sftpOperationFailed;
  }
}
