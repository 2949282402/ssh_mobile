import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:feature_ai/src/skills/viewmodels/ai_skills_viewmodel.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:app_ui/app_ui.dart';

final _kPlaceholderSkills = List.generate(
  4,
  (i) => AiSkillRecord(
    id: 'placeholder-skill-$i',
    name: 'Placeholder Skill ${i + 1}',
    description:
        'A mock skill description placeholder to keep skeleton layout aligned with real items.',
    content: '',
    enabled: true,
    createdAt: DateTime(2026, 9, 1),
    updatedAt: DateTime(2026, 9, 1),
  ),
);

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
    final isLoading = viewModel.loading && viewModel.skills.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.title),
        actions: [
          IconButton(
            tooltip: strings.newSkill,
            icon: const Icon(Icons.add_rounded),
            onPressed: isLoading
                ? null
                : () {
                    viewModel.newSkill();
                    _navigateToEdit(context, viewModel);
                  },
          ),
        ],
      ),
      body: isLoading
          ? AppSkeletonizer(
              enabled: true,
              semanticsLabel: strings.loadingSkills,
              child: _buildSkillList(
                viewModel,
                strings,
                colorScheme,
                skills: _kPlaceholderSkills,
                isSkeleton: true,
              ),
            )
          : Stack(
              children: [
                _buildSkillList(
                  viewModel,
                  strings,
                  colorScheme,
                  skills: viewModel.skills,
                ),
                if (viewModel.loading && viewModel.skills.isNotEmpty)
                  const LinearProgressIndicator(minHeight: 2),
              ],
            ),
    );
  }

  Widget _buildSkillList(
    AiSkillsViewModel viewModel,
    _SkillStrings strings,
    ColorScheme colorScheme, {
    required List<AiSkillRecord> skills,
    bool isSkeleton = false,
  }) {
    if (!isSkeleton && skills.isEmpty) {
      return AppEmptyState(
        icon: Icons.psychology_outlined,
        title: strings.emptyTitle,
        message: strings.emptyHint,
        action: FilledButton.icon(
          onPressed: () {
            viewModel.newSkill();
            _navigateToEdit(context, viewModel);
          },
          icon: const Icon(Icons.add_rounded),
          label: Text(strings.newSkill),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.sm),
      itemCount: skills.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.xs),
      itemBuilder: (context, index) {
        final skill = skills[index];
        final selected = !isSkeleton && skill.id == viewModel.selectedId;
        return ListTile(
          selected: selected,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          ),
          leading: Icon(
            skill.enabled
                ? (selected ? Icons.auto_awesome : Icons.auto_awesome_outlined)
                : Icons.visibility_off_outlined,
            color: skill.enabled
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          title: OverflowScrollText(
            skill.displayName,
            selectable: false,
            maxLines: 1,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${skill.enabled ? strings.enabled : strings.disabled} · ${skill.displayDescription.isEmpty ? strings.noDescription : skill.displayDescription}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Switch(
            value: skill.enabled,
            onChanged: isSkeleton
                ? null
                : (value) => viewModel.setSkillEnabled(skill, value),
          ),
          onTap: isSkeleton
              ? null
              : () {
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
  String get loadingSkills => _en ? 'Loading skills...' : '正在加载 Skills...';
  String get newSkill => _en ? 'New skill' : '新增 Skill';
  String get emptyTitle => _en ? 'No custom skills yet' : '还没有自定义 Skills';
  String get emptyHint => _en
      ? 'Create reusable instructions for model behavior, workflows, references, and maintenance rules.'
      : '创建可复用的模型行为、工作流、references 和维护规则说明。';
  String get noDescription => _en ? 'No description' : '暂无说明';
}
