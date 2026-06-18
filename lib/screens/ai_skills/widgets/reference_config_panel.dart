import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../features/ai_skills/viewmodels/ai_skills_viewmodel.dart';
import '../../../../services/app_settings.dart';

class ReferenceConfigPanel extends StatefulWidget {
  const ReferenceConfigPanel({super.key});

  @override
  State<ReferenceConfigPanel> createState() => _ReferenceConfigPanelState();
}

class _ReferenceConfigPanelState extends State<ReferenceConfigPanel> {
  final TextEditingController _refTitleController = TextEditingController();
  final TextEditingController _refContentController = TextEditingController();

  @override
  void dispose() {
    _refTitleController.dispose();
    _refContentController.dispose();
    super.dispose();
  }

  void _submitReference(AiSkillsViewModel viewModel) {
    final title = _refTitleController.text.trim();
    final content = _refContentController.text.trim();
    if (title.isNotEmpty) {
      viewModel.addReference(title, content);
      _refTitleController.clear();
      _refContentController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<AiSkillsViewModel>();
    final strings = _PanelStrings(viewModel.language);
    final colorScheme = Theme.of(context).colorScheme;

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
                        style: TextStyle(
                            color: colorScheme.onSurfaceVariant, fontSize: 13),
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
                          leading: const Icon(Icons.insert_drive_file_outlined,
                              size: 20),
                          title: Text(ref.title,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 13)),
                          subtitle: ref.content.isNotEmpty
                              ? Text(
                                  ref.content,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: colorScheme.onSurfaceVariant,
                                      fontSize: 12),
                                )
                              : null,
                          trailing: IconButton(
                            icon: const Icon(Icons.remove_circle_outline,
                                color: Colors.redAccent, size: 20),
                            onPressed: () => viewModel.removeReference(index),
                          ),
                          onTap: () {
                            showDialog(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: Text(ref.title),
                                content: SingleChildScrollView(
                                  child: Text(ref.content,
                                      style: const TextStyle(fontSize: 14)),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx),
                                    child: Text(strings.close),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ),
                  const SizedBox(height: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _refTitleController,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: strings.addReferenceLabel,
                          hintText: strings.addReferenceHint,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _refContentController,
                              minLines: 2,
                              maxLines: 4,
                              decoration: InputDecoration(
                                isDense: true,
                                labelText: strings.addReferenceDescLabel,
                                hintText: strings.addReferenceDescHint,
                                alignLabelWithHint: true,
                                border: const OutlineInputBorder(),
                              ),
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
}

class _PanelStrings {
  final AppLanguage language;

  const _PanelStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get close => _en ? 'Close' : '关闭';
  String get enableReferences =>
      _en ? 'Enable References' : '启用参考资料 (References)';
  String get enableReferencesHint => _en
      ? 'Enable structured reference notes for conditional loading by AI agent.'
      : '开启可视化参考说明及规程，便于 AI Agent 针对不同场景动态检索和使用。';
  String get referencesListTitle => _en ? 'Reference Items' : '已配置的参考说明';
  String get noReferences =>
      _en ? 'No reference items added yet.' : '尚未配置任何参考资料。';
  String get addReferenceLabel =>
      _en ? 'Reference Title / Purpose' : '参考说明 / 标题';
  String get addReferenceHint =>
      _en ? 'e.g. Nginx restart rules' : '如：Nginx 重启与故障恢复步骤';
  String get addReferenceDescLabel =>
      _en ? 'Reference Content / Instructions' : '具体参考内容 / 命令 (支持多行)';
  String get addReferenceDescHint => _en
      ? 'Write commands, details, or checklists...'
      : '书写具体的命令行参数、规程内容或排障注意事项...';

  String get referenceHint => _en
      ? 'Reference items are configured independently and loaded on demand by AI agent, avoiding overloading system prompts.'
      : '参考说明与内容单独配置且独立于 Markdown 正文存储。智能体在需要时按需调用工具加载它们，可防止一次性塞入系统提示词引起 Token 溢出。';
}
