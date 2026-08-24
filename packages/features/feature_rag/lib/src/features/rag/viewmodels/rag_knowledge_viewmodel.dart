// RAG 知识库页面的 Route-scoped ViewModel。
//
// ViewModel 只转发页面状态和用户动作，不创建数据库、缓存或 API Client；
// Module Service 与 App Settings Port 的生命周期由上层 Scope 管理。

import 'package:flutter/foundation.dart';

import '../../../application/rag_service.dart';
import '../../../domain/rag_models.dart';
import '../../../domain/rag_ports.dart';

final class RagKnowledgeViewModel extends ChangeNotifier {
  RagKnowledgeViewModel({required this._ragService, required this._settings}) {
    _ragService.addListener(_onServiceChanged);
    _settings.addListener(_onSettingsChanged);
  }

  final RagService _ragService;
  final RagSettingsPort _settings;
  bool _isProcessing = false;
  String? _initializationError;

  List<RagDocumentMetadata> get documents => _ragService.documents;

  bool get isLoading => _ragService.isLoading;

  bool get isProcessing => _isProcessing;

  bool get isEnglish => _settings.isEnglish;

  bool get isInitialLoading =>
      !_ragService.isInitialized && _initializationError == null;

  String? get initializationError => _initializationError;

  bool get isInitialized => _ragService.isInitialized;

  Future<void> initRag() async {
    _initializationError = null;
    await Future<void>.delayed(Duration.zero);
    try {
      await _ragService.init();
    } catch (e) {
      _initializationError = e.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> retryInit() {
    _initializationError = null;
    notifyListeners();
    return initRag();
  }

  Future<String?> getAliyunApiKey() => _settings.getAliyunApiKey();

  Future<void> saveAliyunApiKey(String key) async {
    await _settings.saveAliyunApiKey(key);
    notifyListeners();
  }

  Future<void> addDocument(
    String name,
    Uint8List bytes,
    String mimeType,
  ) async {
    _isProcessing = true;
    notifyListeners();
    try {
      await _ragService.addDocument(
        name: name,
        bytes: bytes,
        mimeType: mimeType,
      );
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  Future<void> deleteDocument(String documentId) async {
    _isProcessing = true;
    notifyListeners();
    try {
      await _ragService.deleteDocument(documentId);
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _ragService.removeListener(_onServiceChanged);
    _settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onServiceChanged() => notifyListeners();

  void _onSettingsChanged() => notifyListeners();
}
