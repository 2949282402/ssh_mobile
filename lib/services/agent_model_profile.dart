enum AgentModelRole {
  main,
  helper,
  audit,
}

class AgentModelFallbackPolicy {
  static const String fallbackToMain = 'fallback_to_main';
  static const String mainOnly = 'main_only';

  static const String defaultValue = fallbackToMain;
  static const List<String> values = [
    fallbackToMain,
    mainOnly,
  ];

  static String normalize(String? value) {
    final normalized = value?.trim().toLowerCase();
    return values.contains(normalized) ? normalized! : defaultValue;
  }
}

class AgentModelProfile {
  final String mainModel;
  final String helperModel;
  final String auditModel;
  final String fallbackPolicy;

  const AgentModelProfile({
    required this.mainModel,
    this.helperModel = '',
    this.auditModel = '',
    this.fallbackPolicy = AgentModelFallbackPolicy.defaultValue,
  });

  bool get usesSingleModel =>
      AgentModelFallbackPolicy.normalize(fallbackPolicy) ==
      AgentModelFallbackPolicy.mainOnly;

  String resolve(AgentModelRole role) {
    final normalizedMain = mainModel.trim();
    final normalizedHelper = helperModel.trim();
    final normalizedAudit = auditModel.trim();
    final policy = AgentModelFallbackPolicy.normalize(fallbackPolicy);

    if (policy == AgentModelFallbackPolicy.mainOnly) {
      return normalizedMain;
    }

    switch (role) {
      case AgentModelRole.main:
        return normalizedMain;
      case AgentModelRole.helper:
        return normalizedHelper.isNotEmpty ? normalizedHelper : normalizedMain;
      case AgentModelRole.audit:
        return normalizedAudit.isNotEmpty ? normalizedAudit : normalizedMain;
    }
  }
}
