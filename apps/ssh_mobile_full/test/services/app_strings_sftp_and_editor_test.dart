// Coverage tests for every localized string in AppStrings.

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  const en = AppStrings(AppLanguage.en);
  const zh = AppStrings(AppLanguage.zh);

  group('SFTP, preview, and remote editor strings', () {
    test(
      'every AppStrings SFTP, preview, and remote editor string is localized',
      () {
        _expectLocalized(en.sftp, zh.sftp);
        _expectLocalized(en.sftpServers, zh.sftpServers);
        _expectLocalized(en.collapseServerList, zh.collapseServerList);
        _expectLocalized(en.expandServerList, zh.expandServerList);
        _expectLocalized(en.sftpEmptyTitle, zh.sftpEmptyTitle);
        _expectLocalized(en.sftpEmptyHint, zh.sftpEmptyHint);
        _expectLocalized(en.parentDirectory, zh.parentDirectory);
        _expectLocalized(en.pathHistory, zh.pathHistory);
        _expectLocalized(en.inputPath, zh.inputPath);
        _expectLocalized(en.recentPaths, zh.recentPaths);
        _expectLocalized(en.favoritePaths, zh.favoritePaths);
        _expectLocalized(en.addFavoritePath, zh.addFavoritePath);
        _expectLocalized(en.removeFavoritePath, zh.removeFavoritePath);
        _expectLocalized(en.noRecentPaths, zh.noRecentPaths);
        _expectLocalized(en.noFavoritePaths, zh.noFavoritePaths);
        _expectLocalized(en.refresh, zh.refresh);
        _expectLocalized(en.retry, zh.retry);
        _expectLocalized(en.disconnect, zh.disconnect);
        _expectLocalized(en.emptyDirectory, zh.emptyDirectory);
        _expectLocalized(en.emptyDirectoryHint, zh.emptyDirectoryHint);
        _expectLocalized(en.loadingDirectory, zh.loadingDirectory);
        _expectLocalized(en.directoryLoadFailed, zh.directoryLoadFailed);
        _expectLocalized(
          en.directoryLoadFailedHint,
          zh.directoryLoadFailedHint,
        );
        _expectLocalized(en.openPath, zh.openPath);
        _expectLocalized(en.entryActions('sample'), zh.entryActions('sample'));
        _expectLocalized(en.pathHistoryLoadFailed, zh.pathHistoryLoadFailed);
        _expectLocalized(
          en.pathHistoryLoadFailedHint,
          zh.pathHistoryLoadFailedHint,
        );
        _expectLocalized(en.directory, zh.directory);
        _expectLocalized(en.uploadFile, zh.uploadFile);
        _expectLocalized(en.uploadComplete, zh.uploadComplete);
        _expectLocalized(en.uploadFailed('sample'), zh.uploadFailed('sample'));
        _expectLocalized(en.viewFile, zh.viewFile);
        _expectLocalized(en.preview, zh.preview);
        _expectLocalized(en.source, zh.source);
        _expectLocalized(en.previewMode, zh.previewMode);
        _expectLocalized(en.loadingFilePreview, zh.loadingFilePreview);
        _expectLocalized(en.filePreviewLoadFailed, zh.filePreviewLoadFailed);
        _expectLocalized(
          en.filePreviewLoadFailedHint,
          zh.filePreviewLoadFailedHint,
        );
        _expectLocalized(en.filePreviewTooLarge, zh.filePreviewTooLarge);
        _expectLocalized(
          en.filePreviewTooLargeHint(524288),
          zh.filePreviewTooLargeHint(524288),
        );
        _expectLocalized(
          en.filePreviewTooLargeHint(1048576),
          zh.filePreviewTooLargeHint(1048576),
        );
        _expectLocalized(
          en.filePreviewTooLargeHint(1572864),
          zh.filePreviewTooLargeHint(1572864),
        );
        _expectLocalized(
          en.filePreviewResourceLimit,
          zh.filePreviewResourceLimit,
        );
        _expectLocalized(
          en.filePreviewResourceLimitHint,
          zh.filePreviewResourceLimitHint,
        );
        _expectLocalized(en.closePreview, zh.closePreview);
        _expectLocalized(
          en.filePreviewRenderFailed,
          zh.filePreviewRenderFailed,
        );
        _expectLocalized(
          en.filePreviewRenderFailedHint,
          zh.filePreviewRenderFailedHint,
        );
        _expectLocalized(
          en.unsupportedPreviewTitle,
          zh.unsupportedPreviewTitle,
        );
        _expectLocalized(en.unsupportedPreview, zh.unsupportedPreview);
        _expectLocalized(en.htmlPreviewUnavailable, zh.htmlPreviewUnavailable);
        _expectLocalized(
          en.htmlPreviewUnavailableHint,
          zh.htmlPreviewUnavailableHint,
        );
        _expectLocalized(en.pdfPreviewUnavailable, zh.pdfPreviewUnavailable);
        _expectLocalized(
          en.pdfPreviewUnavailableHint,
          zh.pdfPreviewUnavailableHint,
        );
        _expectLocalized(en.viewSource, zh.viewSource);
        _expectLocalized(
          en.externalPreviewContentBlocked,
          zh.externalPreviewContentBlocked,
        );
        _expectLocalized(en.previewKindImage, zh.previewKindImage);
        _expectLocalized(en.previewKindPdf, zh.previewKindPdf);
        _expectLocalized(en.previewKindMarkdown, zh.previewKindMarkdown);
        _expectLocalized(en.previewKindHtml, zh.previewKindHtml);
        _expectLocalized(en.previewKindText, zh.previewKindText);
        _expectLocalized(en.previewKindUnsupported, zh.previewKindUnsupported);
        _expectLocalized(
          en.previewFileDetails('image', '12.5 KB'),
          zh.previewFileDetails('image', '12.5 KB'),
        );
        _expectLocalized(en.imagePreviewLabel, zh.imagePreviewLabel);
        _expectLocalized(en.htmlPreviewLabel, zh.htmlPreviewLabel);
        _expectLocalized(en.zoomOut, zh.zoomOut);
        _expectLocalized(en.zoomIn, zh.zoomIn);
        _expectLocalized(en.resetZoom, zh.resetZoom);
        _expectLocalized(en.imageZoomLevel(2), zh.imageZoomLevel(2));
        _expectLocalized(en.downloadFile, zh.downloadFile);
        _expectLocalized(en.downloadComplete, zh.downloadComplete);
        _expectLocalized(
          en.downloadFailed('sample'),
          zh.downloadFailed('sample'),
        );
        _expectLocalized(en.deleteRemoteEntry, zh.deleteRemoteEntry);
        _expectLocalized(
          en.deleteRemoteEntryContent('sample'),
          zh.deleteRemoteEntryContent('sample'),
        );
        _expectLocalized(en.deleteComplete, zh.deleteComplete);
        _expectLocalized(
          en.editRemoteFile('sample'),
          zh.editRemoteFile('sample'),
        );
        _expectLocalized(en.remoteFileContent, zh.remoteFileContent);
        _expectLocalized(en.loadingRemoteFile, zh.loadingRemoteFile);
        _expectLocalized(en.remoteFileOpenFailed, zh.remoteFileOpenFailed);
        _expectLocalized(
          en.remoteFileOpenFailedHint,
          zh.remoteFileOpenFailedHint,
        );
        _expectLocalized(
          en.openEditorFailed('sample'),
          zh.openEditorFailed('sample'),
        );
        _expectLocalized(en.saveComplete, zh.saveComplete);
        _expectLocalized(en.saveRemoteFile, zh.saveRemoteFile);
        _expectLocalized(en.savingRemoteFile, zh.savingRemoteFile);
        _expectLocalized(en.remoteFileSaveFailed, zh.remoteFileSaveFailed);
        _expectLocalized(
          en.remoteFileTooLarge(524288),
          zh.remoteFileTooLarge(524288),
        );
        _expectLocalized(
          en.remoteFileTooLarge(1048576),
          zh.remoteFileTooLarge(1048576),
        );
        _expectLocalized(
          en.remoteFileTooLarge(1572864),
          zh.remoteFileTooLarge(1572864),
        );
        _expectLocalized(
          en.remoteFileNewChangesRemain,
          zh.remoteFileNewChangesRemain,
        );
        _expectLocalized(en.remoteFilePath, zh.remoteFilePath);
        _expectLocalized(en.remoteFileSaved, zh.remoteFileSaved);
        _expectLocalized(en.remoteFileUnsaved, zh.remoteFileUnsaved);
        _expectLocalized(en.editorControls, zh.editorControls);
        _expectLocalized(en.editorFontSize, zh.editorFontSize);
        _expectLocalized(en.fontSizeValue(2), zh.fontSizeValue(2));
        _expectLocalized(en.smallerFont, zh.smallerFont);
        _expectLocalized(en.largerFont, zh.largerFont);
        _expectLocalized(en.enableLineWrap, zh.enableLineWrap);
        _expectLocalized(en.disableLineWrap, zh.disableLineWrap);
        _expectLocalized(en.discardChangesTitle, zh.discardChangesTitle);
        _expectLocalized(en.discardChangesContent, zh.discardChangesContent);
        _expectLocalized(en.discard, zh.discard);
        _expectLocalized(
          en.connectionFailed('sample'),
          zh.connectionFailed('sample'),
        );
        _expectLocalized(
          en.tmuxMissingHint('sample'),
          zh.tmuxMissingHint('sample'),
        );
      },
    );
  });
}

void _expectLocalized(String english, String chinese) {
  expect(english, isNotEmpty);
  expect(chinese, isNotEmpty);
}
