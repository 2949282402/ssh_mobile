/// 模块依赖审计使用的层级、边和报告模型。
///
/// 这些类型与 CLI 审计器分离，便于回归测试和后续文档工具复用，而不复制
/// workspace 依赖解析逻辑。

/// Workspace Package 所处的架构层级。
enum ModuleLayer { app, core, feature, infrastructure, unknown }

extension ModuleLayerLabel on ModuleLayer {
  /// 返回稳定的报告标签，避免把层级名称散落在审计输出中。
  String get label => switch (this) {
    ModuleLayer.app => 'App',
    ModuleLayer.core => 'Core',
    ModuleLayer.feature => 'Feature',
    ModuleLayer.infrastructure => 'Infrastructure',
    ModuleLayer.unknown => 'Unknown',
  };
}

/// 根 workspace 中一个可独立验证的 Package。
final class WorkspacePackage {
  const WorkspacePackage({
    required this.name,
    required this.relativePath,
    required this.layer,
    required this.productionDependencies,
  });

  final String name;
  final String relativePath;
  final ModuleLayer layer;
  final Set<String> productionDependencies;
}

/// 一条 Package 到另一个 workspace Package 的直接生产依赖边。
final class ModuleDependencyEdge {
  const ModuleDependencyEdge({required this.source, required this.target});

  final WorkspacePackage source;
  final WorkspacePackage target;

  @override
  String toString() => '${source.name} -> ${target.name}';
}

/// 一条依赖审计违规。
final class ModuleDependencyViolation {
  const ModuleDependencyViolation({
    required this.rule,
    required this.source,
    required this.target,
    required this.message,
  });

  final String rule;
  final String source;
  final String target;
  final String message;

  @override
  String toString() =>
      '[$rule] $source${target.isEmpty ? '' : ' -> $target'} $message';
}

/// 依赖审计的完整结果，供 CLI、测试和架构文档生成使用。
final class ModuleDependencyReport {
  const ModuleDependencyReport({
    required this.packages,
    required this.edges,
    required this.violations,
  });

  final List<WorkspacePackage> packages;
  final List<ModuleDependencyEdge> edges;
  final List<ModuleDependencyViolation> violations;

  bool get isValid => violations.isEmpty;
  int get internalDependencyCount => edges.length;
}
