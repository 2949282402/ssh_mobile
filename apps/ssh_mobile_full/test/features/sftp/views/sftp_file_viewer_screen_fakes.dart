part of 'sftp_file_viewer_screen_test.dart';

class _ViewerLauncher extends StatelessWidget {
  const _ViewerLauncher({
    required this.entry,
    required this.readBytes,
    required this.htmlBuilder,
    required this.imageProviderBuilder,
  });

  final SftpEntry entry;
  final SftpViewerReadBytes readBytes;
  final SftpViewerHtmlBuilder? htmlBuilder;
  final SftpViewerImageProviderBuilder? imageProviderBuilder;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const ValueKey('open-sftp-viewer'),
          onPressed: () {
            Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (context) => SftpFileViewerScreen.forTesting(
                  entry: entry,
                  readBytesForTesting: readBytes,
                  htmlBuilderForTesting: htmlBuilder,
                  imageProviderBuilderForTesting: imageProviderBuilder,
                ),
              ),
            );
          },
          child: const Text('Open viewer'),
        ),
      ),
    );
  }
}

class _TestAppSettings extends ChangeNotifier implements SftpSettingsPort {
  _TestAppSettings({
    required this.language,
    this.textLimitBytes = 2 * 1024 * 1024,
    this.richLimitBytes = 20 * 1024 * 1024,
  });

  @override
  SftpLanguage language;
  final int textLimitBytes;
  final int richLimitBytes;

  @override
  int get sftpTextPreviewLimitBytes => textLimitBytes;

  @override
  int get sftpRichPreviewLimitBytes => richLimitBytes;

  @override
  int get sftpDownloadLimitBytes => 512 * 1024 * 1024;

  @override
  int get sftpTextEditLimitBytes => 512 * 1024;

  @override
  Future<void> setSftpDownloadLimitBytes(int bytes) async {}

  @override
  Future<void> setSftpTextPreviewLimitBytes(int bytes) async {}

  @override
  Future<void> setSftpRichPreviewLimitBytes(int bytes) async {}

  @override
  Future<void> setSftpTextEditLimitBytes(int bytes) async {}

  void setLanguage(SftpLanguage nextLanguage) {
    if (language == nextLanguage) return;
    language = nextLanguage;
    notifyListeners();
  }
}

SftpEntry _entry({
  required String name,
  String? path,
  int? size,
  String? sizeLabel,
}) {
  return SftpEntry(
    connectionId: 'server-1',
    targetFingerprint: 'target-1',
    name: name,
    path: path ?? '/srv/$name',
    lowerName: name.toLowerCase(),
    isDirectory: false,
    isLink: false,
    size: size,
    sizeLabel: sizeLabel ?? (size == null ? 'Unknown size' : '$size B'),
  );
}

final Uint8List _testPng = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAARSURBVBhXY9DPf/sfhBlgDABVngopRVqb1AAAAABJRU5ErkJggg==',
  ),
);

class _SynchronousImageProvider
    extends ImageProvider<_SynchronousImageProvider> {
  const _SynchronousImageProvider(this.image);

  final ui.Image image;

  @override
  Future<_SynchronousImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) => SynchronousFuture<_SynchronousImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _SynchronousImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      SynchronousFuture<ImageInfo>(ImageInfo(image: image)),
    );
  }
}
