import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/models/connection.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storage;
  late SshService ssh;
  late SftpService sftp;
  late AiToolService tools;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storage = StorageService();
    ssh = SshService(storage);
    sftp = SftpService(storage);
    tools = AiToolService(
      storageService: storage,
      sshService: ssh,
      sftpService: sftp,
    );
  });

  tearDown(() {
    sftp.dispose();
    ssh.dispose();
    storage.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test('allows Linux read-only diagnostics', () {
    final review = tools.reviewCommand(
      'df -h',
      platform: ServerPlatform.linux,
    );

    expect(review.blocked, isFalse);
    expect(review.requiresApproval, isFalse);
  });

  test('requires approval for Linux command chaining', () {
    final review = tools.reviewCommand(
      'cat /etc/os-release | grep PRETTY',
      platform: ServerPlatform.linux,
    );

    expect(review.blocked, isFalse);
    expect(review.requiresApproval, isTrue);
  });

  test('blocks delete-style commands on all platforms', () {
    final linux = tools.reviewCommand(
      'rm -rf /tmp/demo',
      platform: ServerPlatform.linux,
    );
    final windows = tools.reviewCommand(
      'powershell Remove-Item C:\\temp\\demo -Recurse',
      platform: ServerPlatform.windows,
    );

    expect(linux.blocked, isTrue);
    expect(windows.blocked, isTrue);
  });

  test('blocks cross-platform command mismatch', () {
    final review = tools.reviewCommand(
      'cmd /c dir',
      platform: ServerPlatform.linux,
    );

    expect(review.blocked, isTrue);
    expect(review.reason, contains('Windows command'));
  });

  test('requires explicit shell prefix for Windows commands', () {
    final review = tools.reviewCommand(
      'dir',
      platform: ServerPlatform.windows,
    );

    expect(review.blocked, isTrue);
    expect(review.reason, contains('explicit'));
  });

  test('exposes local web search by default', () async {
    await storage.init();

    final names = (await tools.tools()).map((tool) => tool.name);

    expect(names, contains('web_search'));
  });

  test('hides local web search when disabled by the user', () async {
    await storage.init();
    await storage.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      webSearchEnabled: false,
    );

    final names = (await tools.tools()).map((tool) => tool.name);

    expect(names, isNot(contains('web_search')));
  });

  test('local web search reports missing chat session', () async {
    await storage.init();

    final raw = await tools.execute('web_search', {'query': 'flutter'});
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['provider'], 'local_webview');
    expect(decoded['error'], contains('No current chat session'));
  });
}
