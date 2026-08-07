part of 'ai_tool_service_test.dart';

void _registerAiToolSkillTests() {
  group('AI Experience Skills tools management', () {
    test(
      'client_save_experience_skill, client_list_skills, and client_update_skill tools CRUD flow',
      () async {
        final rawSave = await tools.execute('client_save_experience_skill', {
          'summary': 'Short summary rule of deployment',
          'title': 'Deploy Skill',
          'content': 'Check server state first',
          'references': [
            {'title': 'Nginx restart', 'content': 'systemctl restart nginx'},
            {'title': 'Service check', 'content': 'systemctl status nginx'},
          ],
        }, approvedWrite: true);
        final decodedSave = jsonDecode(rawSave) as Map<String, dynamic>;
        expect(decodedSave['saved'], isTrue);
        final skillId = decodedSave['skillId'] as String;

        final savedSkills = await storage.loadAiSkills();
        expect(savedSkills, hasLength(1));
        final skill = savedSkills.first;
        expect(skill.id, skillId);
        expect(skill.name, 'Deploy Skill');
        expect(skill.references, hasLength(2));
        expect(skill.references[0].title, equals('Nginx restart'));
        expect(skill.references[0].content, equals('systemctl restart nginx'));

        final rawList = await tools.execute('client_list_skills', {});
        final decodedList = jsonDecode(rawList) as Map<String, dynamic>;
        final skillItems = decodedList['skills'] as List<dynamic>;
        expect(skillItems, hasLength(1));
        expect(skillItems.first['id'], skillId);

        final rawUpdate = await tools.execute('client_update_skill', {
          'skillId': skillId,
          'name': 'Updated Deploy Title',
          'enabled': false,
          'references': [
            {
              'title': 'New backup step',
              'content': 'tar -czf backup.tar.gz /var/www',
            },
          ],
        }, approvedWrite: true);
        final decodedUpdate = jsonDecode(rawUpdate) as Map<String, dynamic>;
        expect(decodedUpdate['updated'], isTrue);

        final updatedSkills = await storage.loadAiSkills();
        expect(updatedSkills, hasLength(1));
        final updatedSkill = updatedSkills.first;
        expect(updatedSkill.name, 'Updated Deploy Title');
        expect(updatedSkill.enabled, isFalse);
        expect(updatedSkill.references, hasLength(1));
        expect(updatedSkill.references.first.title, equals('New backup step'));
      },
    );
  });

  test(
    'sftp write approval request includes path, bytes, and preview',
    () async {
      final request = await tools.approvalRequestFor('sftp_write_text', {
        'connectionId': 'server-1',
        'path': '/etc/nginx/nginx.conf',
        'content': 'worker_processes auto;',
      });

      expect(request, isNotNull);
      expect(request!.command, 'SFTP WRITE /etc/nginx/nginx.conf (22 bytes)');
      expect(request.targetPath, '/etc/nginx/nginx.conf');
      expect(request.byteLength, 22);
      expect(request.contentPreview, 'worker_processes auto;');
    },
  );

  test(
    'ssh session and terminal history tools require approval metadata',
    () async {
      final openRequest = await tools.approvalRequestFor('ssh_open_session', {
        'connectionId': 'server-1',
        'displayName': 'Ops Shell',
      });
      final closeAllRequest = await tools.approvalRequestFor(
        'ssh_close_server_sessions',
        {'connectionId': 'server-1'},
      );
      final restoreRequest = await tools.approvalRequestFor(
        'ssh_restore_tmux_sessions',
        {},
      );
      final deleteHistoryRequest = await tools.approvalRequestFor(
        'ssh_delete_terminal_history_record',
        {'sessionId': 'session-1'},
      );

      expect(openRequest, isNotNull);
      expect(openRequest!.approvalType, 'ssh_session_change');
      expect(openRequest.contentPreview, 'Ops Shell');
      expect(closeAllRequest, isNotNull);
      expect(closeAllRequest!.approvalType, 'ssh_session_change');
      expect(restoreRequest, isNotNull);
      expect(restoreRequest!.approvalType, 'ssh_session_change');
      expect(deleteHistoryRequest, isNotNull);
      expect(deleteHistoryRequest!.approvalType, 'terminal_history_change');
      expect(deleteHistoryRequest.destructive, isTrue);
    },
  );

  test('ssh session tool refuses execution without approval', () async {
    final raw = await tools.execute('ssh_open_session', {
      'connectionId': 'server-1',
    });
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['error'], contains('requires user approval'));
  });

  test('SSH reconnect validates approval and session ownership', () async {
    final session = SshSession(
      id: 'session-1',
      connectionId: 'server-1',
      connectionName: 'Demo Server',
      displayName: 'Ops Shell',
      outputController: StreamController<String>.broadcast(),
      state: SshConnectionState.disconnected,
    );
    addTearDown(session.close);
    final fakeSsh = _FakeSshClient(session);
    final guardedTools = _buildTools(
      storage: storage,
      ssh: fakeSsh,
      sftp: sftp,
      clientSystem: clientSystem,
      clientWebView: clientWebView,
      serverCatalog: serverCatalog,
      performanceMonitor: performanceMonitor,
      diagnostics: diagnostics,
      appSettings: appSettings,
      chatId: 'chat-1',
    );
    final arguments = {
      'sessionId': session.id,
      'connectionId': session.connectionId,
    };

    final request = await guardedTools.approvalRequestFor(
      'ssh_ensure_session_connected',
      arguments,
    );
    expect(request, isNotNull);
    expect(request!.approvalType, 'ssh_session_change');
    expect(request.executionBinding?.connectionTargets, contains('server-1'));

    final unapproved =
        jsonDecode(
              await guardedTools.execute(
                'ssh_ensure_session_connected',
                arguments,
              ),
            )
            as Map<String, dynamic>;
    expect(unapproved['error'], contains('requires user approval'));
    expect(fakeSsh.ensureCalls, 0);

    final approved =
        jsonDecode(await guardedTools.executeApproved(request, arguments))
            as Map<String, dynamic>;
    expect(approved['connected'], isTrue);
    expect(fakeSsh.ensureCalls, 1);

    final changedSession =
        jsonDecode(
              await guardedTools.executeApproved(request, {
                'sessionId': 'session-2',
                'connectionId': session.connectionId,
              }),
            )
            as Map<String, dynamic>;
    expect(changedSession['code'], 'approval_target_changed');
    expect(fakeSsh.ensureCalls, 1);

    final mismatch =
        jsonDecode(
              await guardedTools.execute('ssh_ensure_session_connected', {
                'sessionId': session.id,
                'connectionId': 'different-server',
              }, approvedWrite: true),
            )
            as Map<String, dynamic>;
    expect(mismatch['code'], 'session_connection_mismatch');
    expect(fakeSsh.ensureCalls, 1);
  });

  test('blocks secret-bearing SFTP paths before read', () async {
    final raw = await tools.execute('sftp_read_text', {
      'connectionId': 'server-1',
      'path': '/home/demo/.ssh/id_rsa',
    });
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['blockedBy'], 'tool_secret_policy');
    expect(decoded['error'], contains('secret policy'));
  });

  test('sftp read approval request includes remote read metadata', () async {
    final request = await tools.approvalRequestFor('sftp_read_text', {
      'connectionId': 'server-1',
      'path': '/tmp/demo.txt',
    });

    expect(request, isNotNull);
    expect(request!.approvalType, 'remote_read');
    expect(request.command, 'SFTP READ /tmp/demo.txt');
    expect(request.targetPath, '/tmp/demo.txt');
  });

  test('sftp read requires approval before execution', () async {
    final raw = await tools.execute('sftp_read_text', {
      'connectionId': 'server-1',
      'path': '/tmp/demo.txt',
    });
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['error'], contains('requires user approval'));
  });

  test('sftp write requires approval before execution', () async {
    final raw = await tools.execute('sftp_write_text', {
      'connectionId': 'server-1',
      'path': '/tmp/demo.txt',
      'content': 'abcd',
    });
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['error'], contains('requires user approval'));
    expect(sftp.lastWritePath, isNull);
  });

  test(
    'sftp write executes after approval and uses app settings limit',
    () async {
      final raw = await tools.execute('sftp_write_text', {
        'connectionId': 'server-1',
        'path': '/tmp/demo.txt',
        'content': 'abcd',
      }, approvedWrite: true);
      final decoded = jsonDecode(raw) as Map<String, dynamic>;

      expect(decoded['written'], isTrue);
      expect(decoded['bytes'], 4);
      expect(sftp.lastWriteConnectionId, 'server-1');
      expect(sftp.lastWritePath, '/tmp/demo.txt');
      expect(sftp.lastWriteText, 'abcd');
      expect(sftp.lastWriteMaxBytes, AppSettings.minSftpLimitBytes);
    },
  );

  test('sftp write fails when content exceeds the edit limit', () async {
    final oversizedText = 'a' * (AppSettings.minSftpLimitBytes + 1);
    await expectLater(
      () => tools.execute('sftp_write_text', {
        'connectionId': 'server-1',
        'path': '/tmp/demo.txt',
        'content': oversizedText,
      }, approvedWrite: true),
      throwsA(isA<StateError>()),
    );
  });

  test('sftp download saves file metadata on the client device', () async {
    final raw = await tools.execute('sftp_download_file', {
      'connectionId': 'server-1',
      'path': '/var/log/app.log',
    }, approvedWrite: true);
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(sftp.lastDownloadConnectionId, 'server-1');
    expect(sftp.lastDownloadPath, '/var/log/app.log');
    expect(sftp.lastDownloadMaxBytes, AppSettings.minSftpLimitBytes);
    expect(clientSystem.lastSavedFileName, 'app.log');
    expect(decoded['saved'], isTrue);
    expect(decoded['remotePath'], '/var/log/app.log');
  });

  test('tool result redacts secret-like output content', () async {
    sftp.readTextResult = 'password=supersecret';

    final raw = await tools.execute('sftp_read_text', {
      'connectionId': 'server-1',
      'path': '/tmp/demo.txt',
    }, approvedWrite: true);
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['content'], contains('[REDACTED]'));
    expect(decoded['content'], isNot(contains('supersecret')));
  });

  test('sftp download treats user cancel as a normal result', () async {
    clientSystem.cancelNextSave = true;

    final raw = await tools.execute('sftp_download_file', {
      'connectionId': 'server-1',
      'path': '/var/log/app.log',
    }, approvedWrite: true);
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['saved'], isFalse);
    expect(decoded['cancelled'], isTrue);
    expect(decoded['note'], contains('cancelled'));
  });

  test('sftp download fails when detached transfer exceeds limit', () async {
    sftp.downloadBytes = Uint8List.fromList(
      List<int>.filled(AppSettings.minSftpLimitBytes + 1, 1),
    );

    await expectLater(
      () => tools.execute('sftp_download_file', {
        'connectionId': 'server-1',
        'path': '/var/log/app.log',
      }, approvedWrite: true),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'server status and ops report keep their public names and delegate',
    () async {
      final statusRaw = await tools.execute('get_server_status', {
        'connectionId': 'server-1',
        'mode': 'performance',
      });
      final reportRaw = await tools.execute('generate_ops_report', {
        'connectionId': 'server-1',
      });
      final status = jsonDecode(statusRaw) as Map<String, dynamic>;
      final report = jsonDecode(reportRaw) as Map<String, dynamic>;

      expect(diagnostics.lastStatusConnectionId, 'server-1');
      expect(diagnostics.lastStatusMode, 'performance');
      expect(status['performance']['memoryPercent'], 32.0);
      expect(diagnostics.lastReportConnectionId, 'server-1');
      expect(report['health']['level'], 'healthy');
    },
  );

  test('composite diagnostic tools return structured JSON payloads', () async {
    final incidentRaw = await tools.execute('collect_incident_context', {
      'connectionId': 'server-1',
      'focus': 'nginx',
      'path': '/var/log/nginx/error.log',
    });
    final compareRaw = await tools.execute('compare_server_states', {
      'connectionIds': ['server-1', 'server-1'],
      'mode': 'performance',
    });

    final incident = jsonDecode(incidentRaw) as Map<String, dynamic>;
    final compare = jsonDecode(compareRaw) as Map<String, dynamic>;

    expect(incident['focus'], 'nginx');
    expect(incident['pathContext'], isNotNull);
    expect(compare['compared'], 2);
    expect(compare['mode'], 'performance');
  });

  test('server detail tool uses the injected server catalog adapter', () async {
    final raw = await tools.execute('get_server_details', {
      'connectionId': 'server-1',
    });
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(serverCatalog.lastDetailsConnectionId, 'server-1');
    expect((decoded['server'] as Map<String, dynamic>)['name'], 'Demo Server');
  });

  test('monitor state tool uses the injected monitor adapter', () async {
    final raw = await tools.execute('monitor_get_state', {});
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['isRunning'], isFalse);
    expect(performanceMonitor.getStateCalled, isTrue);
  });

  test('app settings tool does not expose API key material', () async {
    final raw = await tools.execute('app_get_operational_settings', {});
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded.containsKey('activeApiKeyMasked'), isFalse);
    expect(decoded.containsKey('apiKey'), isFalse);
    expect(decoded.containsKey('hasApiKeyConfigured'), isTrue);
    expect(decoded['multiAgentEnabled'], isTrue);
    expect(decoded['multiAgentMaxAgents'], 3);
    expect(decoded['postToolReviewEnabled'], isTrue);
    expect(decoded['toolCallBudget'], 20);
  });

  test(
    'app settings tool updates postToolReviewEnabled setting with approval',
    () async {
      final raw = await tools.execute('app_update_operational_settings', {
        'postToolReviewEnabled': false,
      }, approvedWrite: true);
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final settings = await storage.loadAiConnectionSettings();

      expect(decoded['postToolReviewEnabled'], isFalse);
      expect(settings.postToolReviewEnabled, isFalse);
    },
  );

  test(
    'app settings tool updates multi-agent settings with approval',
    () async {
      final raw = await tools.execute('app_update_operational_settings', {
        'multiAgentEnabled': false,
        'multiAgentMaxAgents': 4,
        'toolCallBudget': 40,
      }, approvedWrite: true);
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final settings = await storage.loadAiConnectionSettings();

      expect(decoded['multiAgentEnabled'], isFalse);
      expect(decoded['multiAgentMaxAgents'], 4);
      expect(decoded['toolCallBudget'], 40);
      expect(settings.multiAgentEnabled, isFalse);
      expect(settings.multiAgentMaxAgents, 4);
      expect(settings.toolCallBudget, 40);
    },
  );
}
