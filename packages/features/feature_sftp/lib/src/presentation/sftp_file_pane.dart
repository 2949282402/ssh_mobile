part of 'sftp_screen.dart';

class _FilePane extends StatelessWidget {
  final SftpStrings strings;
  final SftpViewModel sftp;

  const _FilePane({required this.strings, required this.sftp});

  @override
  Widget build(BuildContext context) {
    final snapshot = context.select<SftpViewModel, _SftpPaneStatusSnapshot>(
      _SftpPaneStatusSnapshot.from,
    );

    if (snapshot.state == SftpConnectionState.disconnected) {
      return _SftpEmptyState(strings: strings);
    }

    return Column(
      children: [
        _SftpFileToolbar(
          strings: strings,
          currentPath: snapshot.currentPath,
          disabled: snapshot.isBusy,
          onParent: sftp.openParent,
          onPath: () =>
              _showPathHistorySheet(context, sftp, snapshot.currentPath),
          onRefresh: sftp.refresh,
          onUpload: () => _uploadFile(context),
          onDisconnect: sftp.disconnect,
          onSettings: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const SftpSettingsScreen())),
        ),
        if (snapshot.isBusy && snapshot.activeTransfer == null)
          Semantics(
            label: strings.loadingDirectory,
            child: const LinearProgressIndicator(minHeight: 2),
          ),
        if (snapshot.activeTransfer != null)
          _SftpTransferBanner(
            strings: strings,
            sftp: sftp,
            activeTransfer: snapshot.activeTransfer!,
          ),
        if (snapshot.state == SftpConnectionState.error &&
            snapshot.errorMessage != null)
          _SftpDirectoryErrorCard(
            strings: strings,
            message: snapshot.errorMessage!,
            onRetry: () => sftp.retry(
              onUnknownHostKey: (request) =>
                  context.read<SftpHostKeyConfirmationPort>().confirm(request),
            ),
          ),
        Expanded(
          child: _SftpEntryList(
            strings: strings,
            sftp: sftp,
            busy: snapshot.isBusy,
            onEntryAction: _handleEntryAction,
            entryMeta: _entryMeta,
          ),
        ),
      ],
    );
  }
}
