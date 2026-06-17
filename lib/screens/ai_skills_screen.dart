import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/ai_skills/viewmodels/ai_skills_viewmodel.dart';
import '../services/app_settings.dart';
import '../widgets/overflow_scroll_text.dart';

class AiSkillsScreen extends StatefulWidget {
  const AiSkillsScreen({super.key});

  @override
  State<AiSkillsScreen> createState() => _AiSkillsScreenState();
}

class _AiSkillsScreenState extends State<AiSkillsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _mobileTabs;

  @override
  void initState() {
    super.initState();
    _mobileTabs = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AiSkillsViewModel>().loadSkills();
    });
  }

  @override
  void dispose() {
    _mobileTabs.dispose();
    super.dispose();
  }

  bool get _isCompactLayout {
    final width = MediaQuery.maybeSizeOf(context)?.width;
    return width != null && width < 760;
  }

  String _skillTemplate(String name, DateTime now) {
    return '''---
name: $name
description: Describe when this skill should be used.
---

# $name

## When To Use

- Describe the trigger, scenario, or user request this skill supports.

## Workflow

1. Inspect the current context.
2. Follow the project-specific steps.
3. Update related references when behavior changes.

## References

- references/example.md

<!-- Created ${now.toIso8601String()} -->
''';
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<AiSkillsViewModel>();
    final strings = _SkillStrings(viewModel.language);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.title),
        actions: [
          IconButton(
            tooltip: strings.newSkill,
            icon: const Icon(Icons.add_rounded),
            onPressed: () {
              viewModel.newSkill(
                strings.defaultName,
                _skillTemplate(strings.defaultName, DateTime.now()),
              );
              if (_isCompactLayout) {
                _mobileTabs.animateTo(1);
              }
            },
          ),
          IconButton(
            tooltip: strings.save,
            icon: const Icon(Icons.save_outlined),
            onPressed: viewModel.canSave
                ? () => viewModel.saveSkill(strings.defaultName)
                : null,
          ),
        ],
      ),
      body: viewModel.loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 760;
                final list = _buildSkillList(viewModel, strings, colorScheme);
                final editor = _buildEditor(viewModel, strings, colorScheme);
                if (wide) {
                  return Row(
                    children: [
                      SizedBox(width: 300, child: list),
                      VerticalDivider(
                        width: 1,
                        color: colorScheme.outlineVariant,
                      ),
                      Expanded(child: editor),
                    ],
                  );
                }
                return Column(
                  children: [
                    Material(
                      color: colorScheme.surface,
                      child: TabBar(
                        controller: _mobileTabs,
                        tabs: [
                          Tab(text: strings.skillList),
                          Tab(text: strings.editor),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: colorScheme.outlineVariant),
                    Expanded(
                      child: TabBarView(
                        controller: _mobileTabs,
                        children: [list, editor],
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildSkillList(AiSkillsViewModel viewModel, _SkillStrings strings,
      ColorScheme colorScheme) {
    final skills = viewModel.skills;

    if (skills.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              strings.emptyTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              strings.emptyHint,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                viewModel.newSkill(
                  strings.defaultName,
                  _skillTemplate(strings.defaultName, DateTime.now()),
                );
                if (_isCompactLayout) {
                  _mobileTabs.animateTo(1);
                }
              },
              icon: const Icon(Icons.add_rounded),
              label: Text(strings.newSkill),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: skills.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final skill = skills[index];
        final selected = skill.id == viewModel.selectedId;
        return ListTile(
          selected: selected,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: Icon(
            skill.enabled
                ? (selected ? Icons.auto_awesome : Icons.auto_awesome_outlined)
                : Icons.visibility_off_outlined,
          ),
          title: OverflowScrollText(
            skill.name,
            selectable: false,
            maxLines: 1,
          ),
          subtitle: Text(
            '${skill.enabled ? strings.enabled : strings.disabled} · ${skill.description.isEmpty ? strings.noDescription : skill.description}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Switch(
            value: skill.enabled,
            onChanged: (value) => viewModel.setSkillEnabled(skill, value),
          ),
          onTap: () {
            viewModel.selectSkill(skill);
            if (_isCompactLayout) {
              _mobileTabs.animateTo(1);
            }
          },
        );
      },
    );
  }

  Widget _buildEditor(AiSkillsViewModel viewModel, _SkillStrings strings,
      ColorScheme colorScheme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
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
                  IconButton(
                    tooltip: strings.delete,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: viewModel.selectedSkill == null
                        ? null
                        : () => _deleteSkill(viewModel, strings),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: viewModel.nameController,
                decoration: InputDecoration(labelText: strings.name),
                onChanged: (_) => viewModel.markDirty(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: viewModel.descriptionController,
                minLines: 3,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: strings.description,
                  alignLabelWithHint: true,
                ),
                onChanged: (_) => viewModel.markDirty(),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(strings.available),
                subtitle: Text(strings.availableHint),
                value: viewModel.enabled,
                onChanged: (value) {
                  viewModel.updateEnabled(value);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: viewModel.contentController,
                minLines: 14,
                maxLines: 26,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  labelText: strings.content,
                  helperText: strings.contentHelp,
                  alignLabelWithHint: true,
                ),
                onChanged: (_) => viewModel.markDirty(),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: Text(
                  strings.referenceHint,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () {
                        viewModel.newSkill(
                          strings.defaultName,
                          _skillTemplate(strings.defaultName, DateTime.now()),
                        );
                      },
                      icon: const Icon(Icons.add_rounded),
                      label: Text(strings.newSkill),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: viewModel.canSave
                          ? () => viewModel.saveSkill(strings.defaultName)
                          : null,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(strings.save),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteSkill(
      AiSkillsViewModel viewModel, _SkillStrings strings) async {
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
    }
  }
}

extension _SkillAvailabilityStrings on _SkillStrings {
  String get available => _en ? 'Available in chat toolbar' : '在聊天工具栏可用';
  String get availableHint => _en
      ? 'Disabled skills stay saved but cannot be selected for a chat request.'
      : '关闭后仍会保存，但不会出现在聊天请求的 Skill 选择中。';
  String get enabled => _en ? 'Enabled' : '可用';
  String get disabled => _en ? 'Disabled' : '不可用';
}

class _SkillStrings {
  final AppLanguage language;

  const _SkillStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get title => _en ? 'AI Skills' : 'AI Skills';
  String get skillList => _en ? 'Skills' : 'Skills';
  String get editor => _en ? 'Editor' : '编辑';
  String get newSkill => _en ? 'New skill' : '新增 Skill';
  String get editSkill => _en ? 'Edit skill' : '编辑 Skill';
  String get save => _en ? 'Save' : '保存';
  String get cancel => _en ? 'Cancel' : '取消';
  String get delete => _en ? 'Delete' : '删除';
  String get deleteSkill => _en ? 'Delete skill' : '删除 Skill';
  String deleteSkillContent(String name) =>
      _en ? 'Delete "$name"?' : '确定删除 "$name" 吗？';
  String get name => _en ? 'Name' : '名称';
  String get description => _en ? 'Description' : '说明';
  String get content => _en ? 'Content' : '具体内容';
  String get noDescription => _en ? 'No description' : '暂无说明';
  String get emptyTitle => _en ? 'No custom skills yet' : '还没有自定义 Skills';
  String get emptyHint => _en
      ? 'Create reusable instructions for model behavior, workflows, references, and maintenance rules.'
      : '创建可复用的模型行为、工作流、references 和维护规则说明。';
  String get contentHelp => _en
      ? 'Supports SKILL.md style front matter, workflow sections, references, and any custom notes.'
      : '支持 SKILL.md 风格 front matter、工作流、references 和自定义说明。';
  String get referenceHint => _en
      ? 'Tip: Put concise usage rules in Description. Put complete SKILL.md-style instructions, references/ paths, templates, or maintenance notes in Content.'
      : '提示：说明栏写触发场景和用途；具体内容栏可写完整 SKILL.md 规范、references/ 路径、模板或维护注意事项。';
  String get defaultName => _en ? 'New Skill' : '新 Skill';
}
