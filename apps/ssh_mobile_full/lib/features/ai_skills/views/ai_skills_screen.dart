import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:ssh_mobile/features/ai_skills/viewmodels/ai_skills_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:app_ui/app_ui.dart';

class AiSkillsScreen extends StatefulWidget {
  const AiSkillsScreen({super.key});

  @override
  State<AiSkillsScreen> createState() => _AiSkillsScreenState();
}

class _AiSkillsScreenState extends State<AiSkillsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AiSkillsViewModel>().loadSkills();
    });
  }

  void _navigateToEdit(BuildContext context, AiSkillsViewModel viewModel) {
    Navigator.pushNamed(
      context,
      '/ai-skills/edit',
      arguments: {'viewModel': viewModel},
    );
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
              viewModel.newSkill();
              _navigateToEdit(context, viewModel);
            },
          ),
        ],
      ),
      body: viewModel.loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _buildSkillList(viewModel, strings, colorScheme),
    );
  }

  Widget _buildSkillList(
    AiSkillsViewModel viewModel,
    _SkillStrings strings,
    ColorScheme colorScheme,
  ) {
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
                viewModel.newSkill();
                _navigateToEdit(context, viewModel);
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
      separatorBuilder: (_, _) => const SizedBox(height: 4),
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
            skill.displayName,
            selectable: false,
            maxLines: 1,
          ),
          subtitle: Text(
            '${skill.enabled ? strings.enabled : strings.disabled} · ${skill.displayDescription.isEmpty ? strings.noDescription : skill.displayDescription}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Switch(
            value: skill.enabled,
            onChanged: (value) => viewModel.setSkillEnabled(skill, value),
          ),
          onTap: () {
            viewModel.selectSkill(skill);
            _navigateToEdit(context, viewModel);
          },
        );
      },
    );
  }
}

extension _SkillAvailabilityStrings on _SkillStrings {
  String get enabled => _en ? 'Enabled' : '可用';
  String get disabled => _en ? 'Disabled' : '不可用';
}

class _SkillStrings {
  final AppLanguage language;

  const _SkillStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get title => _en ? 'AI Skills' : 'AI Skills';
  String get newSkill => _en ? 'New skill' : '新增 Skill';
  String get emptyTitle => _en ? 'No custom skills yet' : '还没有自定义 Skills';
  String get emptyHint => _en
      ? 'Create reusable instructions for model behavior, workflows, references, and maintenance rules.'
      : '创建可复用的模型行为、工作流、references 和维护规则说明。';
  String get noDescription => _en ? 'No description' : '暂无说明';
}
