part of 'ai_tool_service_test.dart';

void _registerAiToolConnectionTests() {
  group('client_update_skill approval and security flow', () {
    test(
      'requires approval before execution and succeeds after approved',
      () async {
        final now = DateTime.now();
        final skill = AiSkillRecord(
          id: 'skill-test-1',
          name: 'Original Name',
          description: 'Original Desc',
          content: 'Original Content',
          enabled: true,
          createdAt: now,
          updatedAt: now,
        );
        await storage.saveAiSkill(skill);

        // 1. 验证 approvalRequestFor 能生成正确的 local_skill_change 请求
        final request = await tools.approvalRequestFor('client_update_skill', {
          'skillId': 'skill-test-1',
          'name': 'Updated Name',
          'description': 'Updated Desc',
        });
        expect(request, isNotNull);
        expect(request!.approvalType, equals('local_skill_change'));
        expect(request.connectionName, contains('client'));
        expect(request.contentPreview, contains('Updated Name'));

        // 2. 未通过审批执行，应当返回报错
        final rawBlocked = await tools.execute('client_update_skill', {
          'skillId': 'skill-test-1',
          'name': 'Updated Name',
        });
        final decodedBlocked = jsonDecode(rawBlocked) as Map<String, dynamic>;
        expect(decodedBlocked['error'], contains('requires user approval'));

        // 3. 审批通过后执行，应当修改成功
        final rawSuccess = await tools.execute('client_update_skill', {
          'skillId': 'skill-test-1',
          'name': 'Updated Name',
        }, approvedWrite: true);
        final decodedSuccess = jsonDecode(rawSuccess) as Map<String, dynamic>;
        expect(decodedSuccess['updated'], isTrue);

        final updated = (await storage.loadAiSkills()).firstWhere(
          (s) => s.id == 'skill-test-1',
        );
        expect(updated.name, equals('Updated Name'));

        // 4. 验证 client_save_experience_skill 也需要审批且未审批报错
        final saveRequest = await tools.approvalRequestFor(
          'client_save_experience_skill',
          {'summary': 'New Exp Summary', 'content': 'Details here'},
        );
        expect(saveRequest, isNotNull);
        expect(saveRequest!.approvalType, equals('local_skill_change'));
        expect(saveRequest.contentPreview, contains('New Exp Summary'));

        final rawSaveBlocked = await tools.execute(
          'client_save_experience_skill',
          {'summary': 'New Exp Summary'},
        );
        expect(
          jsonDecode(rawSaveBlocked)['error'],
          contains('requires user approval'),
        );

        final rawSaveSuccess = await tools.execute(
          'client_save_experience_skill',
          {'summary': 'New Exp Summary'},
          approvedWrite: true,
        );
        expect(jsonDecode(rawSaveSuccess)['saved'], isTrue);

        // 5. 验证 client_list_skills 仍然不需要审批
        final rawList = await tools.execute('client_list_skills', {});
        expect(jsonDecode(rawList)['skills'], isNotNull);
      },
    );

    test(
      'client_save_experience_skill approval preview redacts secrets',
      () async {
        final request = await tools.approvalRequestFor(
          'client_save_experience_skill',
          {
            'summary': 'Add password config',
            'content':
                'Use secret admin password: "my-super-secret-password-123" to login, and check Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ token.',
          },
        );

        expect(request, isNotNull);
        expect(
          request!.contentPreview,
          isNot(contains('my-super-secret-password-123')),
        );
        expect(
          request.contentPreview,
          isNot(contains('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9')),
        );
        expect(request.contentPreview, contains('password=[REDACTED]'));
      },
    );

    test(
      'approved skill update does not overwrite a concurrent edit',
      () async {
        final now = DateTime.now();
        final original = AiSkillRecord(
          id: 'skill-cas',
          name: 'Original',
          description: 'Original description',
          content: 'Original content',
          createdAt: now,
          updatedAt: now,
        );
        await storage.saveAiSkill(original);
        final arguments = <String, dynamic>{
          'skillId': original.id,
          'name': 'AI approved name',
        };
        final request = await tools.approvalRequestFor(
          'client_update_skill',
          arguments,
        );
        expect(request, isNotNull);

        await storage.saveAiSkill(
          original.copyWith(
            name: 'User edit',
            updatedAt: now.add(const Duration(seconds: 1)),
          ),
        );
        final result =
            jsonDecode(await tools.executeApproved(request!, arguments))
                as Map<String, dynamic>;

        expect(result['code'], 'approval_target_changed');
        final persisted = (await storage.loadAiSkills()).singleWhere(
          (skill) => skill.id == original.id,
        );
        expect(persisted.name, 'User edit');
      },
    );
  });

  group('needsServerSelection tools connectionId boundary check tests', () {
    test(
      'server tool without connectionId returns connection_required',
      () async {
        final raw = await tools.execute('get_server_details', {});
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        expect(
          decoded['error'],
          contains('requires a selected server connection'),
        );
        expect(decoded['code'], 'connection_required');
        expect(decoded['tool'], 'get_server_details');
      },
    );

    test(
      'sftp write without connectionId returns connection_required',
      () async {
        final raw = await tools.execute('sftp_write_text', {
          'path': '/tmp/test.txt',
          'content': 'hello',
        });
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        expect(
          decoded['error'],
          contains('requires a selected server connection'),
        );
        expect(decoded['code'], 'connection_required');
        expect(decoded['tool'], 'sftp_write_text');
      },
    );

    test(
      'ssh run_command without connectionId returns connection_required',
      () async {
        final raw = await tools.execute('run_command', {'command': 'ls -la'});
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        expect(
          decoded['error'],
          contains('requires a selected server connection'),
        );
        expect(decoded['code'], 'connection_required');
        expect(decoded['tool'], 'run_command');
      },
    );

    test(
      'ssh run_command with local connectionId returns connection_required',
      () async {
        final raw = await tools.execute('run_command', {
          'connectionId': 'local',
          'command': 'ls -la',
        });
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        expect(
          decoded['error'],
          contains('requires a selected server connection'),
        );
        expect(decoded['code'], 'connection_required');
        expect(decoded['tool'], 'run_command');
      },
    );

    test('monitor汇总工具不需要选中服务器连接就可以执行', () async {
      // monitor_get_state
      final rawState = await tools.execute('monitor_get_state', {});
      final decodedState = jsonDecode(rawState) as Map<String, dynamic>;
      expect(decodedState['error'], isNull);

      // monitor_get_health
      final rawHealth = await tools.execute('monitor_get_health', {});
      final decodedHealth = jsonDecode(rawHealth) as Map<String, dynamic>;
      expect(decodedHealth['error'], isNull);

      // monitor_get_alerts
      final rawAlerts = await tools.execute('monitor_get_alerts', {});
      final decodedAlerts = jsonDecode(rawAlerts) as Map<String, dynamic>;
      expect(decodedAlerts['error'], isNull);
    });

    test('其他monitor工具和停止监视工具依然必须有服务器连接', () async {
      final toolsToTest = [
        'monitor_get_samples',
        'monitor_get_ports',
        'monitor_get_applications',
        'monitor_stop_for_connection',
      ];
      for (final toolName in toolsToTest) {
        final raw = await tools.execute(toolName, {});
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        expect(
          decoded['error'],
          contains('requires a selected server connection'),
          reason: 'Tool $toolName should require a server connection.',
        );
        expect(
          decoded['code'],
          'connection_required',
          reason: 'Tool $toolName should fail with connection_required.',
        );
      }
    });
  });
}
