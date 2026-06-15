part of '../playbook_screen.dart';

class _PlaybookStrings {
  final AppLanguage language;

  const _PlaybookStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get title => _en ? 'Playbook Orchestrator' : '运维剧本与AI编排';
  String get newPlaybook => _en ? 'New Playbook' : '新建剧本';
  String get editPlaybook => _en ? 'Edit Playbook' : '编辑剧本';
  String get playbooksList => _en ? 'Playbooks' : '剧本列表';
  String get execution => _en ? 'Execution' : '执行控制';
  String get save => _en ? 'Save' : '保存';
  String get cancel => _en ? 'Cancel' : '取消';
  String get delete => _en ? 'Delete' : '删除';
  String get deletePlaybook => _en ? 'Delete Playbook' : '删除剧本';
  String deletePlaybookContent(String name) =>
      _en ? 'Are you sure you want to delete "$name"?' : '确定要删除剧本 "$name" 吗？';

  String get name => _en ? 'Playbook Name' : '剧本名称';
  String get description => _en ? 'Playbook Description' : '剧本描述';
  String get steps => _en ? 'Steps' : '执行步骤';
  String get stepsCount => _en ? 'steps' : '个步骤';
  String get step => _en ? 'Step' : '步骤';
  String get addStep => _en ? 'Add Step' : '添加步骤';

  String get stepName => _en ? 'Step Name' : '步骤名称';
  String get stepCommand => _en ? 'Execution Command' : '执行命令';
  String get stepDesc => _en ? 'Step Description' : '步骤描述';
  String get expectedRegex =>
      _en ? 'Expected Outcome Regex (Optional)' : '预期输出正则 (可选)';

  String get emptyTitle => _en ? 'No Playbooks Yet' : '暂无运维剧本';
  String get emptyHint => _en
      ? 'Create automated sequential task playbooks to run multiple SSH commands with step-by-step control, status tracking, and AI-assisted troubleshooting.'
      : '创建自动化的顺序执行剧本，一键运行多个服务器命令。支持分步追踪、执行失败自动暂停、一键拉起 AI 诊断及排障。';

  String get selectPlaybookPrompt =>
      _en ? 'Please select a playbook from the list' : '请先从左侧列表选择一个剧本';
  String get selectServer => _en ? 'Target Server' : '目标服务器';
  String get selectServerHint =>
      _en ? 'Please select a server connection' : '请选择执行该剧本的服务器';

  String get start => _en ? 'Start Execution' : '开始执行';
  String get pause => _en ? 'Pause' : '暂停';
  String get resume => _en ? 'Resume' : '继续执行';
  String get skip => _en ? 'Skip Step' : '跳过当前步';
  String get reset => _en ? 'Reset' : '重置状态';

  String get aiDiagnostic => _en ? 'Request AI Diagnostic' : '请求 AI 诊断';

  String get regex => _en ? 'Regex' : '预期正则';
  String get exitCode => _en ? 'Exit Code' : '退出状态码';
}
