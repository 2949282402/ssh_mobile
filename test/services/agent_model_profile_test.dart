import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/agent_model_profile.dart';

void main() {
  group('AgentModelProfile', () {
    test('falls back helper and audit roles to the main model by default', () {
      const profile = AgentModelProfile(
        mainModel: 'gpt-main',
      );

      expect(profile.usesSingleModel, isFalse);
      expect(profile.resolve(AgentModelRole.main), 'gpt-main');
      expect(profile.resolve(AgentModelRole.helper), 'gpt-main');
      expect(profile.resolve(AgentModelRole.audit), 'gpt-main');
    });

    test('uses dedicated helper and audit models when configured', () {
      const profile = AgentModelProfile(
        mainModel: 'gpt-main',
        helperModel: 'gpt-helper',
        auditModel: 'gpt-audit',
      );

      expect(profile.resolve(AgentModelRole.helper), 'gpt-helper');
      expect(profile.resolve(AgentModelRole.audit), 'gpt-audit');
    });

    test('forces every role onto the main model in main-only mode', () {
      const profile = AgentModelProfile(
        mainModel: 'gpt-main',
        helperModel: 'gpt-helper',
        auditModel: 'gpt-audit',
        fallbackPolicy: AgentModelFallbackPolicy.mainOnly,
      );

      expect(profile.usesSingleModel, isTrue);
      expect(profile.resolve(AgentModelRole.main), 'gpt-main');
      expect(profile.resolve(AgentModelRole.helper), 'gpt-main');
      expect(profile.resolve(AgentModelRole.audit), 'gpt-main');
    });
  });
}
