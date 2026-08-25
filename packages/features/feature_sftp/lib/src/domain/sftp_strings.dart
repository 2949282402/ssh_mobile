// SFTP Feature 的本地化文案。
//
// 文案与旧 AppStrings 保持一致，但不再让 Feature 依赖 App Shell 的全量
// 字符串对象；新增文案应优先在本文件按业务边界维护。

import 'sftp_ports.dart';

/// SFTP 页面使用的中英文文案集合。
final class SftpStrings {
  /// 根据语言创建 SFTP 文案。
  SftpStrings(this.language);

  final SftpLanguage language;
  bool get _en => language == SftpLanguage.english;

  String get addConnection => _en ? 'Add connection' : '添加连接';
  String get cancel => _en ? 'Cancel' : '取消';
  String get close => _en ? 'Close' : '关闭';
  String get connected => _en ? 'Connected' : '已连接';
  String get connecting => _en ? 'Connecting' : '连接中';
  String get delete => _en ? 'Delete' : '删除';
  String get disconnect => _en ? 'Disconnect' : '断开连接';
  String get disconnected => _en ? 'Disconnected' : '未连接';
  String get directory => _en ? 'Directory' : '目录';
  String get discard => _en ? 'Discard' : '放弃修改';
  String get edit => _en ? 'Edit' : '编辑';
  String get emptyDirectory => _en ? 'Directory is empty' : '目录为空';
  String get emptyDirectoryHint => _en ? 'No files found here.' : '此目录中没有文件。';
  String entryActions(String name) => _en ? 'Actions for $name' : '$name 的操作';
  String get favoritePaths => _en ? 'Favorite paths' : '收藏路径';
  String get inputPath => _en ? 'Input path' : '输入路径';
  String get loadingDirectory =>
      _en ? 'Loading remote directory…' : '正在加载远程目录…';
  String get loadingFilePreview => _en ? 'Loading file preview…' : '正在加载文件预览…';
  String get loadingRemoteFile => _en ? 'Loading remote file…' : '正在加载远程文件…';
  String get loadingServerCatalog =>
      _en ? 'Loading server catalog…' : '正在加载服务器目录…';
  String get moreActions => _en ? 'More actions' : '更多操作';
  String get noConnections => _en ? 'No saved connections' : '没有已保存的连接';
  String get openPath => _en ? 'Open path' : '打开路径';
  String get parentDirectory => _en ? 'Parent directory' : '上级目录';
  String get pathHistory => _en ? 'Path history' : '路径记录';
  String get preview => _en ? 'Preview' : '预览';
  String get recentPaths => _en ? 'Recent paths' : '最近路径';
  String get refresh => _en ? 'Refresh' : '刷新';
  String get removeFavoritePath => _en ? 'Remove favorite path' : '取消收藏路径';
  String get retry => _en ? 'Retry' : '重试';
  String get save => _en ? 'Save' : '保存';
  String get sftp => 'SFTP';
  String get sftpEmptyTitle =>
      _en ? 'Select a server for SFTP' : '选择服务器使用 SFTP';
  String get sftpEmptyHint => _en
      ? 'Browse remote files using saved SSH connections.'
      : '桌面端和移动端使用同一套 SSH 连接来浏览远程文件。';
  String get sftpLimits => _en ? 'SFTP file limits' : 'SFTP 文件限制';
  String get sftpLimitsHint => _en
      ? 'Client limits for file download, preview, and edit.'
      : '用于客户端下载、预览和编辑的内存保护限制。';
  String get sftpSettings => _en ? 'SFTP settings' : 'SFTP 设置';
  String get sftpServers => _en ? 'SFTP servers' : 'SFTP 服务器';
  String get source => _en ? 'Source' : '源码';
  String get unsupportedPreview => _en
      ? 'Unsupported preview file type. Download to open.'
      : '暂不支持预览这种文件类型。可以下载后用其他应用打开。';
  String get uploadFile => _en ? 'Upload file' : '上传文件';
  String get viewFile => _en ? 'View file' : '查看文件';

  String get collapseServerList => _en ? 'Collapse server list' : '折叠服务器列表';
  String get expandServerList => _en ? 'Expand server list' : '展开服务器列表';
  String get reorderServer => _en ? 'Reorder server' : '调整服务器顺序';

  String get addFavoritePath => _en ? 'Add favorite path' : '收藏当前路径';
  String get noFavoritePaths => _en ? 'No favorite paths' : '暂无收藏路径';
  String get noRecentPaths => _en ? 'No recent paths' : '暂无最近路径';
  String get pathHistoryLoadFailed =>
      _en ? 'Could not load path history' : '无法加载路径记录';
  String get pathHistoryLoadFailedHint => _en
      ? 'Recent and favorite paths could not be read. Try again.'
      : '无法读取最近路径和收藏路径，请重试。';

  String get directoryLoadFailed =>
      _en ? 'Could not load this directory' : '无法加载此目录';
  String get directoryLoadFailedHint => _en
      ? 'Check the SFTP connection and permissions, then try again.'
      : '请检查 SFTP 连接和目录权限，然后重试。';
  String get downloadFile => _en ? 'Download file' : '下载文件';
  String downloadingFile(String name) =>
      _en ? 'Downloading $name' : '正在下载 $name';
  String get downloadComplete => _en ? 'Download complete' : '下载完成';
  String downloadFailed(Object error) =>
      _en ? 'Download failed: $error' : '下载失败：$error';
  String get downloadCancelled => _en ? 'Download cancelled' : '已取消下载';
  String get uploadComplete => _en ? 'Upload complete' : '上传完成';
  String uploadingFile(String name) => _en ? 'Uploading $name' : '正在上传 $name';
  String uploadFailed(Object error) =>
      _en ? 'Upload failed: $error' : '上传失败：$error';
  String get uploadCancelled => _en ? 'Upload cancelled' : '已取消上传';
  String get uploadFileNoAccess =>
      _en ? 'The selected file is not accessible.' : '无法访问选择的文件。';
  String uploadFileTooLarge(String limit) =>
      _en ? 'File is larger than $limit' : '文件大小超过了 $limit';
  String downloadFileTooLarge(String limit) =>
      _en ? 'File is larger than $limit' : '文件大小超过了 $limit';
  String get lanShareSendToNearby =>
      _en ? 'Nearby sharing is not available here yet.' : '附近分享暂未在此处开放。';

  String get deleteRemoteEntry => _en ? 'Delete remote entry' : '删除远程项目';
  String deleteRemoteEntryContent(String name) =>
      _en ? 'Delete "$name" from the server?' : '从服务器删除 "$name"？';
  String get deleteRemoteEntryConfirmPrompt =>
      _en ? 'Type the exact name to confirm:' : '请输入完整名称确认：';
  String get deleteRemoteEntryConfirmLabel => _en ? 'Entry name' : '文件或目录名称';
  String get deleteRemoteEntryConfirmMismatch =>
      _en ? 'Name does not match.' : '名称不匹配。';
  String get deleteComplete => _en ? 'Deleted' : '已删除';
  String get filePreviewLoadFailed =>
      _en ? 'Could not load this preview' : '无法加载此文件预览';
  String get filePreviewLoadFailedHint => _en
      ? 'Check the SFTP connection and file permissions, then try again.'
      : '请检查 SFTP 连接和文件权限，然后重试。';
  String get filePreviewTooLarge =>
      _en ? 'This file is too large to preview' : '文件过大，无法预览';
  String filePreviewTooLargeHint(int maxBytes) => _en
      ? 'File exceeds ${_fileSizeLimitLabel(maxBytes)} preview limit. Return and download file.'
      : '安全预览上限为 ${_fileSizeLimitLabel(maxBytes)}。请返回文件列表，下载后再查看。';
  String get filePreviewResourceLimit =>
      _en ? 'This file is too complex to preview safely' : '文件复杂度过高，无法安全预览';
  String get filePreviewResourceLimitHint => _en
      ? 'Complexity exceeds in-app rendering budget. Download to view.'
      : '文件复杂度超过应用内渲染预算，请下载后查看。';
  String get closePreview => _en ? 'Back to files' : '返回文件列表';
  String get filePreviewRenderFailed =>
      _en ? 'Could not display this preview' : '无法显示此文件预览';
  String get filePreviewRenderFailedHint => _en
      ? 'The file may be damaged or use an unsupported format. Try loading it again.'
      : '文件可能已损坏或使用了不支持的格式，请重新加载。';
  String get unsupportedPreviewTitle => _en ? 'No preview available' : '暂不支持预览';
  String get previewMode => _en ? 'Preview mode' : '预览模式';
  String get htmlPreviewUnavailable =>
      _en ? 'HTML preview is unavailable here' : '当前平台无法渲染 HTML';
  String get htmlPreviewUnavailableHint => _en
      ? 'Rendered HTML preview is available on Android, iOS, and macOS. You can still inspect the source safely.'
      : 'HTML 渲染预览支持 Android、iOS 和 macOS；你仍可安全查看源码。';
  String get pdfPreviewUnavailable =>
      _en ? 'Remote PDF preview is disabled' : '已禁用远程 PDF 预览';
  String get pdfPreviewUnavailableHint => _en
      ? 'Download PDF to open in a trusted reader.'
      : '为避免在应用内解析不受信任的文档，请下载后使用可信的 PDF 阅读器打开。';
  String get viewSource => _en ? 'View source' : '查看源码';
  String get externalPreviewContentBlocked =>
      _en ? 'External preview content is blocked' : '已阻止预览中的外部内容';
  String get previewKindImage => _en ? 'Image' : '图片';
  String get previewKindPdf => _en ? 'PDF document' : 'PDF 文档';
  String get previewKindMarkdown => 'Markdown';
  String get previewKindHtml => _en ? 'HTML document' : 'HTML 文档';
  String get previewKindText => _en ? 'Text file' : '文本文件';
  String get previewKindUnsupported => _en ? 'File' : '文件';
  String previewFileDetails(String kind, String size) => '$kind · $size';
  String get imagePreviewLabel => _en ? 'Image preview' : '图片预览';
  String get htmlPreviewLabel => _en ? 'HTML preview' : 'HTML 预览';
  String get zoomOut => _en ? 'Zoom out' : '缩小';
  String get zoomIn => _en ? 'Zoom in' : '放大';
  String get resetZoom => _en ? 'Reset zoom' : '重置缩放';
  String imageZoomLevel(int percent) => _en ? 'Zoom $percent%' : '缩放 $percent%';

  String editRemoteFile(String name) => _en ? 'Edit "$name"' : '编辑 "$name"';
  String get remoteFileContent => _en ? 'Remote file content' : '远程文件内容';
  String get remoteFileOpenFailed =>
      _en ? 'Could not open this file' : '无法打开此文件';
  String get remoteFileOpenFailedHint => _en
      ? 'Check the SFTP connection and file permissions, then try again.'
      : '请检查 SFTP 连接和文件权限，然后重试。';
  String get remoteFileSaved => _en ? 'All changes saved' : '所有修改均已保存';
  String get remoteFileUnsaved => _en ? 'Unsaved changes' : '有未保存的修改';
  String get saveRemoteFile => _en ? 'Save remote file' : '保存远程文件';
  String get savingRemoteFile => _en ? 'Saving remote file…' : '正在保存远程文件…';
  String get saveComplete => _en ? 'Saved' : '已保存';
  String get remoteFileSaveFailed => _en
      ? 'Could not save this file. Check the connection and try again.'
      : '无法保存此文件，请检查连接后重试。';
  String remoteFileTooLarge(int maxBytes) => _en
      ? 'File exceeds ${_fileSizeLimitLabel(maxBytes)} edit limit.'
      : '文件超过 ${_fileSizeLimitLabel(maxBytes)} 编辑限制。';
  String get remoteFileNewChangesRemain => _en
      ? 'Earlier changes were saved. New edits are still unsaved.'
      : '先前修改已保存，新的编辑仍未保存。';
  String get discardChangesTitle => _en ? 'Discard changes?' : '放弃修改？';
  String get discardChangesContent => _en
      ? 'You have unsaved changes. Discard them and leave?'
      : '有未保存的修改，确定放弃并离开吗？';
  String get remoteFilePath => _en ? 'Remote path' : '远程路径';
  String get editorControls => _en ? 'Editor controls' : '编辑器控制';
  String get editorFontSize => _en ? 'Font size' : '字号';
  String fontSizeValue(int value) => _en ? 'Font size $value' : '字号 $value';
  String get smallerFont => _en ? 'Smaller font' : '缩小字号';
  String get largerFont => _en ? 'Larger font' : '放大字号';
  String get disableLineWrap => _en ? 'Disable line wrap' : '关闭自动换行';
  String get enableLineWrap => _en ? 'Enable line wrap' : '开启自动换行';
  String get remoteFilePathLabel => _en ? 'Remote path' : '远程路径';

  String get sftpDownloadLimit => _en ? 'Download Limit' : '下载限制';
  String get sftpTextPreviewLimit => _en ? 'Text Preview' : '文本预览限制';
  String get sftpRichPreviewLimit => _en ? 'Image/PDF Preview' : '图片/PDF 预览限制';
  String get sftpEditLimit => _en ? 'Text Edit' : '文本编辑限制';
  String get sftpLimitDialogHint => _en
      ? 'Enter a size in MB. Decimal values are allowed.'
      : '请输入 MB 单位大小，支持小数。';
  String get sftpLimitInvalid =>
      _en ? 'Enter a value greater than 0.' : '请输入大于 0 的数值。';
  String sftpLimitRange(String min, String max) =>
      _en ? 'Allowed range: $min - $max' : '允许范围：$min - $max';

  String _fileSizeLimitLabel(int bytes) {
    final mb = bytes / (1024 * 1024);
    if (mb >= 1) {
      return '${mb.toStringAsFixed(mb == mb.roundToDouble() ? 0 : 1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}
