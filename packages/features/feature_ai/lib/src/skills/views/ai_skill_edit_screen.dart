import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:app_ui/app_ui.dart';
import 'package:feature_ai/src/skills/viewmodels/ai_skills_viewmodel.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'widgets/skill_editor_form.dart';
import 'widgets/reference_config_panel.dart';

class AiSkillEditScreen extends StatelessWidget {
  const AiSkillEditScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<AiSkillsViewModel>();
    final strings = _EditStrings(viewModel.language);

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
          title: Text(
            viewModel.selectedId == null ? strings.newSkill : strings.editSkill,
          ),
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
            const editor = SkillEditorForm();
            const references = ReferenceConfigPanel();

            if (wide) {
              return const Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: SingleChildScrollView(child: editor),
                    ),
                    SizedBox(width: AppSpacing.xl),
                    Expanded(
                      flex: 2,
                      child: SingleChildScrollView(child: references),
                    ),
                  ],
                ),
              );
            }

            return const SingleChildScrollView(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  editor,
                  SizedBox(height: AppSpacing.lg),
                  references,
                  SizedBox(height: AppSpacing.xxl),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<bool?> _confirmDiscard(BuildContext context, _EditStrings strings) {
    return AppConfirmDialog.show(
      context,
      title: strings.discardTitle,
      content: strings.discardContent,
      cancelLabel: strings.cancel,
      confirmLabel: strings.discard,
      isDestructive: true,
    );
  }

  Future<void> _deleteSkill(
    BuildContext context,
    AiSkillsViewModel viewModel,
    _EditStrings strings,
  ) async {
    final skill = viewModel.selectedSkill;
    if (skill == null) return;
    final confirmed = await AppConfirmDialog.show(
      context,
      title: strings.deleteSkill,
      content: strings.deleteSkillContent(skill.displayName),
      cancelLabel: strings.cancel,
      confirmLabel: strings.delete,
      isDestructive: true,
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

  String get discardTitle => _en ? 'Discard Changes?' : '放弃修改？';
  String get discardContent => _en
      ? 'You have unsaved changes. Are you sure you want to discard them?'
      : '您有尚未保存的修改。确定要放弃并退出吗？';
  String get discard => _en ? 'Discard' : '放弃';
}
