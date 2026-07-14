import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../../core/services/ssh_host_key_policy.dart';
import '../../../services/sftp_service.dart';
import '../../../services/storage_service.dart';

class SftpViewModel extends ChangeNotifier {
  final SftpService _sftpService;

  SftpViewModel({required this._sftpService}) {
    _sftpService.addListener(notifyListeners);
  }

  @override
  void dispose() {
    _sftpService.removeListener(notifyListeners);
    super.dispose();
  }

  String? get connectionId => _sftpService.connectionId;
  String? get connectionName => _sftpService.connectionName;
  String get currentPath => _sftpService.currentPath;
  SftpConnectionState get state => _sftpService.state;
  String? get errorMessage => _sftpService.errorMessage;
  int get entriesRevision => _sftpService.entriesRevision;
  List<SftpEntry> get entries => _sftpService.entries;
  bool get isConnected => _sftpService.isConnected;
  bool get isBusy => _sftpService.isBusy;
  SftpTransferState? get activeTransfer => _sftpService.activeTransfer;
  bool get hasActiveTransfer => _sftpService.hasActiveTransfer;

  bool isConnectionBusy(String id) => _sftpService.isConnectionBusy(id);
  bool isConnectionOpen(String id) => _sftpService.isConnectionOpen(id);

  Future<List<SftpRecentPathRecord>> loadRecentPaths({int limit = 30}) async {
    final id = connectionId;
    if (id == null) return const [];
    return _sftpService.loadRecentPaths(id, limit: limit);
  }

  Future<List<SftpFavoritePathRecord>> loadFavoritePaths() async {
    final id = connectionId;
    if (id == null) return const [];
    return _sftpService.loadFavoritePaths(id);
  }

  Future<SftpFavoritePathRecord?> findFavoritePath(String path) async {
    final id = connectionId;
    if (id == null) return null;
    return _sftpService.findFavoritePath(id, path);
  }

  Future<SftpFavoritePathRecord> addFavoritePath(
    String path,
    String name,
  ) async {
    final id = connectionId;
    if (id == null) {
      throw StateError('SFTP is not connected');
    }
    return _sftpService.addFavoritePath(id, path, name);
  }

  Future<void> removeFavoritePath(String id) {
    return _sftpService.removeFavoritePath(id);
  }

  Future<void> connect(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    await _sftpService.connect(
      connectionId,
      onUnknownHostKey: onUnknownHostKey,
    );
  }

  void disconnect() {
    _sftpService.disconnect();
  }

  Future<void> openPath(String path) async {
    await _sftpService.openPath(path);
  }

  Future<void> openParent() async {
    await _sftpService.openParent();
  }

  Future<void> refresh() async {
    await _sftpService.refresh();
  }

  Future<void> uploadLocalFile({
    required String localPath,
    required String filename,
    required int sizeBytes,
  }) async {
    await _sftpService.uploadFile(localPath: localPath, filename: filename);
  }

  Future<void> downloadToLocalFile({
    required SftpEntry entry,
    required String localPath,
    required int maxBytes,
  }) async {
    await _sftpService.downloadFile(
      entry,
      localPath: localPath,
      maxBytes: maxBytes,
    );
  }

  void cancelActiveTransfer() {
    _sftpService.cancelActiveTransfer();
  }

  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  }) async {
    if (bytes.length > SftpService.maxUploadBytes) {
      throw StateError('File exceeds max upload size of 50MB');
    }
    await _sftpService.uploadBytes(filename: filename, bytes: bytes);
  }

  Future<void> deleteEntry(
    SftpEntry entry, {
    required String confirmedName,
  }) async {
    await _sftpService.deleteEntry(entry, confirmedName: confirmedName);
  }

  Future<Uint8List> downloadBytes(
    SftpEntry entry, {
    int maxBytes = SftpService.maxDownloadBytes,
    bool updateState = false,
  }) async {
    return await _sftpService.downloadBytes(
      entry,
      maxBytes: maxBytes,
      updateState: updateState,
    );
  }

  Future<String> readTextFile(SftpEntry entry, {required int maxBytes}) async {
    return await _sftpService.readTextFile(entry, maxBytes: maxBytes);
  }

  Future<void> saveTextFile(
    SftpEntry entry,
    String content, {
    required int maxBytes,
  }) async {
    await _sftpService.saveTextFile(entry, content, maxBytes: maxBytes);
  }
}
