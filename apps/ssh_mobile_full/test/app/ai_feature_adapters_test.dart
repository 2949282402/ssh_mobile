// AI Feature adapter coverage.
//
// These adapters convert App-owned settings, SSH, SFTP, and monitoring
// services into feature_ai Ports. Fakes record delegate calls so assertions
// stay on the observable boundary without platform I/O.

import 'dart:async';
import 'dart:typed_data';

import 'package:app_core/app_core.dart' as app_core;
import 'package:connection_core/connection_core.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/app/ai_feature_adapters.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/sftp_service.dart' as legacy_sftp;
import 'package:ssh_mobile/services/ssh_service.dart' as legacy_ssh;
import 'package:ssh_mobile/services/terminal_session_metadata_store.dart';

import 'support/feature_adapter_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'settings adapter maps state, forwards writes, and stops listening',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings();
      addTearDown(settings.dispose);
      await settings.ensureCoreLoaded();
      final adapter = AppAiSettingsAdapter(settings);
      var notifications = 0;
      adapter.addListener(() => notifications++);

      expect(adapter.language, AppLanguage.zh);
      expect(adapter.isEnglish, isFalse);
      expect(adapter.ragEnabled, isFalse);
      expect(adapter.ragSearchMode, 'bm25');
      expect(adapter.ragTopN, 3);
      expect(
        adapter.sftpDownloadLimitBytes,
        AppSettings.defaultSftpDownloadLimitBytes,
      );
      expect(
        adapter.sftpTextEditLimitBytes,
        AppSettings.defaultSftpTextEditLimitBytes,
      );

      await adapter.setRagEnabled(true);
      await adapter.setRagSearchMode('hybrid');
      await adapter.setRagTopN(7);
      await adapter.setSftpDownloadLimitBytes(64 * 1024);
      await adapter.setSftpTextEditLimitBytes(128 * 1024);

      expect(adapter.ragEnabled, isTrue);
      expect(adapter.ragSearchMode, 'hybrid');
      expect(adapter.ragTopN, 7);
      expect(adapter.sftpDownloadLimitBytes, 64 * 1024);
      expect(adapter.sftpTextEditLimitBytes, 128 * 1024);
      expect(notifications, greaterThan(0));

      adapter.dispose();
      adapter.dispose();
      final before = notifications;
      await adapter.setRagTopN(9);
      expect(notifications, before);
    },
  );

  test('ssh adapter maps sessions and server overview snapshots', () {
    final service = _AiSshService()
      ..sessions = <legacy_ssh.SshSession>[
        _session(
          's1',
          state: legacy_ssh.SshConnectionState.connected,
          output: 'abcdefgh',
        ),
        _session('s2', state: legacy_ssh.SshConnectionState.connecting),
        _session('s3', state: legacy_ssh.SshConnectionState.error),
        _session('s4', state: legacy_ssh.SshConnectionState.disconnected),
      ]
      ..connected = true
      ..errorMessage = 'boom'
      ..overview = legacy_ssh.SshServerOverviewSnapshot(
        byConnection: <String, legacy_ssh.SshConnectionOverview>{
          'c1': legacy_ssh.SshConnectionOverview(
            count: 2,
            latestState: legacy_ssh.SshConnectionState.connected,
            hasConnected: true,
          ),
          'c2': legacy_ssh.SshConnectionOverview(
            count: 0,
            latestState: null,
            hasConnected: false,
          ),
        },
        windowCount: 4,
      );
    final adapter = AppAiSshAdapter(service);

    expect(adapter.isConnected, isTrue);
    expect(adapter.errorMessage, 'boom');
    final sessions = adapter.sessions;
    expect(sessions, hasLength(4));
    expect(sessions[0].id, 's1');
    expect(sessions[0].displayName, 'display-s1');
    expect(sessions[0].state, ai.AiSshConnectionState.connected);
    expect(sessions[0].isConnected, isTrue);
    expect(sessions[0].estimatedMemoryBytes, 16);
    expect(sessions[1].state, ai.AiSshConnectionState.connecting);
    expect(sessions[2].state, ai.AiSshConnectionState.error);
    expect(sessions[2].errorMessage, 'error-s3');
    expect(sessions[2].tmuxSessionName, 'tmux');
    expect(sessions[2].tmuxAutoDeleteSeconds, 30);
    expect(sessions[3].state, ai.AiSshConnectionState.disconnected);

    final overview = adapter.serverOverviewSnapshot;
    expect(overview.windowCount, 4);
    expect(overview.byConnection['c1']!.count, 2);
    expect(
      overview.byConnection['c1']!.latestState,
      ai.AiSshConnectionState.connected,
    );
    expect(overview.byConnection['c1']!.hasConnected, isTrue);
    expect(
      overview.byConnection['c2']!.latestState,
      ai.AiSshConnectionState.disconnected,
    );
  });

  test(
    'ssh adapter forwards session and terminal lifecycle operations',
    () async {
      final session = _session('s1');
      final service = _AiSshService()
        ..sessions = <legacy_ssh.SshSession>[session]
        ..sessionsById['s1'] = session
        ..renameResult = false
        ..openResult = 'o1'
        ..ensureResult = true
        ..hasConnectedResult = true
        ..latestSessionId = 's1'
        ..sessionCountResult = 3
        ..historyText = 'history'
        ..historyRecords = <TerminalHistoryRecord>[
          TerminalHistoryRecord(
            sessionId: 's1',
            connectionId: 'c1',
            connectionName: 'Server A',
            displayName: 'window',
            tmuxSessionName: 'tmux',
            state: 'connected',
            errorMessage: 'none',
            createdAt: DateTime.fromMillisecondsSinceEpoch(1),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(2),
          ),
        ]
        ..commandResult = const legacy_ssh.RemoteCommandResult(
          exitCode: 7,
          stdout: 'stdout',
          stderr: 'stderr',
        );
      final adapter = AppAiSshAdapter(service);

      expect(adapter.getSession('s1')!.id, 's1');
      expect(adapter.getSession('missing'), isNull);
      expect(adapter.latestSessionForConnection('c1')!.id, 's1');
      expect(adapter.latestSessionForConnection('missing'), isNull);
      expect(adapter.hasConnectedSession('c1'), isTrue);
      expect(adapter.sessionCountForConnection('c1'), 3);
      expect(await adapter.openSession('c1', displayName: 'D'), 'o1');
      expect(await adapter.ensureSessionConnected('s1', 'c1'), isTrue);
      expect(adapter.renameSession('s1', 'other'), isFalse);
      expect(await adapter.loadSessionHistoryText('s1'), 'history');
      await adapter.disconnectSession('s1');
      await adapter.disconnect();
      await adapter.disconnectSessionsForConnection('c1');
      await adapter.restoreTmuxSessions();

      expect(service.lastOpened?.connectionId, 'c1');
      expect(service.lastOpened?.displayName, 'D');
      expect(service.lastEnsured?.sessionId, 's1');
      expect(service.lastRenamed?.name, 'other');
      expect(service.lastHistoryRead, 's1');
      expect(service.disconnectedSessions, <String>['s1']);
      expect(service.disconnectCalls, 1);
      expect(service.lastDisconnectedConnection, 'c1');
      expect(service.restoreCalls, 1);

      final history = (await adapter.loadTerminalHistoryRecords()).single;
      expect(history.sessionId, 's1');
      expect(history.connectionName, 'Server A');
      expect(history.tmuxSessionName, 'tmux');
      expect(history.errorMessage, 'none');
      expect(history.updatedAt, DateTime.fromMillisecondsSinceEpoch(2));

      await adapter.removeTerminalHistoryRecord('s1');
      expect(service.lastRemovedHistory, 's1');

      final result = await adapter.runOneShotCommand(
        connectionId: 'c1',
        command: 'uname -a',
        timeout: const Duration(seconds: 3),
      );
      expect(result.exitCode, 7);
      expect(result.stdout, 'stdout');
      expect(result.stderr, 'stderr');
      expect(service.lastOneShot?.timeout, const Duration(seconds: 3));
    },
  );

  test('sftp adapter maps listings and forwards bounded mutations', () async {
    final service = FakeSftpService()
      ..listResult = <legacy_sftp.SftpEntry>[
        legacy_sftp.SftpEntry(
          connectionId: 'c1',
          targetFingerprint: 'fp',
          name: 'notes.txt',
          path: '/home/user/notes.txt',
          lowerName: 'notes.txt',
          isDirectory: false,
          isLink: true,
          size: 12,
          sizeLabel: '12 B',
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(3),
          modifiedLabel: 'now',
        ),
      ]
      ..statResult = legacy_sftp.SftpPathInfo(
        path: '/home/user',
        isDirectory: true,
        isLink: false,
        size: 0,
        sizeLabel: '0 B',
        modifiedAt: null,
      );
    final adapter = AppAiSftpAdapter(service);
    final bytes = Uint8List.fromList(<int>[1, 2]);

    final entries = await adapter.listDirectoryForConnection('c1', '/home');
    expect(entries.single.name, 'notes.txt');
    expect(entries.single.path, '/home/user/notes.txt');
    expect(entries.single.isDirectory, isFalse);
    expect(entries.single.isLink, isTrue);
    expect(entries.single.size, 12);
    expect(entries.single.modifiedLabel, 'now');

    final stat = await adapter.statPathForConnection(
      connectionId: 'c1',
      path: '/home/user',
    );
    expect(stat.path, '/home/user');
    expect(stat.isDirectory, isTrue);
    expect(stat.modifiedAt, isNull);
    expect(service.listedDirectories.single.path, '/home');
    expect(service.stats.single.path, '/home/user');

    expect(
      await adapter.readTextPathForConnection(connectionId: 'c1', path: '/a'),
      'text',
    );
    expect(
      await adapter.downloadPathForConnection(connectionId: 'c1', path: '/b'),
      <int>[1, 2, 3],
    );
    await adapter.writeTextPathForConnection(
      connectionId: 'c1',
      path: '/c',
      text: 'hello',
    );
    await adapter.uploadBytesPathForConnection(
      connectionId: 'c1',
      path: '/d',
      bytes: bytes,
    );
    await adapter.createDirectoryPathForConnection(
      connectionId: 'c1',
      path: '/dir',
    );
    await adapter.renamePathForConnection(
      connectionId: 'c1',
      path: '/old',
      newPath: '/new',
    );
    await adapter.deletePathForConnection(connectionId: 'c1', path: '/gone');

    expect(service.reads.single.maxBytes, 2 * 1024 * 1024);
    expect(service.downloads.single.maxBytes, 50 * 1024 * 1024);
    expect(service.writeTexts.single.maxBytes, 2 * 1024 * 1024);
    expect(service.byteUploads.single.maxBytes, 50 * 1024 * 1024);
    expect(service.createdDirectories.single.path, '/dir');
    expect(service.renames.single.newPath, '/new');
    expect(service.deletedPaths.single.path, '/gone');

    await adapter.readTextPathForConnection(
      connectionId: 'c1',
      path: '/a2',
      maxBytes: 100,
    );
    await adapter.downloadPathForConnection(
      connectionId: 'c1',
      path: '/b2',
      maxBytes: 200,
    );
    await adapter.writeTextPathForConnection(
      connectionId: 'c1',
      path: '/c2',
      text: 'x',
      maxBytes: 300,
    );
    await adapter.uploadBytesPathForConnection(
      connectionId: 'c1',
      path: '/d2',
      bytes: bytes,
      maxBytes: 400,
    );
    expect(service.reads.last.maxBytes, 100);
    expect(service.downloads.last.maxBytes, 200);
    expect(service.writeTexts.last.maxBytes, 300);
    expect(service.byteUploads.last.maxBytes, 400);
  });

  test('monitoring adapter forwards tool service results', () async {
    final service = _AiMonitoringService()
      ..selectedConnectionIds = <String>{'c1'}
      ..healthByConnection = <String, monitoring.ServerHealthSnapshot>{
        'c1': _health,
      }
      ..alerts = <monitoring.MonitorAlert>[_alert]
      ..visibleSamples = <monitoring.PerformanceSample>[_sample]
      ..samples = <monitoring.PerformanceSample>[_sample]
      ..ports = <monitoring.PortProcessSnapshot>[_port]
      ..applications = <monitoring.ApplicationMemorySnapshot>[_application];
    final adapter = AppAiMonitoringAdapter(service);

    expect(adapter.getState()['isRunning'], isFalse);
    final selected = adapter.setSelectedServers(<String>['c2']);
    expect(selected['selectedConnectionIds'], contains('c2'));
    expect(service.toggleCalls, 2);
    expect(adapter.clearSelection()['selectedConnectionIds'], isEmpty);
    expect(service.clearCalls, 1);

    expect((await adapter.start())['isRunning'], isTrue);
    expect(service.startCalls, 1);
    final targetResult = await adapter.startWithTargets(
      <String, ssh_core.SshTargetBinding>{
        'c1': ssh_core.SshTargetBinding.fromConfig(_config),
      },
    );
    expect(targetResult['isRunning'], isTrue);
    expect(service.targetStarts.single.keys, contains('c1'));
    expect(service.startCalls, 2);

    expect(adapter.stop()['isRunning'], isFalse);
    expect(adapter.stopForConnection('c1')['isRunning'], isFalse);
    expect(service.monitoringConnectionIds, isEmpty);
    expect(
      adapter.setInterval(const Duration(seconds: 5))['intervalSeconds'],
      5,
    );
    expect(
      adapter.setHistoryWindow(
        const Duration(minutes: 2),
      )['historyWindowSeconds'],
      120,
    );

    expect(adapter.getHealth()['health'], contains('c1'));
    final samples = adapter.getSamples('c1', visibleOnly: true, limit: 1);
    expect(samples['visibleOnly'], isTrue);
    expect(samples['limit'], 1);
    expect(samples['returned'], 1);
    expect(
      adapter.getSamples('c1', visibleOnly: false)['visibleOnly'],
      isFalse,
    );
    final alerts = adapter.getAlerts(limit: 1);
    expect(alerts['alerts'], hasLength(1));
    expect(alerts['limit'], 1);
    final ports = await adapter.getPorts('c1');
    expect(ports['ports'].single['port'], 22);
    final applications = await adapter.getApplications('c1');
    expect(applications['applications'].single['pid'], 42);
  });

  test('monitoring adapter dispatches query operations', () async {
    final service = _AiMonitoringService()
      ..healthByConnection = <String, monitoring.ServerHealthSnapshot>{
        'c1': _health,
      }
      ..alerts = <monitoring.MonitorAlert>[_alert]
      ..visibleSamples = <monitoring.PerformanceSample>[_sample]
      ..samples = <monitoring.PerformanceSample>[_sample]
      ..ports = <monitoring.PortProcessSnapshot>[_port]
      ..applications = <monitoring.ApplicationMemorySnapshot>[_application];
    final adapter = AppAiMonitoringAdapter(service);

    expect(
      await adapter.query(
        const app_core.MonitoringQuery(operation: ' getState '),
      ),
      containsPair('isRunning', false),
    );
    final health = await adapter.query(
      const app_core.MonitoringQuery(
        operation: 'getHealth',
        connectionId: 'c1',
        arguments: <String, dynamic>{
          'connectionIds': <String>['c1'],
        },
      ),
    );
    expect(health['health'], contains('c1'));
    expect(
      (await adapter.query(
        const app_core.MonitoringQuery(operation: 'getHealth'),
      ))['health'],
      contains('c1'),
    );

    final samples = await adapter.query(
      const app_core.MonitoringQuery(
        operation: 'getSamples',
        connectionId: 'c1',
        arguments: <String, dynamic>{'visibleOnly': false, 'limit': 1},
      ),
    );
    expect(samples['visibleOnly'], isFalse);
    expect(samples['limit'], 1);
    final defaultSamples = await adapter.query(
      const app_core.MonitoringQuery(operation: 'getSamples'),
    );
    expect(defaultSamples['visibleOnly'], isTrue);
    expect(defaultSamples['limit'], 100);
    expect(defaultSamples['returned'], 1);

    final alerts = await adapter.query(
      const app_core.MonitoringQuery(
        operation: 'getAlerts',
        arguments: <String, dynamic>{'limit': 1},
      ),
    );
    expect(alerts['alerts'], hasLength(1));
    expect(
      (await adapter.query(
        const app_core.MonitoringQuery(operation: 'getAlerts'),
      ))['limit'],
      50,
    );
    expect(
      (await adapter.query(
        const app_core.MonitoringQuery(operation: 'getPorts'),
      ))['connectionId'],
      '',
    );
    expect(
      (await adapter.query(
        const app_core.MonitoringQuery(operation: 'getApplications'),
      ))['connectionId'],
      '',
    );
    await expectLater(
      adapter.query(const app_core.MonitoringQuery(operation: 'unknown')),
      throwsArgumentError,
    );
  });
}

final _config = ConnectionConfig(
  id: 'c1',
  name: 'Server A',
  host: '10.0.0.1',
  username: 'root',
);

final _health = monitoring.ServerHealthSnapshot(
  connectionId: 'c1',
  level: monitoring.ServerHealthLevel.healthy,
  score: 100,
  summary: 'healthy',
  details: const <String>['ok'],
  updatedAt: DateTime.fromMillisecondsSinceEpoch(3),
);

final _sample = monitoring.PerformanceSample(
  connectionId: 'c1',
  time: DateTime.fromMillisecondsSinceEpoch(4),
  cpuPercent: 10,
  memoryPercent: 20,
  diskBytesPerSecond: 30,
  networkBytesPerSecond: 40,
);

final _alert = monitoring.MonitorAlert(
  id: 'a1',
  connectionId: 'c1',
  metric: 'cpu',
  level: monitoring.ServerHealthLevel.warning,
  message: 'cpu high',
  createdAt: DateTime.fromMillisecondsSinceEpoch(5),
);

final _port = monitoring.PortProcessSnapshot(
  protocol: 'tcp',
  localAddress: '0.0.0.0',
  port: 22,
  state: 'listen',
  process: 'sshd',
);

final _application = monitoring.ApplicationMemorySnapshot(
  pid: 42,
  command: 'sshd',
  rssBytes: 100,
  memoryPercent: 1,
  cpuPercent: 2,
);

legacy_ssh.SshSession _session(
  String id, {
  legacy_ssh.SshConnectionState state = legacy_ssh.SshConnectionState.connected,
  String output = '',
}) {
  final session = legacy_ssh.SshSession(
    id: id,
    connectionId: 'c1',
    connectionName: 'Server A',
    outputController: StreamController<String>.broadcast(),
    displayName: 'display-$id',
    tmuxSessionName: id == 's3' ? 'tmux' : null,
    tmuxAutoDeleteSeconds: id == 's3' ? 30 : null,
    state: state,
    errorMessage: state == legacy_ssh.SshConnectionState.error
        ? 'error-$id'
        : null,
    createdAt: DateTime.fromMillisecondsSinceEpoch(1),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(2),
  );
  if (output.isNotEmpty) session.addOutput(output);
  return session;
}

final class _AiSshService extends Fake implements legacy_ssh.SshService {
  @override
  List<legacy_ssh.SshSession> sessions = <legacy_ssh.SshSession>[];
  bool connected = false;
  legacy_ssh.SshServerOverviewSnapshot overview =
      const legacy_ssh.SshServerOverviewSnapshot.empty();
  @override
  bool get isConnected => connected;
  @override
  legacy_ssh.SshServerOverviewSnapshot get serverOverviewSnapshot => overview;
  @override
  String? errorMessage;
  final Map<String, legacy_ssh.SshSession> sessionsById =
      <String, legacy_ssh.SshSession>{};
  String historyText = 'history text';
  List<TerminalHistoryRecord> historyRecords = const [];
  bool renameResult = true, ensureResult = true, hasConnectedResult = true;
  String? latestSessionId;
  int sessionCountResult = 0;
  String? openResult = 'opened';
  legacy_ssh.RemoteCommandResult commandResult =
      const legacy_ssh.RemoteCommandResult(
        exitCode: 0,
        stdout: 'out',
        stderr: 'err',
      );
  ({String connectionId, String? displayName})? lastOpened;
  ({String sessionId, String connectionId})? lastEnsured;
  ({String sessionId, String name})? lastRenamed;
  String? lastHistoryRead;
  final List<String> disconnectedSessions = <String>[];
  int disconnectCalls = 0;
  String? lastDisconnectedConnection;
  int restoreCalls = 0;
  String? lastRemovedHistory;
  ({String connectionId, String command, Duration timeout})? lastOneShot;

  @override
  legacy_ssh.SshSession? getSession(String sessionId) =>
      sessionsById[sessionId];

  @override
  Future<String?> openSession(
    String connectionId, {
    String? displayName,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    lastOpened = (connectionId: connectionId, displayName: displayName);
    return openResult;
  }

  @override
  Future<bool> ensureSessionConnected(
    String sessionId,
    String connectionId,
  ) async {
    lastEnsured = (sessionId: sessionId, connectionId: connectionId);
    return ensureResult;
  }

  @override
  bool renameSession(String sessionId, String name) {
    lastRenamed = (sessionId: sessionId, name: name);
    return renameResult;
  }

  @override
  bool hasConnectedSession(String connectionId) => hasConnectedResult;

  @override
  legacy_ssh.SshSession? latestSessionForConnection(String connectionId) {
    if (connectionId != 'c1') return null;
    final latest = latestSessionId;
    return latest == null ? null : sessionsById[latest];
  }

  @override
  int sessionCountForConnection(String connectionId) => sessionCountResult;

  @override
  Future<String> loadSessionHistoryText(String sessionId) async {
    lastHistoryRead = sessionId;
    return historyText;
  }

  @override
  Future<void> disconnectSession(String sessionId) async =>
      disconnectedSessions.add(sessionId);

  @override
  Future<void> disconnect() async => disconnectCalls++;

  @override
  Future<void> disconnectSessionsForConnection(String connectionId) async =>
      lastDisconnectedConnection = connectionId;

  @override
  Future<void> restoreTmuxSessions() async => restoreCalls++;

  @override
  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords() async =>
      List<TerminalHistoryRecord>.of(historyRecords);

  @override
  Future<void> removeTerminalHistoryRecord(String sessionId) async =>
      lastRemovedHistory = sessionId;

  @override
  Future<legacy_ssh.RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    lastOneShot = (
      connectionId: connectionId,
      command: command,
      timeout: timeout,
    );
    return commandResult;
  }
}

final class _AiMonitoringService extends Fake
    implements monitoring.MonitoringService {
  @override
  bool isRunning = false, isSampling = false;
  @override
  Duration interval = const Duration(seconds: 10),
      effectiveInterval = const Duration(seconds: 10),
      historyWindow = const Duration(minutes: 5);
  @override
  DateTime? startedAt;
  @override
  Set<String> selectedConnectionIds = <String>{};
  @override
  Set<String> monitoringConnectionIds = <String>{};
  @override
  Map<String, String> errorsByConnection = const {};
  @override
  Map<String, monitoring.ServerHealthSnapshot> healthByConnection = const {};
  @override
  List<monitoring.MonitorAlert> alerts = const [];
  List<monitoring.PerformanceSample> visibleSamples = const [],
      samples = const [];
  List<monitoring.PortProcessSnapshot> ports = const [];
  List<monitoring.ApplicationMemorySnapshot> applications = const [];
  final List<Map<String, ssh_core.SshTargetBinding>> targetStarts =
      <Map<String, ssh_core.SshTargetBinding>>[];
  int clearCalls = 0, startCalls = 0, toggleCalls = 0;

  @override
  monitoring.ServerHealthSnapshot healthFor(String connectionId) =>
      healthByConnection[connectionId]!;

  @override
  List<monitoring.PerformanceSample> visibleSamplesFor(String connectionId) =>
      visibleSamples;

  @override
  List<monitoring.PerformanceSample> samplesFor(String connectionId) => samples;

  @override
  void toggleSelection(String connectionId) {
    toggleCalls++;
    if (isRunning) return;
    if (!selectedConnectionIds.remove(connectionId)) {
      selectedConnectionIds.add(connectionId);
    }
  }

  @override
  void clearSelection() {
    clearCalls++;
    selectedConnectionIds.clear();
  }

  @override
  Future<void> startMonitoring({
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    Map<String, ssh_core.SshTargetBinding>? targetBindings,
  }) async {
    startCalls++;
    if (targetBindings != null) targetStarts.add(targetBindings);
    isRunning = true;
    startedAt = DateTime.fromMillisecondsSinceEpoch(1);
    monitoringConnectionIds.addAll(selectedConnectionIds);
  }

  @override
  void stopMonitoring() {
    isRunning = false;
    startedAt = null;
    monitoringConnectionIds.clear();
  }

  @override
  void stopForConnection(String connectionId) {
    selectedConnectionIds.remove(connectionId);
    monitoringConnectionIds.remove(connectionId);
  }

  @override
  void setInterval(Duration value) => interval = value;

  @override
  void setHistoryWindow(Duration value) => historyWindow = value;

  @override
  Future<List<monitoring.PortProcessSnapshot>> fetchPorts(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async => ports;

  @override
  Future<List<monitoring.ApplicationMemorySnapshot>> fetchApplications(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async => applications;
}
