class TerminalHistoryService {
  static const int defaultLoadBytes = 2 * 1024 * 1024;

  Future<void> append(String sessionId, String data) async {}

  Future<String> readTail(
    String sessionId, {
    int maxBytes = defaultLoadBytes,
  }) async {
    return '';
  }

  Future<Object?> historyFile(String sessionId) async => null;

  Future<void> flush() async {}
}
