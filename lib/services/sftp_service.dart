import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../models/connection.dart';
import 'app_log_service.dart';
import 'ssh_client_factory.dart';
import 'storage_service.dart';

abstract interface class SftpClientAdapter {
  String? get connectionId;
  String? get connectionName;
  String get currentPath;
  SftpConnectionState get state;
  String? get errorMessage;
  int get entriesRevision;
  List<SftpEntry> get entries;
  bool get isConnected;
  bool get isBusy;

  bool isConnectionBusy(String connectionId);

  bool isConnectionOpen(String connectionId);

  Future<void> connect(String connectionId);

  Future<void> refresh();

  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  });

  Future<void> deleteEntry(
    SftpEntry entry, {
    required String confirmedName,
  });

  Future<List<SftpEntry>> listDirectoryForConnection(
    String connectionId,
    String path,
  );

  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = SftpService.maxTextPreviewBytes,
  });

  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = SftpService.maxDownloadBytes,
  });

  Future<SftpPathInfo> statPathForConnection({
    required String connectionId,
    required String path,
  });

  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = SftpService.maxTextEditBytes,
  });

  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = SftpService.maxUploadBytes,
  });

  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  });

  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  });

  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  });

  Future<void> openPath(String path);

  Future<void> openParent();

  Future<void> disconnect({bool notify = true});

  Future<void> disconnectConnection(
    String connectionId, {
    bool notify = true,
    bool forgetPath = false,
  });

  Future<void> disconnectAll({bool notify = true});
}

enum SftpConnectionState {
  disconnected,
  connecting,
  connected,
  loading,
  error,
}

class SftpEntry {
  final String connectionId;
  final String name;
  final String path;
  final String lowerName;
  final bool isDirectory;
  final bool isLink;
  final int? size;
  final String sizeLabel;
  final DateTime? modifiedAt;
  final String? modifiedLabel;

  const SftpEntry({
    required this.connectionId,
    required this.name,
    required this.path,
    required this.lowerName,
    required this.isDirectory,
    required this.isLink,
    required this.sizeLabel,
    this.size,
    this.modifiedAt,
    this.modifiedLabel,
  });
}

class SftpPathInfo {
  final String path;
  final bool isDirectory;
  final bool isLink;
  final int? size;
  final String sizeLabel;
  final DateTime? modifiedAt;

  const SftpPathInfo({
    required this.path,
    required this.isDirectory,
    required this.isLink,
    required this.size,
    required this.sizeLabel,
    required this.modifiedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'type': isDirectory ? 'directory' : 'file',
      'isDirectory': isDirectory,
      'isLink': isLink,
      'size': size,
      'sizeLabel': sizeLabel,
      'modifiedAt': modifiedAt?.toIso8601String(),
    };
  }
}

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

  final StorageService _storageService;
  late final SshClientFactory _clientFactory =
      SshClientFactory(_storageService);

  final Map<String, _SftpSession> _sessions = {};
  final Map<String, String> _lastPaths = {};
  final Map<String, Future<void>> _connectTasks = {};
  Timer? _notifyTimer;
  String? _activeConnectionId;
  bool _disposed = false;

  SftpService(this._storageService);

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

  @override
  Future<void> connect(String connectionId) async {
    final config = _storageService.getConnection(connectionId);
    if (config == null) {
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
      session.errorMessage = 'Connection config not found';
      notifyListeners();
      return;
    }

    final existing = _sessions[connectionId];
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
    );
    _sessions[connectionId] = session;
    _activeConnectionId = connectionId;
    session.state = SftpConnectionState.connecting;
    session.errorMessage = null;
    notifyListeners();
    final task = _connect(session, config);
    _connectTasks[connectionId] = task;
    try {
      await task;
    } finally {
      if (identical(_connectTasks[connectionId], task)) {
        _connectTasks.remove(connectionId);
      }
    }
  }

  Future<void> _connect(_SftpSession session, ConnectionConfig config) async {
    try {
      final client = await _clientFactory.connectClient(config);
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
      notifyListeners();
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
      notifyListeners();
    }
  }

  @override
  Future<void> refresh() => openPath(currentPath);

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
    SftpFile? file;
    try {
      file = await sftp.open(
        remotePath,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      await file.writeBytes(bytes);
      AppLogService.instance.info(
        'SFTP file uploaded',
        details: 'path=$remotePath bytes=${bytes.length}',
      );
      await _openPath(session, session.currentPath);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'SFTP upload failed',
        error: e,
        stackTrace: stackTrace,
        details: 'path=$remotePath',
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
      AppLogService.instance.info(
        'SFTP entry deleted',
        details: 'path=${entry.path} directory=${entry.isDirectory}',
      );
      await _openPath(session, session.currentPath);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'SFTP delete failed',
        error: e,
        stackTrace: stackTrace,
        details: 'path=${entry.path}',
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
  }) async {
    final session = _sessionForEntry(entry);
    final sftp = session.sftp;
    if (sftp == null) throw StateError('SFTP is not connected');
    if (entry.isDirectory) throw StateError('Directories cannot be downloaded');
    _assertWithinMemoryLimit(entry.size, 'download', maxBytes: maxBytes);
    if (updateState) {
      session.state = SftpConnectionState.loading;
      session.errorMessage = null;
      notifyListeners();
    }

    SftpFile? file;
    try {
      file = await sftp.open(entry.path, mode: SftpFileOpenMode.read);
      final bytes = await file.readBytes();
      _assertWithinMemoryLimit(bytes.length, 'download', maxBytes: maxBytes);
      AppLogService.instance.info(
        'SFTP file downloaded',
        details: 'path=${entry.path} bytes=${bytes.length}',
      );
      if (updateState) {
        session.state = SftpConnectionState.connected;
        notifyListeners();
      }
      return bytes;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'SFTP download failed',
        error: e,
        stackTrace: stackTrace,
        details: 'path=${entry.path}',
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

  Future<String> readTextFile(SftpEntry entry,
      {int maxBytes = maxTextEditBytes}) async {
    final sftp = _sessionForEntry(entry).sftp;
    if (sftp == null) throw StateError('SFTP is not connected');
    _assertWithinMemoryLimit(entry.size, 'edit', maxBytes: maxBytes);

    SftpFile? file;
    try {
      file = await sftp.open(entry.path, mode: SftpFileOpenMode.read);
      final bytes = await file.readBytes();
      _assertWithinMemoryLimit(bytes.length, 'edit', maxBytes: maxBytes);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      await _closeFileQuietly(file);
    }
  }

  Future<void> saveTextFile(SftpEntry entry, String text) async {
    final session = _sessionForEntry(entry);
    final sftp = session.sftp;
    if (sftp == null) return;

    session.state = SftpConnectionState.loading;
    session.errorMessage = null;
    notifyListeners();

    SftpFile? file;
    try {
      file = await sftp.open(
        entry.path,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      final bytes = Uint8List.fromList(utf8.encode(text));
      await file.writeBytes(bytes);
      AppLogService.instance.info(
        'SFTP text file saved',
        details: 'path=${entry.path} bytes=${bytes.length}',
      );
      await _openPath(session, session.currentPath);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'SFTP save failed',
        error: e,
        stackTrace: stackTrace,
        details: 'path=${entry.path}',
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
  ) async {
    return _withDetachedSftp(connectionId, (sftp, config) async {
      final absolutePath = await sftp.absolute(path);
      final names = await sftp.listdir(absolutePath);
      final entries = _buildEntries(
        connectionId: config.id,
        absolutePath: absolutePath,
        names: names,
      );
      AppLogService.instance.info(
        'SFTP directory listed for tool',
        details: 'connection=${config.name} path=$absolutePath',
      );
      return List.unmodifiable(entries);
    });
  }

  @override
  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = maxTextPreviewBytes,
  }) async {
    return _withDetachedSftp(connectionId, (sftp, config) async {
      SftpFile? file;
      try {
        file = await sftp.open(path, mode: SftpFileOpenMode.read);
        final bytes = await file.readBytes();
        _assertWithinMemoryLimit(bytes.length, 'read', maxBytes: maxBytes);
        AppLogService.instance.info(
          'SFTP file read for tool',
          details: 'connection=${config.name} path=$path bytes=${bytes.length}',
        );
        return utf8.decode(bytes, allowMalformed: true);
      } finally {
        await _closeFileQuietly(file);
      }
    });
  }

  @override
  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = maxDownloadBytes,
  }) async {
    return _withDetachedSftp(connectionId, (sftp, config) async {
      final absolutePath = await sftp.absolute(path);
      final attrs = await sftp.stat(absolutePath);
      if (attrs.isDirectory) {
        throw StateError('Directories cannot be downloaded');
      }
      _assertWithinMemoryLimit(attrs.size, 'download', maxBytes: maxBytes);

      SftpFile? file;
      try {
        file = await sftp.open(absolutePath, mode: SftpFileOpenMode.read);
        final bytes = await file.readBytes();
        _assertWithinMemoryLimit(bytes.length, 'download', maxBytes: maxBytes);
        AppLogService.instance.info(
          'SFTP file downloaded for tool',
          details:
              'connection=${config.name} path=$absolutePath bytes=${bytes.length}',
        );
        return bytes;
      } finally {
        await _closeFileQuietly(file);
      }
    });
  }

  @override
  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = maxTextEditBytes,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    _assertWithinMemoryLimit(bytes.length, 'edit', maxBytes: maxBytes);
    await _withDetachedSftp(connectionId, (sftp, config) async {
      final absolutePath = await sftp.absolute(path);
      SftpFile? file;
      try {
        file = await sftp.open(
          absolutePath,
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.truncate |
              SftpFileOpenMode.write,
        );
        await file.writeBytes(bytes);
        AppLogService.instance.info(
          'SFTP text file saved for tool',
          details:
              'connection=${config.name} path=$absolutePath bytes=${bytes.length}',
        );
      } finally {
        await _closeFileQuietly(file);
      }
    });
  }

  @override
  Future<SftpPathInfo> statPathForConnection({
    required String connectionId,
    required String path,
  }) async {
    return _withDetachedSftp(connectionId, (sftp, _) async {
      final absolutePath = await sftp.absolute(path);
      final attrs = await sftp.stat(absolutePath);
      final modifiedAt = attrs.modifyTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000);
      return SftpPathInfo(
        path: absolutePath,
        isDirectory: attrs.isDirectory,
        isLink: attrs.isSymbolicLink,
        size: attrs.size,
        sizeLabel: _formatBytes(attrs.size),
        modifiedAt: modifiedAt,
      );
    });
  }

  @override
  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = maxUploadBytes,
  }) async {
    _assertWithinMemoryLimit(bytes.length, 'upload', maxBytes: maxBytes);
    await _withDetachedSftp(connectionId, (sftp, config) async {
      final absolutePath = await sftp.absolute(path);
      SftpFile? file;
      try {
        file = await sftp.open(
          absolutePath,
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.truncate |
              SftpFileOpenMode.write,
        );
        await file.writeBytes(bytes);
        AppLogService.instance.info(
          'SFTP file uploaded for tool',
          details:
              'connection=${config.name} path=$absolutePath bytes=${bytes.length}',
        );
      } finally {
        await _closeFileQuietly(file);
      }
    });
  }

  @override
  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  }) async {
    await _withDetachedSftp(connectionId, (sftp, config) async {
      final absolutePath = await sftp.absolute(path);
      await sftp.mkdir(absolutePath);
      AppLogService.instance.info(
        'SFTP directory created for tool',
        details: 'connection=${config.name} path=$absolutePath',
      );
    });
  }

  @override
  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  }) async {
    await _withDetachedSftp(connectionId, (sftp, config) async {
      final absolutePath = await sftp.absolute(path);
      final absoluteNewPath = await sftp.absolute(newPath);
      await sftp.rename(absolutePath, absoluteNewPath);
      AppLogService.instance.info(
        'SFTP path renamed for tool',
        details:
            'connection=${config.name} from=$absolutePath to=$absoluteNewPath',
      );
    });
  }

  @override
  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  }) async {
    await _withDetachedSftp(connectionId, (sftp, config) async {
      final absolutePath = await sftp.absolute(path);
      final attrs = await sftp.stat(absolutePath);
      if (attrs.isDirectory) {
        await sftp.rmdir(absolutePath);
      } else {
        await sftp.remove(absolutePath);
      }
      AppLogService.instance.info(
        'SFTP path deleted for tool',
        details:
            'connection=${config.name} path=$absolutePath directory=${attrs.isDirectory}',
      );
    });
  }

  Future<void> _openPath(_SftpSession session, String path) async {
    final sftp = session.sftp;
    if (sftp == null) return;

    session.state = SftpConnectionState.loading;
    session.errorMessage = null;
    notifyListeners();

    try {
      final absolutePath = await sftp.absolute(path);
      final names = await sftp.listdir(absolutePath);
      final entries = _buildEntries(
        connectionId: session.connectionId,
        absolutePath: absolutePath,
        names: names,
      );

      session.currentPath = absolutePath;
      _lastPaths[session.connectionId] = absolutePath;
      session.entries = entries;
      session.entriesRevision++;
      session.state = SftpConnectionState.connected;
      notifyListeners();
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'SFTP list directory failed',
        error: e,
        stackTrace: stackTrace,
        details: 'path=$path',
      );
      session.state = SftpConnectionState.error;
      session.errorMessage = 'Unable to read directory: $e';
      notifyListeners();
    }
  }

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
    unawaited(disconnectAll(notify: false));
    super.dispose();
  }

  Future<void> _openLastKnownPath(_SftpSession session) async {
    final targetPath = _lastPaths[session.connectionId] ?? session.currentPath;
    await _openPath(session, targetPath);
    if (session.state != SftpConnectionState.error || targetPath == '.') {
      return;
    }

    AppLogService.instance.warning(
      'SFTP last path unavailable, falling back to default directory',
      details: 'connection=${session.connectionName} path=$targetPath',
    );
    session.errorMessage = null;
    await _openPath(session, '.');
  }

  Future<T> _withDetachedSftp<T>(
    String connectionId,
    Future<T> Function(SftpClient sftp, ConnectionConfig config) action,
  ) async {
    final config = _storageService.getConnection(connectionId);
    if (config == null) {
      throw StateError('Connection config not found');
    }

    final client = await _clientFactory.connectClient(config);
    SftpClient? sftp;
    try {
      sftp = await client.sftp().timeout(const Duration(seconds: 15));
      return await action(sftp, config);
    } finally {
      sftp?.close();
      client.close();
    }
  }

  List<SftpEntry> _buildEntries({
    required String connectionId,
    required String absolutePath,
    required Iterable<dynamic> names,
  }) {
    final entries = <SftpEntry>[];
    for (final name in names) {
      if (name.filename == '.' || name.filename == '..') continue;
      final modifiedAt = name.attr.modifyTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              name.attr.modifyTime! * 1000,
            );
      entries.add(
        SftpEntry(
          connectionId: connectionId,
          name: name.filename,
          path: _joinRemotePath(absolutePath, name.filename),
          lowerName: name.filename.toLowerCase(),
          isDirectory: name.attr.isDirectory,
          isLink: name.attr.isSymbolicLink,
          size: name.attr.size,
          sizeLabel: _formatBytes(name.attr.size),
          modifiedAt: modifiedAt,
          modifiedLabel:
              modifiedAt == null ? null : _formatTimestamp(modifiedAt),
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.lowerName.compareTo(b.lowerName);
    });
    return entries;
  }

  String _joinRemotePath(String base, String name) {
    if (base == '/' || base.isEmpty) return '/$name';
    return '$base/$name';
  }

  _SftpSession _sessionForEntry(SftpEntry entry) {
    final session = _sessions[entry.connectionId];
    if (session == null) {
      throw StateError('SFTP connection is no longer available');
    }
    return session;
  }

  void _assertWithinMemoryLimit(
    int? bytes,
    String action, {
    int maxBytes = maxInMemoryTransferBytes,
  }) {
    if (bytes == null || bytes <= maxBytes) return;
    throw StateError(
      'File is too large to $action in app memory '
      '(${_formatBytes(bytes)} > ${_formatBytes(maxBytes)}).',
    );
  }

  String _formatBytes(int? bytes) {
    if (bytes == null) return '-';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(gb < 10 ? 1 : 0)} GB';
  }

  String _formatTimestamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year.toString().padLeft(4, '0')}-'
        '${two(time.month)}-'
        '${two(time.day)} '
        '${two(time.hour)}:'
        '${two(time.minute)}';
  }

  Future<void> _closeFileQuietly(SftpFile? file) async {
    if (file == null) return;
    try {
      await file.close();
    } catch (e) {
      AppLogService.instance.warning(
        'SFTP file close failed',
        details: '$e',
      );
    }
  }
}

class _SftpSession {
  final String connectionId;
  final String connectionName;
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
  });

  void close() {
    _closed = true;
    sftp?.close();
    client?.close();
  }

  bool isCurrent(Map<String, _SftpSession> sessions) {
    return !_closed && identical(sessions[connectionId], this);
  }
}
