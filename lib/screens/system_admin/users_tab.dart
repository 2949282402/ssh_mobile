part of '../system_admin_screen.dart';

class _UsersTab extends StatefulWidget {
  final AppStrings strings;
  final ColorScheme colorScheme;
  final String connectionId;
  final List<LinuxUserAccount> accounts;
  final bool isLoading;
  final RefreshCallback onRefresh;

  const _UsersTab({
    required this.strings,
    required this.colorScheme,
    required this.connectionId,
    required this.accounts,
    required this.isLoading,
    required this.onRefresh,
  });

  @override
  State<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<_UsersTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.strings.switchToChinese == '中文'
                    ? 'Local Accounts'
                    : '本地账号列表',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.person_add),
                label: Text(widget.strings.createUser),
                onPressed: () =>
                    _openCreateUserDialog(widget.strings, widget.connectionId),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: widget.onRefresh,
            child: widget.accounts.isEmpty
                ? const Center(child: Text('No accounts found.'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: widget.accounts.length,
                    itemBuilder: (context, index) {
                      final account = widget.accounts[index];
                      return Card(
                        child: ExpansionTile(
                          leading: CircleAvatar(
                            backgroundColor: account.uid == 0
                                ? widget.colorScheme.errorContainer
                                : widget.colorScheme.primaryContainer,
                            child: Icon(
                              account.uid == 0 ? Icons.security : Icons.person,
                              color: account.uid == 0
                                  ? widget.colorScheme.onErrorContainer
                                  : widget.colorScheme.onPrimaryContainer,
                            ),
                          ),
                          title: Row(
                            children: [
                              Text(account.username,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              const SizedBox(width: 8),
                              Text('(${account.uid}/${account.gid})',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color:
                                          widget.colorScheme.onSurfaceVariant)),
                              const Spacer(),
                              if (account.isLocked)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: widget.colorScheme.error
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    widget.strings.lockUser,
                                    style: TextStyle(
                                        color: widget.colorScheme.error,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold),
                                  ),
                                )
                              else
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: widget.colorScheme.primary
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    widget.strings.unlockUser,
                                    style: TextStyle(
                                        color: widget.colorScheme.primary,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                            ],
                          ),
                          subtitle: OverflowScrollText(
                            '${account.homeDir}  •  ${account.shell}',
                            selectable: false,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 12,
                              color: widget.colorScheme.onSurface
                                  .withValues(alpha: 0.58),
                            ),
                          ),
                          children: [
                            _UserDetailActions(
                              connectionId: widget.connectionId,
                              account: account,
                              strings: widget.strings,
                              colorScheme: widget.colorScheme,
                              onStatusChanged: widget.onRefresh,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  void _openCreateUserDialog(AppStrings strings, String connectionId) {
    showDialog(
      context: context,
      builder: (context) => _CreateUserDialog(
        connectionId: connectionId,
        strings: strings,
        onCreated: widget.onRefresh,
      ),
    );
  }
}

class _UserDetailActions extends StatefulWidget {
  final String connectionId;
  final LinuxUserAccount account;
  final AppStrings strings;
  final ColorScheme colorScheme;
  final VoidCallback onStatusChanged;

  const _UserDetailActions({
    required this.connectionId,
    required this.account,
    required this.strings,
    required this.colorScheme,
    required this.onStatusChanged,
  });

  @override
  State<_UserDetailActions> createState() => _UserDetailActionsState();
}

class _UserDetailActionsState extends State<_UserDetailActions> {
  String _storageUsed = 'Loading...';
  bool _isAdmin = false;
  bool _loadingSudo = true;

  @override
  void initState() {
    super.initState();
    _loadStorageInfo();
    _loadSudoInfo();
  }

  Future<void> _loadStorageInfo() async {
    final adminService = context.read<SystemAdminService>();
    final size = await adminService.getUserHomeStorageUsage(
        widget.connectionId, widget.account.homeDir);
    if (!mounted) return;
    setState(() {
      _storageUsed = size;
    });
  }

  Future<void> _loadSudoInfo() async {
    final adminService = context.read<SystemAdminService>();
    final isAdmin = await adminService.checkUserSudo(
        widget.connectionId, widget.account.username);
    if (!mounted) return;
    setState(() {
      _isAdmin = isAdmin;
      _loadingSudo = false;
    });
  }

  Future<void> _toggleSudoPrivilege() async {
    setState(() => _loadingSudo = true);
    try {
      final admin = context.read<SystemAdminService>();
      await admin.setUserSudo(
          widget.connectionId, widget.account.username, !_isAdmin);
      await _loadSudoInfo();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingSudo = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('${widget.strings.storageUsed}: ',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(_storageUsed),
              const SizedBox(width: 24),
              Text('${widget.strings.sudoStatus}: ',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              _loadingSudo
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5))
                  : Text(_isAdmin
                      ? widget.strings.administrator
                      : widget.strings.normalUser),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                icon: Icon(
                    widget.account.isLocked ? Icons.lock_open : Icons.lock),
                label: Text(widget.account.isLocked
                    ? widget.strings.unlockUser
                    : widget.strings.lockUser),
                onPressed: _toggleUserLock,
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.password),
                label: Text(widget.strings.changePassword),
                onPressed: _openPasswordDialog,
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.folder_shared),
                label: Text(widget.strings.viewHomeDir),
                onPressed: _openHomeExplorer,
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.donut_large),
                label: Text(widget.strings.usageStats),
                onPressed: _openProcessesDialog,
              ),
              if (!_loadingSudo)
                ElevatedButton.icon(
                  icon: Icon(_isAdmin ? Icons.gpp_bad : Icons.verified_user),
                  label: Text(_isAdmin
                      ? widget.strings.revokeSudo
                      : widget.strings.grantSudo),
                  onPressed: _toggleSudoPrivilege,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _toggleUserLock() async {
    try {
      final admin = context.read<SystemAdminService>();
      if (widget.account.isLocked) {
        await admin.unlockUser(widget.connectionId, widget.account.username);
      } else {
        await admin.lockUser(widget.connectionId, widget.account.username);
      }
      widget.onStatusChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  void _openPasswordDialog() {
    showDialog(
      context: context,
      builder: (context) => _ChangePasswordDialog(
        connectionId: widget.connectionId,
        username: widget.account.username,
        strings: widget.strings,
      ),
    );
  }

  void _openHomeExplorer() {
    showDialog(
      context: context,
      builder: (context) => _HomeDirectoryExplorerDialog(
        connectionId: widget.connectionId,
        homeDir: widget.account.homeDir,
        strings: widget.strings,
      ),
    );
  }

  void _openProcessesDialog() {
    showDialog(
      context: context,
      builder: (context) => _UserProcessesDialog(
        connectionId: widget.connectionId,
        username: widget.account.username,
        strings: widget.strings,
      ),
    );
  }
}

// --- Change Password Dialog ---
class _ChangePasswordDialog extends StatefulWidget {
  final String connectionId;
  final String username;
  final AppStrings strings;

  const _ChangePasswordDialog({
    required this.connectionId,
    required this.username,
    required this.strings,
  });

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.strings.changePasswordTitle} (${widget.username})'),
      content: TextField(
        controller: _controller,
        obscureText: true,
        decoration: InputDecoration(
          labelText: widget.strings.enterNewPassword,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          child: Text(widget.strings.cancel),
          onPressed: () => Navigator.pop(context),
        ),
        FilledButton(
          onPressed: _busy ? null : _savePassword,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(widget.strings.save),
        ),
      ],
    );
  }

  Future<void> _savePassword() async {
    final newPwd = _controller.text.trim();
    if (newPwd.isEmpty) return;

    setState(() => _busy = true);
    try {
      await context.read<SystemAdminService>().changePassword(
            widget.connectionId,
            widget.username,
            newPwd,
          );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.strings.passwordChangedSuccess)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    }
  }
}

// --- Home Directory Explorer Dialog ---
class _HomeDirectoryExplorerDialog extends StatefulWidget {
  final String connectionId;
  final String homeDir;
  final AppStrings strings;

  const _HomeDirectoryExplorerDialog({
    required this.connectionId,
    required this.homeDir,
    required this.strings,
  });

  @override
  State<_HomeDirectoryExplorerDialog> createState() =>
      _HomeDirectoryExplorerDialogState();
}

class _HomeDirectoryExplorerDialogState
    extends State<_HomeDirectoryExplorerDialog> {
  late String _currentPath;
  List<SftpEntry> _entries = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.homeDir;
    _loadDirectory(_currentPath);
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final sftpService = context.read<SftpService>();
      final items = await sftpService.listDirectoryForConnection(
          widget.connectionId, path);
      if (!mounted) return;
      setState(() {
        _currentPath = path;
        _entries = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.strings.viewHomeDir),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              _currentPath,
              style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.normal),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: _buildContent(),
      ),
      actions: [
        if (_currentPath != widget.homeDir)
          TextButton(
            child: Text(widget.strings.switchToChinese == '中文'
                ? 'Back to Home'
                : '返回主目录'),
            onPressed: () => _loadDirectory(widget.homeDir),
          ),
        TextButton(
          child: Text(widget.strings.close),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  Widget _buildContent() {
    final colorScheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: colorScheme.error, size: 48),
            const SizedBox(height: 12),
            Text('Error listing files:\n$_error', textAlign: TextAlign.center),
          ],
        ),
      );
    }

    if (_entries.isEmpty) {
      return const Center(child: Text('This directory is empty.'));
    }

    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        final isSelf = entry.name == '.';
        if (isSelf) return const SizedBox.shrink();

        return ListTile(
          dense: true,
          leading: Icon(
            entry.isDirectory ? Icons.folder : Icons.insert_drive_file,
            color: entry.isDirectory ? Colors.amber : colorScheme.primary,
          ),
          title: Text(entry.name,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: entry.isDirectory ? null : Text(entry.sizeLabel),
          onTap: () {
            if (entry.isDirectory) {
              _loadDirectory(entry.path);
            } else {
              _viewFileDetail(entry);
            }
          },
        );
      },
    );
  }

  void _viewFileDetail(SftpEntry entry) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Size: ${entry.sizeLabel}'),
            if (entry.modifiedLabel != null)
              Text('Last Modified: ${entry.modifiedLabel}'),
            const SizedBox(height: 16),
            const Text(
              'Files can be full-edited, downloaded, or renamed from the SFTP tab.',
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ],
        ),
        actions: [
          TextButton(
            child: Text(widget.strings.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
}

// --- User Processes and Resource Usage Dialog ---
class _UserProcessesDialog extends StatefulWidget {
  final String connectionId;
  final String username;
  final AppStrings strings;

  const _UserProcessesDialog({
    required this.connectionId,
    required this.username,
    required this.strings,
  });

  @override
  State<_UserProcessesDialog> createState() => _UserProcessesDialogState();
}

class _UserProcessesDialogState extends State<_UserProcessesDialog> {
  List<LinuxUserProcess> _processes = [];
  bool _loading = false;
  double _totalMemoryMB = 0;

  @override
  void initState() {
    super.initState();
    _loadProcesses();
  }

  Future<void> _loadProcesses() async {
    setState(() => _loading = true);
    final admin = context.read<SystemAdminService>();
    final list = await admin.getUserProcessesAndMemory(
        widget.connectionId, widget.username);

    // Sum memory
    int totalBytes = 0;
    for (final p in list) {
      totalBytes += p.rssBytes;
    }

    if (!mounted) return;
    setState(() {
      _processes = list;
      _totalMemoryMB = totalBytes / (1024 * 1024);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text('${widget.strings.usageStats} (${widget.username})'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${widget.strings.memoryUsed}:',
                          style: TextStyle(
                              color: colorScheme.onSecondaryContainer,
                              fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${_totalMemoryMB.toStringAsFixed(2)} MB',
                          style: TextStyle(
                            color: colorScheme.onSecondaryContainer,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${widget.strings.activeProcesses} (${_processes.length}):',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _processes.isEmpty
                        ? const Center(child: Text('No active processes.'))
                        : ListView.builder(
                            itemCount: _processes.length,
                            itemBuilder: (context, index) {
                              final p = _processes[index];
                              final memMB = p.rssBytes / (1024 * 1024);
                              return Card(
                                child: ListTile(
                                  dense: true,
                                  title: OverflowScrollText(
                                    p.command,
                                    selectable: false,
                                    maxLines: 1,
                                    style: const TextStyle(
                                        fontFamily: 'monospace', fontSize: 12),
                                  ),
                                  subtitle: Text(
                                      'PID: ${p.pid}  •  CPU: ${p.cpuPercent}%  •  RAM: ${p.memPercent}%'),
                                  trailing:
                                      Text('${memMB.toStringAsFixed(1)} M'),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadProcesses,
        ),
        TextButton(
          child: Text(widget.strings.close),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }
}

class _CreateUserDialog extends StatefulWidget {
  final String connectionId;
  final AppStrings strings;
  final VoidCallback onCreated;

  const _CreateUserDialog({
    required this.connectionId,
    required this.strings,
    required this.onCreated,
  });

  @override
  State<_CreateUserDialog> createState() => _CreateUserDialogState();
}

class _CreateUserDialogState extends State<_CreateUserDialog> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _shellController = TextEditingController(text: '/bin/bash');
  bool _busy = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _shellController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.strings.createUser),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Username',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: widget.strings.enterNewPassword,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _shellController,
              decoration: InputDecoration(
                labelText: widget.strings.loginShell,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          child: Text(widget.strings.cancel),
          onPressed: () => Navigator.pop(context),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(widget.strings.save),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final user = _usernameController.text.trim();
    final pwd = _passwordController.text.trim();
    final sh = _shellController.text.trim();
    if (user.isEmpty || pwd.isEmpty) return;

    setState(() => _busy = true);
    try {
      final admin = context.read<SystemAdminService>();
      await admin.createUser(
        widget.connectionId,
        username: user,
        password: pwd,
        shell: sh,
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.strings.userCreatedSuccess)),
      );
      widget.onCreated();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    }
  }
}
