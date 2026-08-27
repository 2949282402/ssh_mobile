import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:app_core/app_core.dart';
import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../app_log_service.dart';
import '../../core/services/ssh_client_factory.dart';
import '../../core/services/data_protection_service.dart';
import '../connection_target_binding.dart';
import '../remote_target_scope.dart';
import '../sftp_path_history_store.dart';
import '../telemetry/app_telemetry_contract.dart';
import '../telemetry/telemetry_span.dart';
import '../tool_secret_policy.dart';
import '../sftp_service.dart';
import 'sftp_entry_parser.dart';
import 'sftp_log_safety.dart';

part 'sftp_cache.dart';
part 'sftp_operations.dart';
part 'sftp_connection_lifecycle.dart';
part 'sftp_directory_navigation.dart';

/// SFTP 文件操作服务。
///
/// 职责：目录列表、文件上传/下载/读取/保存/删除。
/// 文件大小上限：文本编辑 512KB / 文本预览 2MB / 富预览 20MB / 上传 50MB / 下载 512MB。
/// 多级缓存：SFTP 连接按 connectionId + host 缓存复用。
/// 通知合并：调用 notifyListeners() 有 16ms 延迟合并窗口，防止高频操作导致 UI 卡顿。
class SftpService extends ChangeNotifier implements SftpClientAdapter {
  static const int maxTextEditBytes = 512 * 1024;
  static const int maxTextPreviewBytes = 2 * 1024 * 1024;
  static const int maxRichPreviewBytes = 20 * 1024 * 1024;
  static const int maxUploadBytes = 50 * 1024 * 1024;
  static const int maxDownloadBytes = 512 * 1024 * 1024;
  static const int maxInMemoryTransferBytes = maxDownloadBytes;
  static const Duration _notifyCoalesceDelay = Duration(milliseconds: 16);

  final ConnectionRepository _connectionRepository;
  final CredentialRepository _credentialRepository;
  final HostKeyRepository _hostKeyRepository;
  final SftpPathHistoryStore _pathHistoryStore;
  final ssh_core.SshNativeStreamConnector? _nativeStreamConnector;
  final ssh_core.SshPeerIdResolver? _peerIdResolver;
  late final SshClientFactory _clientFactory = SshClientFactory(
    credentialRepository: _credentialRepository,
    hostKeyRepository: _hostKeyRepository,
    logger: AppLogService.instance,
    nativeStreamConnector: _nativeStreamConnector,
    peerIdResolver: _peerIdResolver,
  );

  final Map<String, _SftpSession> _sessions = {};
  final Map<String, String> _lastPaths = {};
  final Map<String, Future<void>> _connectTasks = {};
  final SftpDirectoryCache _directoryCache = SftpDirectoryCache();
  Timer? _notifyTimer;
  String? _activeConnectionId;
  bool _disposed = false;
  SftpTransferState? _activeTransfer;
  String? _cancelTransferId;

  /// 可选遥测客户端；由 Composition Root 在 SFTP 服务创建后注入。
  ///
  /// transfer span 共享同一个 traceId（started -> completed/failed），便于
  /// 端到端关联。本地路径、远程路径不写入事件属性，避免泄露服务器布局。
  TelemetryClient? telemetryClient;

  // 传输 span：键为 transferId，沿用 UUID traceId；跨 completed/failed
  // 端点保持会话内关联。
  final Map<String, String> _telemetryTransferTraceIds = {};
  final Map<String, DateTime> _telemetryTransferStartedAt = {};

  @override
  SftpTransferState? get activeTransfer => _activeTransfer;
  @override
  bool get hasActiveTransfer => _activeTransfer != null;

  SftpService({
    required this._connectionRepository,
    required this._credentialRepository,
    required this._hostKeyRepository,
    SftpPathHistoryStore? pathHistoryStore,
    this._nativeStreamConnector,
    this._peerIdResolver,
    this.telemetryClient,
  }) : _pathHistoryStore = pathHistoryStore ?? InMemorySftpPathHistoryStore();

  @visibleForTesting
  SftpService.forTesting(
    this._connectionRepository,
    this._credentialRepository,
    this._hostKeyRepository, {
    required ConnectionConfig connection,
    required SftpClient sftpClient,
    String currentPath = '.',
    SftpPathHistoryStore? pathHistoryStore,
    this._nativeStreamConnector,
    this._peerIdResolver,
  }) : _pathHistoryStore = pathHistoryStore ?? InMemorySftpPathHistoryStore() {
    final session =
        _SftpSession(
            connectionId: connection.id,
            connectionName: connection.name,
            currentPath: currentPath,
            targetBinding: ConnectionTargetBinding.fromConfig(connection),
          )
          ..sftp = sftpClient
          ..state = SftpConnectionState.connected;
    _sessions[connection.id] = session;
    _activeConnectionId = connection.id;
  }

  static String _decodeUtf8(Uint8List bytes) {
    return utf8.decode(bytes, allowMalformed: true);
  }

  _SftpSession? get _activeSession =>
      _activeConnectionId == null ? null : _sessions[_activeConnectionId];

  @override
  String? get connectionId => _activeSession?.connectionId;
  @override
  String? get connectionName => _activeSession?.connectionName;
  @override
  String get currentPath => _activeSession?.currentPath ?? '.';
  @override
  SftpConnectionState get state =>
      _activeSession?.state ?? SftpConnectionState.disconnected;
  @override
  String? get errorMessage => _activeSession?.errorMessage;
  @override
  int get entriesRevision => _activeSession?.entriesRevision ?? 0;
  @override
  List<SftpEntry> get entries => _activeSession?.entries ?? const [];
  @override
  bool get isConnected => _activeSession?.sftp != null;
  SftpClient? getSftpClientForConnection(String id) => _sessions[id]?.sftp;
  @override
  bool get isBusy =>
      state == SftpConnectionState.connecting ||
      state == SftpConnectionState.loading;

  @override
  bool isConnectionBusy(String connectionId) {
    final session = _sessions[connectionId];
    return session?.state == SftpConnectionState.connecting ||
        session?.state == SftpConnectionState.loading;
  }

  @override
  bool isConnectionOpen(String connectionId) {
    return _sessions[connectionId]?.sftp != null;
  }

  Future<List<SftpRecentPathRecord>> loadRecentPaths(
    String connectionId, {
    int limit = 30,
  }) {
    return _pathHistoryStore.loadRecentPaths(connectionId, limit: limit);
  }

  Future<List<SftpFavoritePathRecord>> loadFavoritePaths(String connectionId) {
    return _pathHistoryStore.loadFavoritePaths(connectionId);
  }

  Future<SftpFavoritePathRecord?> findFavoritePath(
    String connectionId,
    String path,
  ) {
    return _pathHistoryStore.findFavoritePath(connectionId, path);
  }

  Future<SftpFavoritePathRecord> addFavoritePath(
    String connectionId,
    String path,
    String name,
  ) {
    return _pathHistoryStore.addFavoritePath(connectionId, path, name);
  }

  Future<void> removeFavoritePath(String id) {
    return _pathHistoryStore.removeFavoritePath(id);
  }

  @override
  Future<void> connect(String connectionId, {dynamic onUnknownHostKey}) async {
    ConnectionRuntimeTarget runtimeTarget;
    try {
      runtimeTarget = await RemoteTargetScope.resolveIfBound(
        connectionRepository: _connectionRepository,
        credentialRepository: _credentialRepository,
        connectionId: connectionId,
      );
    } on RemoteTargetScopeException catch (e) {
      _activeConnectionId = connectionId;
      final session = _sessions.putIfAbsent(
        connectionId,
        () => _SftpSession(
          connectionId: connectionId,
          connectionName: connectionId,
          currentPath: _lastPaths[connectionId] ?? '.',
        ),
      );
      session.state = SftpConnectionState.error;
      session.errorMessage = e.message;
      notifyListeners();
      return;
    }
    final config = runtimeTarget.config;

    var existing = _sessions[connectionId];
    if (existing != null &&
        existing.targetBinding?.fingerprint !=
            runtimeTarget.binding.fingerprint) {
      existing.close();
      _sessions.remove(connectionId);
      existing = null;
    }
    if (existing?.sftp != null) {
      _activeConnectionId = connectionId;
      notifyListeners();
      return;
    }
    if (existing?.state == SftpConnectionState.connecting) {
      _activeConnectionId = connectionId;
      notifyListeners();
      final task = _connectTasks[connectionId];
      if (task != null) await task;
      return;
    }

    final session = _SftpSession(
      connectionId: connectionId,
      connectionName: config.name,
      currentPath: _lastPaths[connectionId] ?? '.',
      targetBinding: runtimeTarget.binding,
    );
    _sessions[connectionId] = session;
    _activeConnectionId = connectionId;
    session.state = SftpConnectionState.connecting;
    session.errorMessage = null;
    notifyListeners();
    final task = _connect(
      session,
      runtimeTarget,
      onUnknownHostKey: onUnknownHostKey,
    );
    _connectTasks[connectionId] = task;
    try {
      await task;
    } finally {
      if (identical(_connectTasks[connectionId], task)) {
        _connectTasks.remove(connectionId);
      }
    }
  }

  @override
  Future<void> refresh() async {
    final session = _activeSession;
    if (session == null) return;
    await _openPath(session, session.currentPath, bypassCache: true);
  }

  @override
  void cancelActiveTransfer() {
    final transfer = _activeTransfer;
    if (transfer != null) {
      _cancelTransferId = transfer.id;
      _activeTransfer = transfer.copyWith(isCancelled: true);
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // 业务遥测：SFTP 传输生命周期 span。
  // ---------------------------------------------------------------------------

  void _startTransferTelemetry(String transferId, SftpTransferState transfer) {
    final client = telemetryClient;
    if (client == null) return;
    final traceId = _telemetryTransferTraceIds[transferId] ??=
        newTelemetryTraceId();
    _telemetryTransferStartedAt[transferId] = DateTime.now();
    unawaited(
      client.recordEvent(
        eventName: AppTelemetryEvents.sftpTransferStarted.name,
        eventVersion: AppTelemetryEvents.sftpTransferStarted.version,
        feature: AppTelemetryEvents.sftpTransferStarted.feature,
        severity: AppTelemetryEvents.sftpTransferStarted.severity,
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
      client.recordEvent(
        eventName: AppTelemetryEvents.sftpTransferCompleted.name,
        eventVersion: AppTelemetryEvents.sftpTransferCompleted.version,
        feature: AppTelemetryEvents.sftpTransferCompleted.feature,
        severity: AppTelemetryEvents.sftpTransferCompleted.severity,
        traceId: traceId,
        properties: {
          'direction': transfer.isUpload ? 'upload' : 'download',
          'bytes_transferred': transfer.bytesTransferred,
          'duration_ms': telemetryElapsedMs(startedAt),
        },
      ),
    );
  }

  void _failTransferTelemetry(
    String transferId,
    SftpTransferState transfer, {
    required String errorCode,
    required String stage,
    String? errorMessage,
  }) {
    final client = telemetryClient;
    if (client == null) return;
    final traceId = _telemetryTransferTraceIds.remove(transferId);
    _telemetryTransferStartedAt.remove(transferId);
    unawaited(
      client.recordEvent(
        eventName: AppTelemetryEvents.sftpTransferFailed.name,
        eventVersion: AppTelemetryEvents.sftpTransferFailed.version,
        feature: AppTelemetryEvents.sftpTransferFailed.feature,
        severity: AppTelemetryEvents.sftpTransferFailed.severity,
        traceId: traceId,
        errorCode: errorCode,
        errorMessage: errorMessage,
        properties: {
          'direction': transfer.isUpload ? 'upload' : 'download',
          'bytes_transferred': transfer.bytesTransferred,
          'stage': stage,
        },
      ),
    );
  }

  /// 将传输异常映射到 contract 已注册的 SFTP 错误码。
  static String _mapSftpErrorCode(Object error, {required bool isUpload}) {
    final message = error.toString().toLowerCase();
    if (message.contains('permission') ||
        message.contains('denied') ||
        message.contains('access')) {
      return AppTelemetryErrorCodes.sftpPermissionDenied.code;
    }
    if (message.contains('not found') ||
        message.contains('no such file') ||
        message.contains('exists')) {
      return AppTelemetryErrorCodes.sftpFileNotFound.code;
    }
    if (message.contains('quota') ||
        message.contains('no space') ||
        message.contains('full')) {
      // contract 没有 sftpQuotaExceeded 码，映射到最接近的权限类终止错误，
      // 让失败事件能通过 catalog 校验并在后端按 category 归类。
      return AppTelemetryErrorCodes.sftpPermissionDenied.code;
    }
    if (message.contains('cancel') || message.contains('abort')) {
      return AppTelemetryErrorCodes.sftpTransferAborted.code;
    }
    return AppTelemetryErrorCodes.sftpTransferAborted.code;
  }

  @override
  Future<void> uploadFile({
    required String localPath,
    required String filename,
  }) async {
    final session = _activeSession;
    final sftp = session?.sftp;
    if (sftp == null) throw StateError('SFTP is not connected');
    final activeSession = session!;

    final localFile = File(localPath);
    if (!await localFile.exists()) {
      throw FileSystemException('Local file not found', localPath);
    }
    final totalSize = await localFile.length();
    _assertWithinMemoryLimit(totalSize, 'upload', maxBytes: maxUploadBytes);

    final remotePath = _joinRemotePath(activeSession.currentPath, filename);

    final transferId = DateTime.now().millisecondsSinceEpoch.toString();
    final transfer = SftpTransferState(
      id: transferId,
      name: filename,
      totalBytes: totalSize,
      isUpload: true,
    );
    _activeTransfer = transfer;
    _cancelTransferId = null;
    activeSession.state = SftpConnectionState.loading;
    notifyListeners();
    _startTransferTelemetry(transferId, transfer);

    RandomAccessFile? raf;
    SftpFile? remoteFile;
    try {
      raf = await localFile.open(mode: FileMode.read);
      remoteFile = await sftp.open(
        remotePath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );

      const chunkSize = 256 * 1024; // 256KB chunks
      int offset = 0;

      while (offset < totalSize) {
        if (_cancelTransferId == transferId) {
          throw const SftpTransferCancelledException();
        }

        final len = (totalSize - offset) < chunkSize
            ? (totalSize - offset)
            : chunkSize;
        final chunk = await raf.read(len);
        if (chunk.isEmpty) break;

        await remoteFile.writeBytes(chunk, offset: offset);
        offset += chunk.length;

        _activeTransfer = transfer.copyWith(bytesTransferred: offset);
        notifyListeners();
      }

      _directoryCache.invalidate(
        activeSession.connectionId,
        activeSession.targetFingerprint,
      );
      await SftpFileCache.invalidate(
        activeSession.connectionId,
        activeSession.targetFingerprint,
        remotePath,
      );
      AppLogService.instance.info(
        'SFTP file uploaded via stream',
        details: SftpLogSafety.details(
          operation: 'stream_upload',
          connectionId: activeSession.connectionId,
          path: remotePath,
          bytes: totalSize,
        ),
      );
      _completeTransferTelemetry(
        transferId,
        transfer.copyWith(bytesTransferred: totalSize),
      );
      await _openPath(activeSession, activeSession.currentPath);
    } catch (e) {
      if (e is SftpTransferCancelledException) {
        AppLogService.instance.info(
          'SFTP upload cancelled',
          details: SftpLogSafety.details(
            operation: 'stream_upload_cancelled',
            connectionId: activeSession.connectionId,
            path: remotePath,
          ),
        );
        try {
          await sftp.remove(remotePath);
        } catch (_) {}
        activeSession.state = SftpConnectionState.connected;
        _failTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
          errorCode: AppTelemetryErrorCodes.sftpTransferAborted.code,
          stage: 'upload',
          errorMessage: 'Transfer cancelled by user',
        );
      } else {
        AppLogService.instance.error(
          'SFTP upload failed',
          details: SftpLogSafety.details(
            operation: 'stream_upload',
            connectionId: activeSession.connectionId,
            path: remotePath,
            error: e,
          ),
        );
        activeSession.state = SftpConnectionState.error;
        activeSession.errorMessage = 'Upload failed: $e';
        _failTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
          errorCode: _mapSftpErrorCode(e, isUpload: true),
          stage: 'upload',
          errorMessage: '$e',
        );
      }
      notifyListeners();
      rethrow;
    } finally {
      await raf?.close();
      await _closeFileQuietly(remoteFile);
      _activeTransfer = null;
      _cancelTransferId = null;
      notifyListeners();
    }
  }

  @override
  Future<void> downloadFile(
    SftpEntry entry, {
    required String localPath,
    int maxBytes = SftpService.maxDownloadBytes,
  }) async {
    final session = _sessionForEntry(entry);
    final sftp = session.sftp;
    if (sftp == null) throw StateError('SFTP is not connected');
    if (entry.isDirectory) throw StateError('Directories cannot be downloaded');

    final totalSize = entry.size ?? 0;
    if (totalSize > 0) {
      _assertWithinMemoryLimit(totalSize, 'download', maxBytes: maxBytes);
    }

    final transferId = DateTime.now().millisecondsSinceEpoch.toString();
    final transfer = SftpTransferState(
      id: transferId,
      name: entry.name,
      totalBytes: totalSize,
      isUpload: false,
    );
    _activeTransfer = transfer;
    _cancelTransferId = null;
    session.state = SftpConnectionState.loading;
    notifyListeners();
    _startTransferTelemetry(transferId, transfer);

    RandomAccessFile? raf;
    SftpFile? remoteFile;
    var shouldDeletePartialLocalFile = false;
    try {
      final localFile = File(localPath);
      final parentDir = localFile.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      raf = await localFile.open(mode: FileMode.write);
      remoteFile = await sftp.open(entry.path, mode: SftpFileOpenMode.read);

      const chunkSize = 256 * 1024; // 256KB chunks
      int offset = 0;

      while (totalSize == 0 || offset < totalSize) {
        if (_cancelTransferId == transferId) {
          throw const SftpTransferCancelledException();
        }

        final len = (totalSize > 0 && (totalSize - offset) < chunkSize)
            ? (totalSize - offset)
            : chunkSize;
        final chunk = await remoteFile.readBytes(length: len, offset: offset);
        if (chunk.isEmpty) break;

        if (offset + chunk.length > maxBytes) {
          throw StateError(
            'Download exceeds max size of ${_formatBytes(maxBytes)}',
          );
        }

        await raf.writeFrom(chunk);
        offset += chunk.length;

        _activeTransfer = transfer.copyWith(bytesTransferred: offset);
        notifyListeners();
      }

      AppLogService.instance.info(
        'SFTP file downloaded via stream',
        details: SftpLogSafety.details(
          operation: 'stream_download',
          connectionId: entry.connectionId,
          path: entry.path,
          destinationPath: localPath,
          bytes: offset,
        ),
      );

      session.state = SftpConnectionState.connected;
      notifyListeners();
      _completeTransferTelemetry(
        transferId,
        transfer.copyWith(bytesTransferred: offset),
      );
    } catch (e) {
      shouldDeletePartialLocalFile = true;

      if (e is SftpTransferCancelledException) {
        AppLogService.instance.info(
          'SFTP download cancelled',
          details: SftpLogSafety.details(
            operation: 'stream_download_cancelled',
            connectionId: entry.connectionId,
            path: entry.path,
            destinationPath: localPath,
          ),
        );
        session.state = SftpConnectionState.connected;
        _failTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
          errorCode: AppTelemetryErrorCodes.sftpTransferAborted.code,
          stage: 'download',
          errorMessage: 'Transfer cancelled by user',
        );
      } else {
        AppLogService.instance.error(
          'SFTP download failed',
          details: SftpLogSafety.details(
            operation: 'stream_download',
            connectionId: entry.connectionId,
            path: entry.path,
            destinationPath: localPath,
            error: e,
          ),
        );
        session.state = SftpConnectionState.error;
        session.errorMessage = 'Download failed: $e';
        _failTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
          errorCode: _mapSftpErrorCode(e, isUpload: false),
          stage: 'download',
          errorMessage: '$e',
        );
      }
      notifyListeners();
      rethrow;
    } finally {
      await raf?.close();
      await _closeFileQuietly(remoteFile);

      // 先关闭本地文件句柄再删除半成品，避免 Windows 上文件占用导致删除失败。
      if (shouldDeletePartialLocalFile) {
        try {
          final file = File(localPath);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }

      _activeTransfer = null;
      _cancelTransferId = null;
      notifyListeners();
    }
  }

  @override
  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  }) async {
    final session = _activeSession;
    final sftp = session?.sftp;
    if (sftp == null) return;
    _assertWithinMemoryLimit(bytes.length, 'upload', maxBytes: maxUploadBytes);

    session!.state = SftpConnectionState.loading;
    session.errorMessage = null;
    notifyListeners();

    final remotePath = _joinRemotePath(session.currentPath, filename);
    final transferId = DateTime.now().millisecondsSinceEpoch.toString();
    final transfer = SftpTransferState(
      id: transferId,
      name: filename,
      totalBytes: bytes.length,
      isUpload: true,
    );
    _startTransferTelemetry(transferId, transfer);
    SftpFile? file;
    try {
      file = await sftp.open(
        remotePath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      await file.writeBytes(bytes);
      _directoryCache.invalidate(
        session.connectionId,
        session.targetFingerprint,
      );
      await SftpFileCache.invalidate(
        session.connectionId,
        session.targetFingerprint,
        remotePath,
      );
      AppLogService.instance.info(
        'SFTP file uploaded',
        details: SftpLogSafety.details(
          operation: 'upload_bytes',
          connectionId: session.connectionId,
          path: remotePath,
          bytes: bytes.length,
        ),
      );
      _completeTransferTelemetry(
        transferId,
        transfer.copyWith(bytesTransferred: bytes.length),
      );
      await _openPath(session, session.currentPath);
    } catch (e) {
      AppLogService.instance.error(
        'SFTP upload failed',
        details: SftpLogSafety.details(
          operation: 'upload_bytes',
          connectionId: session.connectionId,
          path: remotePath,
          error: e,
        ),
      );
      _failTransferTelemetry(
        transferId,
        transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
        errorCode: _mapSftpErrorCode(e, isUpload: true),
        stage: 'upload',
        errorMessage: '$e',
      );
      session.state = SftpConnectionState.error;
      session.errorMessage = 'Upload failed: $e';
      notifyListeners();
      rethrow;
    } finally {
      await _closeFileQuietly(file);
    }
  }

  @override
  Future<void> deleteEntry(
    SftpEntry entry, {
    required String confirmedName,
  }) async {
    if (confirmedName != entry.name && confirmedName.trim() != entry.name) {
      throw StateError('Deletion confirmation does not match the entry name.');
    }
    final session = _sessionForEntry(entry);
    final sftp = session.sftp;
    if (sftp == null) return;

    session.state = SftpConnectionState.loading;
    session.errorMessage = null;
    notifyListeners();

    try {
      if (entry.isDirectory) {
        await sftp.rmdir(entry.path);
      } else {
        await sftp.remove(entry.path);
      }
      _directoryCache.invalidate(entry.connectionId, session.targetFingerprint);
      await SftpFileCache.invalidate(
        entry.connectionId,
        session.targetFingerprint,
        entry.path,
      );
      AppLogService.instance.info(
        'SFTP entry deleted',
        details: SftpLogSafety.details(
          operation: 'delete_entry',
          connectionId: entry.connectionId,
          path: entry.path,
          directory: entry.isDirectory,
        ),
      );
      await _openPath(session, session.currentPath);
    } catch (e) {
      AppLogService.instance.error(
        'SFTP delete failed',
        details: SftpLogSafety.details(
          operation: 'delete_entry',
          connectionId: entry.connectionId,
          path: entry.path,
          directory: entry.isDirectory,
          error: e,
        ),
      );
      session.state = SftpConnectionState.error;
      session.errorMessage = 'Delete failed: $e';
      notifyListeners();
    }
  }

  Future<Uint8List> downloadBytes(
    SftpEntry entry, {
    int maxBytes = maxDownloadBytes,
    bool updateState = false,
    bool bypassCache = false,
  }) async {
    final session = _sessionForEntry(entry);
    final sftp = session.sftp;
    if (sftp == null) throw StateError('SFTP is not connected');
    if (entry.isDirectory) throw StateError('Directories cannot be downloaded');
    _assertWithinMemoryLimit(entry.size, 'download', maxBytes: maxBytes);

    if (!bypassCache) {
      final cachedBytes = await SftpFileCache.get(
        entry.connectionId,
        session.targetFingerprint,
        entry.path,
        entry.size,
        entry.modifiedAt,
        maxBytes: maxBytes,
      );
      if (cachedBytes != null) {
        return cachedBytes;
      }
    }

    if (updateState) {
      session.state = SftpConnectionState.loading;
      session.errorMessage = null;
      notifyListeners();
    }

    final transferId = '${entry.connectionId}-${DateTime.now().millisecondsSinceEpoch}';
    final transfer = SftpTransferState(
      id: transferId,
      name: entry.name,
      totalBytes: entry.size ?? 0,
      isUpload: false,
    );
    _startTransferTelemetry(transferId, transfer);
    SftpFile? file;
    try {
      file = await sftp.open(entry.path, mode: SftpFileOpenMode.read);
      final bytes = await _readFileBytesWithinLimit(file, maxBytes: maxBytes);
      AppLogService.instance.info(
        'SFTP file downloaded',
        details: SftpLogSafety.details(
          operation: 'download_bytes',
          connectionId: entry.connectionId,
          path: entry.path,
          bytes: bytes.length,
        ),
      );

      await SftpFileCache.put(
        entry.connectionId,
        session.targetFingerprint,
        entry.path,
        entry.size,
        entry.modifiedAt,
        bytes,
      );

      _completeTransferTelemetry(
        transferId,
        transfer.copyWith(bytesTransferred: bytes.length),
      );
      if (updateState) {
        session.state = SftpConnectionState.connected;
        notifyListeners();
      }
      return bytes;
    } catch (e) {
      AppLogService.instance.error(
        'SFTP download failed',
        details: SftpLogSafety.details(
          operation: 'download_bytes',
          connectionId: entry.connectionId,
          path: entry.path,
          error: e,
        ),
      );
      _failTransferTelemetry(
        transferId,
        transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
        errorCode: _mapSftpErrorCode(e, isUpload: false),
        stage: 'download',
        errorMessage: '$e',
      );
      if (updateState) {
        session.state = SftpConnectionState.error;
        session.errorMessage = 'Download failed: $e';
        notifyListeners();
      }
      rethrow;
    } finally {
      await _closeFileQuietly(file);
    }
  }

  Future<String> readTextFile(
    SftpEntry entry, {
    int maxBytes = maxTextEditBytes,
  }) async {
    final sftp = _sessionForEntry(entry).sftp;
    if (sftp == null) throw StateError('SFTP is not connected');
    _assertWithinMemoryLimit(entry.size, 'edit', maxBytes: maxBytes);

    SftpFile? file;
    try {
      file = await sftp.open(entry.path, mode: SftpFileOpenMode.read);
      final bytes = await _readFileBytesWithinLimit(file, maxBytes: maxBytes);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      await _closeFileQuietly(file);
    }
  }

  Future<void> saveTextFile(
    SftpEntry entry,
    String text, {
    int maxBytes = maxTextEditBytes,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.length > maxBytes) {
      throw SftpTextSizeLimitException(
        actualBytes: bytes.length,
        maxBytes: maxBytes,
      );
    }

    final session = _sessionForEntry(entry);
    final sftp = session.sftp;
    if (sftp == null) throw StateError('SFTP is not connected');

    session.state = SftpConnectionState.loading;
    session.errorMessage = null;
    notifyListeners();

    SftpFile? file;
    try {
      file = await sftp.open(
        entry.path,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      await file.writeBytes(bytes);
      await _closeFileQuietly(file);
      file = null;
      _directoryCache.invalidate(entry.connectionId, session.targetFingerprint);
      await SftpFileCache.invalidate(
        entry.connectionId,
        session.targetFingerprint,
        entry.path,
      );
      AppLogService.instance.info(
        'SFTP text file saved',
        details: SftpLogSafety.details(
          operation: 'save_text',
          connectionId: entry.connectionId,
          path: entry.path,
          bytes: bytes.length,
        ),
      );
      await _openPath(session, session.currentPath, bypassCache: true);
    } catch (e) {
      AppLogService.instance.error(
        'SFTP save failed',
        details: SftpLogSafety.details(
          operation: 'save_text',
          connectionId: entry.connectionId,
          path: entry.path,
          error: e,
        ),
      );
      session.state = SftpConnectionState.error;
      session.errorMessage = 'Save failed: $e';
      notifyListeners();
      rethrow;
    } finally {
      await _closeFileQuietly(file);
    }
  }

  @override
  Future<void> openPath(String path) async {
    final session = _activeSession;
    if (session == null) return;
    return _openPath(session, path);
  }

  @override
  Future<List<SftpEntry>> listDirectoryForConnection(
    String connectionId,
    String path,
  ) => _listDirectoryForConnectionImpl(connectionId, path);

  @override
  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = maxTextPreviewBytes,
  }) => _readTextPathForConnectionImpl(
    connectionId: connectionId,
    path: path,
    maxBytes: maxBytes,
  );

  @override
  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = maxDownloadBytes,
  }) => _downloadPathForConnectionImpl(
    connectionId: connectionId,
    path: path,
    maxBytes: maxBytes,
  );

  @override
  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = maxTextEditBytes,
  }) => _writeTextPathForConnectionImpl(
    connectionId: connectionId,
    path: path,
    text: text,
    maxBytes: maxBytes,
  );

  @override
  Future<SftpPathInfo> statPathForConnection({
    required String connectionId,
    required String path,
  }) => _statPathForConnectionImpl(connectionId: connectionId, path: path);

  @override
  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = maxUploadBytes,
  }) => _uploadBytesPathForConnectionImpl(
    connectionId: connectionId,
    path: path,
    bytes: bytes,
    maxBytes: maxBytes,
  );

  @override
  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  }) => _createDirectoryPathForConnectionImpl(
    connectionId: connectionId,
    path: path,
  );

  @override
  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  }) => _renamePathForConnectionImpl(
    connectionId: connectionId,
    path: path,
    newPath: newPath,
  );

  @override
  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  }) => _deletePathForConnectionImpl(connectionId: connectionId, path: path);

  @override
  Future<void> openParent() {
    final path = currentPath;
    if (path == '/' || path.isEmpty) return refresh();
    final trimmed = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final slash = trimmed.lastIndexOf('/');
    if (slash <= 0) return openPath('/');
    return openPath(trimmed.substring(0, slash));
  }

  @override
  Future<void> disconnect({bool notify = true}) async {
    final connectionId = _activeConnectionId;
    if (connectionId == null) return;
    final session = _sessions.remove(connectionId);
    if (session != null) {
      _lastPaths[connectionId] = session.currentPath;
    }
    session?.close();
    _activeConnectionId = null;

    if (notify) notifyListeners();
  }

  @override
  Future<void> disconnectConnection(
    String connectionId, {
    bool notify = true,
    bool forgetPath = false,
  }) async {
    _connectTasks.remove(connectionId);
    final session = _sessions.remove(connectionId);
    if (session != null && !forgetPath) {
      _lastPaths[connectionId] = session.currentPath;
    }
    if (forgetPath) {
      _lastPaths.remove(connectionId);
      await SftpFileCache.clearConnection(connectionId);
    }
    session?.close();
    if (_activeConnectionId == connectionId) {
      _activeConnectionId = null;
    }
    if (notify) notifyListeners();
  }

  @override
  Future<void> disconnectAll({bool notify = true}) async {
    _connectTasks.clear();
    for (final session in _sessions.values) {
      _lastPaths[session.connectionId] = session.currentPath;
      session.close();
    }
    _sessions.clear();
    _activeConnectionId = null;
    if (notify) notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(_notifyCoalesceDelay, () {
      _notifyTimer = null;
      if (!_disposed) super.notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    _directoryCache.clear();
    unawaited(disconnectAll(notify: false));
    super.dispose();
  }

  void notify() {
    notifyListeners();
  }
}

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
