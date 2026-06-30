// ignore_for_file: invalid_use_of_protected_member
part of '../llm_chat_screen.dart';

class _ChatAttachmentPreview extends StatelessWidget {
  const _ChatAttachmentPreview();

  @override
  Widget build(BuildContext context) {
    return Selector<AiChatViewModel, List<AiChatAttachment>>(
      selector: (_, vm) =>
          List<AiChatAttachment>.unmodifiable(vm.pendingAttachments),
      shouldRebuild: (prev, next) => !listEquals(prev, next),
      builder: (context, pendingAttachments, _) {
        if (pendingAttachments.isEmpty) return const SizedBox.shrink();
        final viewModel = context.read<AiChatViewModel>();
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (var i = 0; i < pendingAttachments.length; i++)
                _AttachmentChip(
                  attachment: pendingAttachments[i],
                  onRemove: () {
                    viewModel.removeAttachmentAt(i);
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

extension _ChatAttachments on _LlmChatScreenBodyState {
  Future<void> _pickImage(_AiStrings strings) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
      );
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;

      final viewModel = context.read<AiChatViewModel>();
      final settings = await viewModel.loadAiConnectionSettings();
      final maxBytes = settings.maxImageSizeBytes;

      for (final file in result.files) {
        if (file.size == 0) continue;
        if (file.size > maxBytes) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(strings.imageTooLarge(
                  file.name,
                  AiUploadSizeLimit.label(maxBytes),
                )),
              ),
            );
          }
          continue;
        }
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        final mimeType = _guessMimeType(file.name, fallback: 'image/png');
        viewModel.addAttachment(AiChatAttachment(
          fileName: file.name,
          mimeType: mimeType,
          sizeBytes: file.size,
          dataBase64: base64Encode(bytes),
        ));
      }
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Image pick failed',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _pickFile(_AiStrings strings) async {
    try {
      final result = await FilePicker.pickFiles();
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;

      final viewModel = context.read<AiChatViewModel>();
      final settings = await viewModel.loadAiConnectionSettings();
      final maxBytes = settings.maxFileSizeBytes;

      for (final file in result.files) {
        if (file.size == 0) continue;
        if (file.size > maxBytes) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(strings.fileTooLarge(
                  file.name,
                  AiUploadSizeLimit.label(maxBytes),
                )),
              ),
            );
          }
          continue;
        }
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        final mimeType = _guessMimeType(file.name);
        viewModel.addAttachment(AiChatAttachment(
          fileName: file.name,
          mimeType: mimeType,
          sizeBytes: file.size,
          dataBase64: base64Encode(bytes),
        ));
      }
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'File pick failed',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  static String _guessMimeType(String fileName,
      {String fallback = 'application/octet-stream'}) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.xml')) return 'text/xml';
    if (lower.endsWith('.html') || lower.endsWith('.htm')) return 'text/html';
    if (lower.endsWith('.css')) return 'text/css';
    if (lower.endsWith('.js')) return 'text/javascript';
    if (lower.endsWith('.dart')) return 'text/plain';
    if (lower.endsWith('.py')) return 'text/plain';
    if (lower.endsWith('.md')) return 'text/markdown';
    if (lower.endsWith('.csv')) return 'text/csv';
    if (lower.endsWith('.yaml') || lower.endsWith('.yml')) return 'text/yaml';
    if (lower.endsWith('.log')) return 'text/plain';
    if (lower.endsWith('.sh') ||
        lower.endsWith('.bat') ||
        lower.endsWith('.ps1')) {
      return 'text/plain';
    }
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.zip')) return 'application/zip';
    return fallback;
  }
}
