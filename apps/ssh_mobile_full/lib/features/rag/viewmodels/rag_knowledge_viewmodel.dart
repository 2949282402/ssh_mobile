import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../services/rag_service.dart';
import '../../../services/ai_storage_adapter.dart';

class RagKnowledgeViewModel extends ChangeNotifier {
  final RagService _ragService;
  final AppAiStorageAdapter _aiStorage;

  bool _isProcessing = false;

  RagKnowledgeViewModel({
    required RagService ragService,
    required AppAiStorageAdapter aiStorage,
  }) : _ragService = ragService,
       _aiStorage = aiStorage {
    _ragService.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _ragService.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    notifyListeners();
  }

  // Getters proxying RagService
  List<RagDocumentMetadata> get documents => _ragService.documents;
  bool get isLoading => _ragService.isLoading;
  bool get isProcessing => _isProcessing;

  Future<void> initRag() async {
    await _ragService.init();
  }

  Future<String?> getAliyunApiKey() async {
    return await _aiStorage.getAliyunApiKey();
  }

  Future<void> saveAliyunApiKey(String key) async {
    await _aiStorage.saveAliyunApiKey(key);
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

  Future<void> deleteDocument(String docId) async {
    _isProcessing = true;
    notifyListeners();
    try {
      await _ragService.deleteDocument(docId);
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }
}
