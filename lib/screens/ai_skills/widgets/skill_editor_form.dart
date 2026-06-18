import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../features/ai_skills/viewmodels/ai_skills_viewmodel.dart';
import '../../../../services/app_settings.dart';

class SkillEditorForm extends StatelessWidget {
  const SkillEditorForm({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = context.read<AiSkillsViewModel>();
    final language =
        context.select<AiSkillsViewModel, AppLanguage>((vm) => vm.language);
    final strings = _FormStrings(language);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
          onChanged: (_) => viewModel.markDirty(),
        ),
      ],
    );
  }
}

class _FormStrings {
  final AppLanguage language;
  const _FormStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get name => _en ? 'Name' : '名称';
  String get description => _en ? 'Description / Summary' : '说明 / 概要';
  String get content =>
      _en ? 'Detailed Skill Instructions' : '具体规程说明 (Markdown)';
  String get contentHelp =>
      _en ? 'Supports standard markdown syntax.' : '支持 markdown 语法规范。';
}
