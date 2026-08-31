// SSH Service 与 Terminal 历史仓库共享测试替身。

import 'package:connection_core/connection_core.dart';
import 'package:feature_terminal/feature_terminal.dart' as feature_terminal;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/terminal_session_metadata_store.dart';

final class FakeSshService extends Fake implements SshService {
  @override
  List<SshSession> sessions = <SshSession>[];
  final Map<String, SshSession> sessionsById = <String, SshSession>{};
  @override
  String? errorMessage;
  @override
  bool initialized = true;
  String defaultDisplayName = 'Server A';
  bool sessionNameAvailable = true;
  bool renameResult = true;
  String? openSessionResult = 'session-1';
  bool sessionConnectedResult = true;
  bool connectedResult = true;
  int sessionCountResult = 0;
  String historyText = 'history';
  bool invokeUnknownHostKey = false;
  ssh_core.SshHostKeyPromptRequest? unknownHostKeyRequest;
  int ensureInitializedCalls = 0;
  int disconnectCalls = 0;
  int disconnectSessionsForConnectionCalls = 0;
  int closeCalls = 0;
  Object? closeError;
  ssh_core.SshHostKeyConfirmation? capturedUnknownHostKey;
  final List<({String sessionId, double fontSize})> fontSizeUpdates =
      <({String sessionId, double fontSize})>[];
  final List<({String sessionId, String data})> sentData =
      <({String sessionId, String data})>[];
  final List<({String sessionId, int width, int height})> resizes =
      <({String sessionId, int width, int height})>[];
  final List<String> disconnectedSessions = <String>[];
  final List<({String sessionId, String name})> renames =
      <({String sessionId, String name})>[];
  final List<VoidCallback> _listeners = <VoidCallback>[];

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void emitChange() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  SshSession? getSession(String sessionId) => sessionsById[sessionId];

  @override
  Future<String> loadSessionHistoryText(String sessionId) async => historyText;

  @override
  Future<bool> ensureSessionConnected(
    String sessionId,
    String connectionId,
  ) async => sessionConnectedResult;

  @override
  void setSessionFontSize(String sessionId, double fontSize) {
    fontSizeUpdates.add((sessionId: sessionId, fontSize: fontSize));
  }

  @override
  void sendData(String sessionId, String data) {
    sentData.add((sessionId: sessionId, data: data));
  }

  @override
  void resizeTerminal(String sessionId, int width, int height) {
    resizes.add((sessionId: sessionId, width: width, height: height));
  }

  @override
  Future<void> disconnectSession(String sessionId) async {
    disconnectedSessions.add(sessionId);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  @override
  Future<void> disconnectSessionsForConnection(String connectionId) async {
    disconnectSessionsForConnectionCalls++;
  }

  bool isSessionNameAvailable(String name) => sessionNameAvailable;

  @override
  bool renameSession(String sessionId, String name) {
    renames.add((sessionId: sessionId, name: name));
    return renameResult;
  }

  @override
  Future<String?> openSession(
    String connectionId, {
    String? displayName,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    capturedUnknownHostKey = onUnknownHostKey;
    if (invokeUnknownHostKey && onUnknownHostKey != null) {
      await onUnknownHostKey(unknownHostKeyRequest!);
    }
    return openSessionResult;
  }

  @override
  Future<bool> ensureConnected(String connectionId) async => connectedResult;

  @override
  int sessionCountForConnection(String connectionId) => sessionCountResult;

  String defaultDisplayNameForConnection(String connectionId) =>
      defaultDisplayName;

  @override
  Future<void> ensureInitialized() async {
    ensureInitializedCalls++;
  }

  @override
  Future<ssh_core.SshSessionLease> acquire({
    required String sessionId,
    required Future<ssh_core.SshSession> Function() create,
  }) async {
    final session = await create();
    return ssh_core.SshSessionLease(
      session: session,
      releaseCallback: () async {},
    );
  }

  @override
  Future<void> close() async {
    closeCalls++;
    final error = closeError;
    if (error != null) throw error;
  }
}

/// 真实 SshService 子类，用于扩展方法（如 isSessionNameAvailable /
/// defaultDisplayNameForConnection）必须作用于真实私有状态的路径。
///
/// 这些扩展方法无法被 `implements` 替身拦截，其它成员仍由测试替身覆盖。
final class TestSshService extends SshService {
  /// 使用独立内存仓库创建真实 SSH Service；[connection] 供显示名解析。
  TestSshService({ConnectionConfig? connection})
    : super(
        connectionRepository: _TestConnectionRepository(connection),
        credentialRepository: _TestCredentialRepository(),
        hostKeyRepository: _TestHostKeyRepository(),
        terminalMetadataStore: TerminalSessionMetadataStore(),
      );
}

final class _TestConnectionRepository extends Fake
    implements ConnectionRepository {
  _TestConnectionRepository(this.config);

  ConnectionConfig? config;

  @override
  ConnectionConfig? getConnection(String id) => config;

  @override
  List<ConnectionConfig> get connections =>
      config == null ? const <ConnectionConfig>[] : <ConnectionConfig>[config!];
}

final class _TestCredentialRepository extends Fake
    implements CredentialRepository {}

final class _TestHostKeyRepository extends Fake implements HostKeyRepository {}

final class FakeTerminalHistoryRepository extends Fake
    implements feature_terminal.TerminalHistoryRepository {
  List<feature_terminal.TerminalHistoryRecord> records =
      <feature_terminal.TerminalHistoryRecord>[];
  final List<feature_terminal.TerminalHistoryRecord> saved =
      <feature_terminal.TerminalHistoryRecord>[];
  final List<String> removed = <String>[];
  final List<List<feature_terminal.TerminalHistoryRecord>> replaced =
      <List<feature_terminal.TerminalHistoryRecord>>[];

  @override
  Future<List<feature_terminal.TerminalHistoryRecord>> loadRecords() async =>
      List<feature_terminal.TerminalHistoryRecord>.of(records);

  @override
  Future<void> saveRecord(feature_terminal.TerminalHistoryRecord record) async {
    saved.add(record);
  }

  @override
  Future<void> removeRecord(String sessionId) async {
    removed.add(sessionId);
  }

  @override
  Future<void> replaceAll(
    Iterable<feature_terminal.TerminalHistoryRecord> records,
  ) async {
    replaced.add(List<feature_terminal.TerminalHistoryRecord>.of(records));
  }
}
