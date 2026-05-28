import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_settings.dart';
import '../services/storage_service.dart';

class AiSkillsScreen extends StatefulWidget {
  const AiSkillsScreen({super.key});

  @override
  State<AiSkillsScreen> createState() => _AiSkillsScreenState();
}

class _AiSkillsScreenState extends State<AiSkillsScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();
  late final TabController _mobileTabs;
  List<AiSkillRecord> _skills = const [];
  String? _selectedId;
  bool _enabled = true;
  bool _loading = true;
  bool _dirty = false;

  AiSkillRecord? get _selectedSkill {
    for (final skill in _skills) {
      if (skill.id == _selectedId) return skill;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _mobileTabs = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSkills());
  }

  @override
  void dispose() {
    _mobileTabs.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _loadSkills() async {
    final skills = await context.read<StorageService>().loadAiSkills();
    if (!mounted) return;
    setState(() {
      _skills = skills;
      _loading = false;
    });
    if (skills.isNotEmpty) _selectSkill(skills.first);
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = _SkillStrings(language);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.title),
        actions: [
          IconButton(
            tooltip: strings.newSkill,
            icon: const Icon(Icons.add_rounded),
            onPressed: _newSkill,
          ),
          IconButton(
            tooltip: strings.save,
            icon: const Icon(Icons.save_outlined),
            onPressed: _canSave ? () => _saveSkill(strings) : null,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 760;
                final list = _buildSkillList(strings, colorScheme);
                final editor = _buildEditor(strings, colorScheme);
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

  bool get _canSave {
    return _nameController.text.trim().isNotEmpty ||
        _descriptionController.text.trim().isNotEmpty ||
        _contentController.text.trim().isNotEmpty;
  }

  Widget _buildSkillList(_SkillStrings strings, ColorScheme colorScheme) {
    if (_skills.isEmpty) {
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
              onPressed: _newSkill,
              icon: const Icon(Icons.add_rounded),
              label: Text(strings.newSkill),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: _skills.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final skill = _skills[index];
        final selected = skill.id == _selectedId;
        return ListTile(
          selected: selected,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: Icon(
            skill.enabled
                ? (selected ? Icons.auto_awesome : Icons.auto_awesome_outlined)
                : Icons.visibility_off_outlined,
          ),
          title: Text(
            skill.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${skill.enabled ? strings.enabled : strings.disabled} · ${skill.description.isEmpty ? strings.noDescription : skill.description}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Switch(
            value: skill.enabled,
            onChanged: (value) => _setSkillEnabled(skill, value),
          ),
          onTap: () => _selectSkill(skill),
        );
      },
    );
  }

  Widget _buildEditor(_SkillStrings strings, ColorScheme colorScheme) {
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
                      '${_selectedId == null ? strings.newSkill : strings.editSkill}${_dirty ? ' *' : ''}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: strings.delete,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _selectedSkill == null
                        ? null
                        : () => _deleteSkill(strings),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameController,
                decoration: InputDecoration(labelText: strings.name),
                onChanged: (_) => _markDirty(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionController,
                minLines: 3,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: strings.description,
                  alignLabelWithHint: true,
                ),
                onChanged: (_) => _markDirty(),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(strings.available),
                subtitle: Text(strings.availableHint),
                value: _enabled,
                onChanged: (value) {
                  setState(() {
                    _enabled = value;
                    _dirty = true;
                  });
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _contentController,
                minLines: 14,
                maxLines: 26,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  labelText: strings.content,
                  helperText: strings.contentHelp,
                  alignLabelWithHint: true,
                ),
                onChanged: (_) => _markDirty(),
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
                      onPressed: _newSkill,
                      icon: const Icon(Icons.add_rounded),
                      label: Text(strings.newSkill),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _canSave ? () => _saveSkill(strings) : null,
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

  void _selectSkill(AiSkillRecord skill) {
    setState(() {
      _selectedId = skill.id;
      _nameController.text = skill.name;
      _descriptionController.text = skill.description;
      _contentController.text = skill.content;
      _enabled = skill.enabled;
      _dirty = false;
    });
    if (_isCompactLayout) {
      _mobileTabs.animateTo(1);
    }
  }

  void _newSkill() {
    final strings = _SkillStrings(context.read<AppSettings>().language);
    final now = DateTime.now();
    setState(() {
      _selectedId = null;
      _nameController.text = strings.defaultName;
      _descriptionController.text = '';
      _contentController.text = _skillTemplate(strings.defaultName, now);
      _enabled = true;
      _dirty = true;
    });
    if (_isCompactLayout) {
      _mobileTabs.animateTo(1);
    }
  }

  bool get _isCompactLayout {
    final width = MediaQuery.maybeSizeOf(context)?.width;
    return width != null && width < 760;
  }

  Future<void> _saveSkill(_SkillStrings strings) async {
    final storage = context.read<StorageService>();
    final now = DateTime.now();
    final current = _selectedSkill;
    final skill = current == null
        ? AiSkillRecord(
            id: 'skill-${now.microsecondsSinceEpoch}',
            name: _nameController.text.trim().isEmpty
                ? strings.defaultName
                : _nameController.text.trim(),
            description: _descriptionController.text.trim(),
            content: _contentController.text,
            enabled: _enabled,
            createdAt: now,
            updatedAt: now,
          )
        : current.copyWith(
            name: _nameController.text.trim().isEmpty
                ? strings.defaultName
                : _nameController.text.trim(),
            description: _descriptionController.text.trim(),
            content: _contentController.text,
            enabled: _enabled,
            updatedAt: now,
          );
    await storage.saveAiSkill(skill);
    final skills = await storage.loadAiSkills();
    if (!mounted) return;
    setState(() {
      _skills = skills;
      _selectedId = skill.id;
      _dirty = false;
    });
    for (final item in skills) {
      if (item.id == skill.id) {
        _selectSkill(item);
        break;
      }
    }
  }

  Future<void> _setSkillEnabled(AiSkillRecord skill, bool enabled) async {
    final storage = context.read<StorageService>();
    final updated = skill.copyWith(enabled: enabled, updatedAt: DateTime.now());
    await storage.saveAiSkill(updated);
    final skills = await storage.loadAiSkills();
    if (!mounted) return;
    setState(() => _skills = skills);
    if (_selectedId == skill.id) {
      _selectSkill(updated);
    }
  }

  Future<void> _deleteSkill(_SkillStrings strings) async {
    final skill = _selectedSkill;
    if (skill == null) return;
    final storage = context.read<StorageService>();
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
    if (confirmed != true || !mounted) return;
    await storage.deleteAiSkill(skill.id);
    final skills = await storage.loadAiSkills();
    if (!mounted) return;
    setState(() {
      _skills = skills;
      _selectedId = null;
      _nameController.clear();
      _descriptionController.clear();
      _contentController.clear();
      _enabled = true;
      _dirty = false;
    });
    if (skills.isNotEmpty) _selectSkill(skills.first);
  }

  void _markDirty() {
    if (_dirty) return;
    setState(() => _dirty = true);
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
