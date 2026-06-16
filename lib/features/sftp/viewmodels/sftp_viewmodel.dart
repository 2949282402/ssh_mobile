import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../../../services/sftp_service.dart';

class SftpViewModel extends ChangeNotifier {
  final SftpService _sftpService;

  SftpViewModel({
    required SftpService sftpService,
  }) : _sftpService = sftpService {
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

  bool isConnectionBusy(String id) => _sftpService.isConnectionBusy(id);
  bool isConnectionOpen(String id) => _sftpService.isConnectionOpen(id);

  Future<void> connect(String connectionId) async {
    await _sftpService.connect(connectionId);
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

  Future<String> readTextFile(
    SftpEntry entry, {
    required int maxBytes,
  }) async {
    return await _sftpService.readTextFile(entry, maxBytes: maxBytes);
  }

  Future<void> saveTextFile(
    SftpEntry entry,
    String content,
  ) async {
    await _sftpService.saveTextFile(entry, content);
  }
}
