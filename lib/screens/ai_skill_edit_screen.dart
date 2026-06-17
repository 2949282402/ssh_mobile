import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/ai_skills/viewmodels/ai_skills_viewmodel.dart';
import '../services/app_settings.dart';

class AiSkillEditScreen extends StatefulWidget {
  const AiSkillEditScreen({super.key});

  @override
  State<AiSkillEditScreen> createState() => _AiSkillEditScreenState();
}

class _AiSkillEditScreenState extends State<AiSkillEditScreen> {
  final TextEditingController _refInputController = TextEditingController();
  final TextEditingController _refDescController = TextEditingController();

  @override
  void dispose() {
    _refInputController.dispose();
    _refDescController.dispose();
    super.dispose();
  }

  void _submitReference(AiSkillsViewModel viewModel) {
    final path = _refInputController.text.trim();
    final desc = _refDescController.text.trim();
    if (path.isNotEmpty) {
      viewModel.addReference(path, desc);
      _refInputController.clear();
      _refDescController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<AiSkillsViewModel>();
    final strings = _EditStrings(viewModel.language);
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !viewModel.dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final confirmed = await _confirmDiscard(context, strings);
        if (confirmed == true && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(viewModel.selectedId == null ? strings.newSkill : strings.editSkill),
          actions: [
            if (viewModel.selectedId != null)
              IconButton(
                tooltip: strings.delete,
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () => _deleteSkill(context, viewModel, strings),
              ),
            IconButton(
              tooltip: strings.save,
              icon: const Icon(Icons.save_outlined),
              onPressed: viewModel.canSave
                  ? () async {
                      await viewModel.saveSkill();
                      if (context.mounted) {
                        Navigator.pop(context);
                      }
                    }
                  : null,
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 840;
            final editor = _buildEditorForm(viewModel, strings, colorScheme);
            final references = _buildReferencesPanel(viewModel, strings, colorScheme);

            if (wide) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: SingleChildScrollView(child: editor),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      flex: 2,
                      child: SingleChildScrollView(child: references),
                    ),
                  ],
                ),
              );
            }

            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  editor,
                  const SizedBox(height: 16),
                  references,
                  const SizedBox(height: 32),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildEditorForm(
      AiSkillsViewModel viewModel, _EditStrings strings, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${viewModel.selectedId == null ? strings.newSkill : strings.editSkill}${viewModel.dirty ? ' *' : ''}',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: viewModel.nameController,
          decoration: InputDecoration(
            labelText: strings.name,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => viewModel.markDirty(),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: viewModel.descriptionController,
          minLines: 3,
          maxLines: 5,
          decoration: InputDecoration(
            labelText: strings.description,
            alignLabelWithHint: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => viewModel.markDirty(),
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(strings.available),
          subtitle: Text(strings.availableHint),
          value: viewModel.enabled,
          onChanged: (value) {
            viewModel.updateEnabled(value);
          },
        ),
        const SizedBox(height: 16),
        TextField(
          controller: viewModel.contentController,
          minLines: 12,
          maxLines: 24,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: InputDecoration(
            labelText: strings.content,
            helperText: strings.contentHelp,
            alignLabelWithHint: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) {
            viewModel.markDirty();
            // 用户在文本框打字时，需要即时同步回可视化面板的状态，但不主动重填 contentController.text 以防光标跳动
            viewModel.parseReferencesFromContent();
          },
        ),
      ],
    );
  }

  Widget _buildReferencesPanel(
      AiSkillsViewModel viewModel, _EditStrings strings, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(strings.enableReferences),
                  subtitle: Text(strings.enableReferencesHint),
                  value: viewModel.hasReferences,
                  onChanged: (value) {
                    viewModel.toggleReferences(value);
                  },
                ),
                if (viewModel.hasReferences) ...[
                  const Divider(height: 24),
                  Text(
                    strings.referencesListTitle,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (viewModel.references.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        strings.noReferences,
                        style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
                      ),
                    )
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: viewModel.references.length,
                      itemBuilder: (context, index) {
                        final ref = viewModel.references[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: const Icon(Icons.insert_drive_file_outlined, size: 20),
                          title: Text(ref.path, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                          subtitle: ref.description.isNotEmpty
                              ? Text(ref.description, style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12))
                              : null,
                          trailing: IconButton(
                            icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent, size: 20),
                            onPressed: () => viewModel.removeReference(index),
                          ),
                        );
                      },
                    ),
                  const SizedBox(height: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _refInputController,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: strings.addReferenceLabel,
                          hintText: 'references/my_rules.md',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _refDescController,
                              decoration: InputDecoration(
                                isDense: true,
                                labelText: strings.addReferenceDescLabel,
                                hintText: strings.addReferenceDescHint,
                                border: const OutlineInputBorder(),
                              ),
                              onSubmitted: (_) => _submitReference(viewModel),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filledTonal(
                            icon: const Icon(Icons.add_rounded),
                            onPressed: () => _submitReference(viewModel),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          child: Text(
            strings.referenceHint,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              height: 1.35,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }

  Future<bool?> _confirmDiscard(BuildContext context, _EditStrings strings) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.discardTitle),
        content: Text(strings.discardContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(strings.discard),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteSkill(
      BuildContext context, AiSkillsViewModel viewModel, _EditStrings strings) async {
    final skill = viewModel.selectedSkill;
    if (skill == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.deleteSkill),
        content: Text(strings.deleteSkillContent(skill.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await viewModel.deleteSkill();
      if (context.mounted) {
        Navigator.pop(context);
      }
    }
  }
}

class _EditStrings {
  final AppLanguage language;

  const _EditStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get newSkill => _en ? 'New Skill' : '新增 Skill';
  String get editSkill => _en ? 'Edit Skill' : '编辑 Skill';
  String get save => _en ? 'Save' : '保存';
  String get cancel => _en ? 'Cancel' : '取消';
  String get delete => _en ? 'Delete' : '删除';
  String get deleteSkill => _en ? 'Delete skill' : '删除 Skill';
  String deleteSkillContent(String name) =>
      _en ? 'Delete "$name"?' : '确定删除 "$name" 吗？';

  String get name => _en ? 'Name' : '名称';
  String get description => _en ? 'Description' : '说明';
  String get content => _en ? 'Content' : '具体内容';
  String get contentHelp => _en ? 'Supports markdown syntax and custom sections.' : '支持 markdown 语法及自定义说明内容。';

  String get available => _en ? 'Available in chat toolbar' : '在聊天工具栏可用';
  String get availableHint => _en
      ? 'Disabled skills stay saved but cannot be selected for a chat request.'
      : '关闭后仍会保存，但不会出现在聊天请求的 Skill 选择中。';

  String get enableReferences => _en ? 'Enable Reference Files' : '启用参考文档 (References)';
  String get enableReferencesHint => _en
      ? 'Enable reference documents path extraction for AI agent search context.'
      : '开启可视化参考文档路径配置，便于 AI Agent 检索时精确加载外部规程及注意事项。';
  String get referencesListTitle => _en ? 'Reference Paths' : '已配置的参考文件路径';
  String get noReferences => _en ? 'No reference paths added yet.' : '尚未配置任何参考文档路径。';
  String get addReferenceLabel => _en ? 'Add File Path' : '添加参考文件路径';
  String get addReferenceDescLabel => _en ? 'Description / Purpose (Optional)' : '说明 / 用途 (可选)';
  String get addReferenceDescHint => _en ? 'e.g. For nginx troubleshooting' : '如：适用于 nginx 故障排查';

  String get referenceHint => _en
      ? 'Tip: Put concise usage rules in Description. Put complete SKILL.md-style instructions, references/ paths, templates, or maintenance notes in Content.\nReference paths are synchronized in real-time to the "## References" markdown section.'
      : '提示：说明栏写触发场景和用途；具体内容栏写完整说明或规则。\n在此面板增删参考文件路径，将会自动、实时地同步回具体内容中的“## References”文本段落中。';

  String get discardTitle => _en ? 'Discard Changes?' : '放弃修改？';
  String get discardContent => _en
      ? 'You have unsaved changes. Are you sure you want to discard them?'
      : '您有尚未保存的修改。确定要放弃并退出吗？';
  String get discard => _en ? 'Discard' : '放弃';
}
