import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/llm_chat_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  late StorageService storage;
  late SshService ssh;
  late SftpService sftp;
  late AiToolService tools;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
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

  test('core services expose injectable contracts', () {
    final llm = LlmChatService(
      storageService: storage,
      toolService: tools,
    );

    expect(storage, isA<AiChatRepository>());
    expect(storage, isA<AiSkillRepository>());
    expect(storage, isA<TerminalHistoryRepository>());
    expect(storage, isA<AppBackupRepository>());
    expect(ssh, isA<SshClientAdapter>());
    expect(sftp, isA<SftpClientAdapter>());
    expect(tools, isA<AiToolExecutor>());
    expect(llm, isA<LlmClientAdapter>());
  });
}
