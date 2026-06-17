import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../features/rag/viewmodels/rag_knowledge_viewmodel.dart';
import '../services/app_settings.dart';
import '../services/rag_service.dart';

class _RagStrings {
  final bool isEn;
  const _RagStrings(this.isEn);

  String get title => isEn ? 'Ops Knowledge Base' : '运维知识库';
  String get noDocuments => isEn ? 'No documents uploaded yet' : '暂无上传的运维文档';
  String get uploadHint => isEn
      ? 'Tap + to upload a document (PDF, Markdown, Txt, Log)'
      : '点击右下角 + 按钮上传本地 PDF、Markdown 或文本日志文档';
  String get documentName => isEn ? 'Document Name' : '文档名称';
  String get uploadTime => isEn ? 'Uploaded At' : '上传时间';
  String get size => isEn ? 'Size' : '大小';
  String get chunks => isEn ? 'Chunks' : '分块数';
  String get deleteConfirmTitle => isEn ? 'Delete Document' : '删除文档';
  String deleteConfirmContent(String name) => isEn
      ? 'Are you sure you want to delete "$name" from the knowledge base?'
      : '确定要从知识库中删除文档 "$name" 吗？该操作不可恢复。';
  String get delete => isEn ? 'Delete' : '删除';
  String get cancel => isEn ? 'Cancel' : '取消';
  String get uploading => isEn ? 'Uploading & indexing...' : '正在上传并构建索引...';
  String get errorNoText =>
      isEn ? 'No valid text found in this document.' : '未在文档中提取到有效文本内容。';
  String get successAdded =>
      isEn ? 'Document indexed successfully' : '文档上传并构建索引成功';
  String get deleteFailed => isEn ? 'Delete failed' : '删除失败';
  String get errorAdd => isEn ? 'Failed to process document' : '上传/处理文档失败';
  String get aliyunSettings =>
      isEn ? 'Aliyun DashScope Settings' : '阿里云 DashScope 设置';
  String get aliyunHint => isEn
      ? 'Configure the API Key to enable semantic vector and hybrid search. DashScope keys start with "sk-".'
      : '配置 API 密钥以启用语义向量与双模混合检索。通义千问 DashScope 密钥通常以 "sk-" 开头。';
  String get save => isEn ? 'Save' : '保存';
  String chunkCount(int count) => isEn ? '$count chunks' : '$count 个分块';
  String uploadedAtLabel(String date) =>
      isEn ? 'Uploaded at $date' : '上传于 $date';
}

class RagKnowledgeScreen extends StatefulWidget {
  const RagKnowledgeScreen({super.key});

  @override
  State<RagKnowledgeScreen> createState() => _RagKnowledgeScreenState();
}

class _RagKnowledgeScreenState extends State<RagKnowledgeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<RagKnowledgeViewModel>().initRag();
    });
  }

  Future<void> _showAliyunSettings(BuildContext context, _RagStrings strings,
      RagKnowledgeViewModel viewModel) async {
    final currentKey = await viewModel.getAliyunApiKey() ?? '';
    final controller = TextEditingController(text: currentKey);
    var isObscured = true;

    if (!context.mounted) return;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(strings.aliyunSettings),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.aliyunHint,
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  obscureText: isObscured,
                  decoration: InputDecoration(
                    labelText: 'Aliyun DashScope API Key',
                    hintText: 'apiKey (e.g. sk-...)',
                    suffixIcon: IconButton(
                      icon: Icon(
                        isObscured ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () {
                        setState(() => isObscured = !isObscured);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(strings.cancel),
            ),
            ElevatedButton(
              onPressed: () async {
                await viewModel.saveAliyunApiKey(controller.text.trim());
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(strings.save),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleUpload(BuildContext context, _RagStrings strings,
      RagKnowledgeViewModel viewModel) async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'pdf',
          'md',
          'txt',
          'log',
          'json',
          'yaml',
          'yml',
          'csv'
        ],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.bytes == null || file.bytes!.isEmpty) return;

      await viewModel.addDocument(
        file.name,
        file.bytes!,
        file.extension == 'pdf' ? 'application/pdf' : 'text/plain',
      );

      messenger.showSnackBar(
        SnackBar(content: Text(strings.successAdded)),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('${strings.errorAdd}: $e')),
      );
    }
  }

  Future<void> _handleDelete(
    BuildContext context,
    _RagStrings strings,
    RagKnowledgeViewModel viewModel,
    RagDocumentMetadata doc,
  ) async {
    final messenger = ScaffoldMessenger.of(context);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.deleteConfirmTitle),
        content: Text(strings.deleteConfirmContent(doc.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.cancel),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.delete),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await viewModel.deleteDocument(doc.id);
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('${strings.deleteFailed}: $e')),
        );
      }
    }
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final viewModel = context.watch<RagKnowledgeViewModel>();
    final strings = _RagStrings(settings.isEnglish);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.title),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: strings.aliyunSettings,
            onPressed: () => _showAliyunSettings(context, strings, viewModel),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (viewModel.documents.isEmpty && !viewModel.isLoading)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.auto_stories,
                      size: 80,
                      color: theme.colorScheme.primary.withValues(alpha: 0.3),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      strings.noDocuments,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      strings.uploadHint,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: viewModel.documents.length,
              itemBuilder: (context, index) {
                final doc = viewModel.documents[index];
                final isPdf = doc.name.toLowerCase().endsWith('.pdf');
                final dateStr =
                    DateFormat('yyyy-MM-dd HH:mm').format(doc.uploadedAt);

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  elevation: 1,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    leading: CircleAvatar(
                      backgroundColor: isPdf
                          ? theme.colorScheme.errorContainer
                          : theme.colorScheme.primaryContainer,
                      foregroundColor: isPdf
                          ? theme.colorScheme.onErrorContainer
                          : theme.colorScheme.onPrimaryContainer,
                      child: Icon(
                        isPdf ? Icons.picture_as_pdf : Icons.description,
                      ),
                    ),
                    title: Text(
                      doc.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.storage_outlined,
                                size: 14,
                                color: theme.textTheme.bodySmall?.color,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _formatSize(doc.sizeBytes),
                                style: theme.textTheme.bodySmall,
                              ),
                              const SizedBox(width: 12),
                              Icon(
                                Icons.grid_view_outlined,
                                size: 14,
                                color: theme.textTheme.bodySmall?.color,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                strings.chunkCount(doc.chunkCount),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            strings.uploadedAtLabel(dateStr),
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      color: theme.colorScheme.error,
                      onPressed: () =>
                          _handleDelete(context, strings, viewModel, doc),
                    ),
                  ),
                );
              },
            ),
          if (viewModel.isProcessing || viewModel.isLoading)
            Container(
              color: Colors.black.withValues(alpha: 0.3),
              child: Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          strings.uploading,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: viewModel.isProcessing
            ? null
            : () => _handleUpload(context, strings, viewModel),
        tooltip: strings.title,
        child: const Icon(Icons.add),
      ),
    );
  }
}
