import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/connection.dart';
import '../../../../services/app_log_service.dart';
import '../../../../services/app_settings.dart';
import '../../../../widgets/ssh_host_key_trust_dialog.dart';
import '../../../../widgets/section_card.dart';
import '../../../../widgets/responsive_row_or_column.dart';
import '../viewmodels/connection_viewmodel.dart';

class AddEditScreen extends StatefulWidget {
  final String? editId;

  const AddEditScreen({super.key, this.editId});

  @override
  State<AddEditScreen> createState() => _AddEditScreenState();
}

class _AddEditScreenState extends State<AddEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '22');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _privateKeyController = TextEditingController();
  final _jumpHostController = TextEditingController();
  final _jumpPortController = TextEditingController(text: '22');
  final _jumpUsernameController = TextEditingController();
  final _tmuxAutoDeleteController = TextEditingController(text: '10');

  AuthMethod _authMethod = AuthMethod.password;
  TerminalLaunchMode _launchMode = TerminalLaunchMode.tmux;
  ServerPlatform _serverPlatform = ServerPlatform.linux;
  bool _keepAlive = true;
  bool _obscurePassword = true;
  bool _isLoadingSecrets = false;
  bool _jumpHostExpanded = false;
  bool _advancedExpanded = false;
  bool _privateKeyExpanded = false;

  bool get isEditing => widget.editId != null;

  int _secondsToDisplayMinutes(int seconds) {
    return ((seconds + 59) ~/ 60).clamp(1, 1440);
  }

  int _tmuxAutoDeleteSecondsFromInput() {
    final minutes = int.tryParse(_tmuxAutoDeleteController.text.trim()) ?? 10;
    return minutes.clamp(1, 1440) * 60;
  }

  AppStrings _strings(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    return AppStrings(language);
  }

  @override
  void initState() {
    super.initState();
    if (isEditing) _loadExistingConfig();
  }

  void _loadExistingConfig() {
    final connectionViewModel = context.read<ConnectionViewModel>();
    final config = connectionViewModel.getConnection(widget.editId!);
    if (config == null) return;

    _nameController.text = config.name;
    _hostController.text = config.host;
    _portController.text = config.port.toString();
    _usernameController.text = config.username;
    _authMethod = config.authMethod;
    _launchMode = config.launchMode;
    _serverPlatform = config.serverPlatform;
    if (_serverPlatform == ServerPlatform.windows &&
        _launchMode == TerminalLaunchMode.tmux) {
      _launchMode = TerminalLaunchMode.ssh;
    }
    _keepAlive = config.keepAlive;
    _tmuxAutoDeleteController.text =
        _secondsToDisplayMinutes(config.tmuxAutoDeleteSeconds).toString();
    _jumpHostController.text = config.jumpHost ?? '';
    _jumpPortController.text = config.jumpPort?.toString() ?? '22';
    _jumpUsernameController.text = config.jumpUsername ?? '';

    _jumpHostExpanded = config.jumpHost != null && config.jumpHost!.isNotEmpty;
    final minutes = _secondsToDisplayMinutes(config.tmuxAutoDeleteSeconds);
    _advancedExpanded = config.serverPlatform != ServerPlatform.linux ||
        config.launchMode != TerminalLaunchMode.tmux ||
        !config.keepAlive ||
        minutes != 10;

    _loadSecrets(config.id);
  }

  Future<void> _loadSecrets(String id) async {
    setState(() => _isLoadingSecrets = true);

    final connectionViewModel = context.read<ConnectionViewModel>();
    final password = await connectionViewModel.getPassword(id);
    final privateKey = await connectionViewModel.getPrivateKey(id);

    if (!mounted) return;
    _passwordController.text = password ?? '';
    _privateKeyController.text = privateKey ?? '';
    setState(() => _isLoadingSecrets = false);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _privateKeyController.dispose();
    _jumpHostController.dispose();
    _jumpPortController.dispose();
    _jumpUsernameController.dispose();
    _tmuxAutoDeleteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = _strings(context);
    final isSaving =
        context.select<ConnectionViewModel, bool>((vm) => vm.isSaving);
    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? strings.editConnection : strings.addConnection),
        actions: [
          TextButton.icon(
            onPressed: isSaving || _isLoadingSecrets ? null : _save,
            icon: isSaving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: Text(isSaving ? strings.saving : strings.save),
          ),
        ],
      ),
      body: _isLoadingSecrets
          ? const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
                children: [
                  SectionCard(
                    title: strings.basicInfo,
                    children: [
                      _buildNameField(),
                    ],
                  ),
                  SectionCard(
                    title: strings.connectionInfo,
                    children: [
                      _buildHostField(),
                      const SizedBox(height: 12),
                      ResponsiveRowOrColumn(
                        flexes: const [2, 3],
                        children: [
                          _buildPortField(),
                          _buildUsernameField(),
                        ],
                      ),
                    ],
                  ),
                  SectionCard(
                    title: strings.authMethod,
                    children: [
                      _buildAuthMethodSelector(),
                      const SizedBox(height: 12),
                      if (_authMethod == AuthMethod.password ||
                          _authMethod == AuthMethod.both)
                        _buildPasswordField(),
                      if (_authMethod == AuthMethod.privateKey ||
                          _authMethod == AuthMethod.both) ...[
                        const SizedBox(height: 12),
                        _buildPrivateKeyField(),
                      ],
                    ],
                  ),
                  SectionCard(
                    title: strings.jumpHostOptional,
                    isCollapsible: true,
                    isExpanded: _jumpHostExpanded,
                    onToggle: () =>
                        setState(() => _jumpHostExpanded = !_jumpHostExpanded),
                    children: [
                      _buildJumpHostField(),
                      const SizedBox(height: 12),
                      ResponsiveRowOrColumn(
                        flexes: const [2, 3],
                        children: [
                          _buildJumpPortField(),
                          _buildJumpUsernameField(),
                        ],
                      ),
                    ],
                  ),
                  SectionCard(
                    title: strings.advancedOptions,
                    isCollapsible: true,
                    isExpanded: _advancedExpanded,
                    onToggle: () =>
                        setState(() => _advancedExpanded = !_advancedExpanded),
                    children: [
                      _buildServerPlatformSelector(),
                      const SizedBox(height: 16),
                      _buildLaunchModeSelector(),
                      if (_launchMode == TerminalLaunchMode.tmux) ...[
                        const SizedBox(height: 12),
                        _buildTmuxAutoDeleteField(),
                      ],
                      const SizedBox(height: 12),
                      _buildKeepAliveSwitch(),
                    ],
                  ),
                ],
              ),
            ),
      bottomNavigationBar: MediaQuery.of(context).viewInsets.bottom > 0
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: FilledButton.icon(
                  onPressed: isSaving || _isLoadingSecrets ? null : _save,
                  icon: isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.check_rounded),
                  label: Text(
                    isSaving ? strings.saving : _text('Verify & Save', '验证并保存'),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildNameField() {
    final strings = _strings(context);
    return TextFormField(
      controller: _nameController,
      decoration: InputDecoration(
        labelText: strings.connectionName,
        hintText: strings.connectionNameHint,
        prefixIcon: const Icon(Icons.label_outline),
      ),
      validator: (value) => value == null || value.trim().isEmpty
          ? strings.enterConnectionName
          : null,
    );
  }

  Widget _buildHostField() {
    final strings = _strings(context);
    return TextFormField(
      controller: _hostController,
      decoration: InputDecoration(
        labelText: strings.hostAddress,
        hintText: strings.hostAddressHint,
        prefixIcon: const Icon(Icons.computer),
      ),
      keyboardType: TextInputType.url,
      validator: (value) => value == null || value.trim().isEmpty
          ? strings.enterHostAddress
          : null,
    );
  }

  Widget _buildPortField() {
    final strings = _strings(context);
    return TextFormField(
      controller: _portController,
      decoration: InputDecoration(
        labelText: strings.port,
        hintText: '22',
        prefixIcon: const Icon(Icons.numbers),
      ),
      keyboardType: TextInputType.number,
      validator: (value) {
        final port = int.tryParse(value ?? '');
        if (port == null || port < 1 || port > 65535) {
          return strings.invalidPort;
        }
        return null;
      },
    );
  }

  Widget _buildUsernameField() {
    final strings = _strings(context);
    return TextFormField(
      controller: _usernameController,
      decoration: InputDecoration(
        labelText: strings.username,
        hintText: 'root',
        prefixIcon: const Icon(Icons.person_outline),
      ),
      validator: (value) =>
          value == null || value.trim().isEmpty ? strings.enterUsername : null,
    );
  }

  Widget _buildAuthMethodSelector() {
    final strings = _strings(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<AuthMethod>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(
            value: AuthMethod.password,
            label: Text(
              strings.password,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            icon: const Icon(Icons.lock_outline, size: 18),
          ),
          ButtonSegment(
            value: AuthMethod.privateKey,
            label: Text(
              strings.privateKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            icon: const Icon(Icons.key, size: 18),
          ),
          ButtonSegment(
            value: AuthMethod.both,
            label: Text(
              strings.privateKeyPassword,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            icon: const Icon(Icons.enhanced_encryption, size: 18),
          ),
        ],
        selected: {_authMethod},
        onSelectionChanged: (set) => setState(() => _authMethod = set.first),
      ),
    );
  }

  Widget _buildPasswordField() {
    final strings = _strings(context);
    return TextFormField(
      controller: _passwordController,
      obscureText: _obscurePassword,
      decoration: InputDecoration(
        labelText: strings.password,
        hintText: strings.passwordHint,
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          icon: Icon(
            _obscurePassword ? Icons.visibility_off : Icons.visibility,
            size: 20,
          ),
          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
        ),
      ),
      validator: (value) {
        if (_authMethod == AuthMethod.password &&
            (value == null || value.trim().isEmpty)) {
          return strings.passwordRequired;
        }
        return null;
      },
    );
  }

  Widget _buildPrivateKeyField() {
    final strings = _strings(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: _privateKeyController,
          maxLines: _privateKeyExpanded ? 15 : 4,
          decoration: InputDecoration(
            labelText: strings.sshPrivateKey,
            hintText:
                '-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----',
            prefixIcon: const Icon(Icons.key),
            alignLabelWithHint: true,
          ),
          validator: (value) {
            if (_authMethod == AuthMethod.privateKey &&
                (value == null || value.trim().isEmpty)) {
              return strings.privateKeyRequired;
            }
            return null;
          },
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.paste_rounded, size: 16),
              label: Text(_text('Paste Private Key', '粘贴私钥')),
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) {
                  setState(() {
                    _privateKeyController.text = data!.text!;
                  });
                }
              },
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              icon: Icon(
                _privateKeyExpanded
                    ? Icons.unfold_less_rounded
                    : Icons.unfold_more_rounded,
                size: 16,
              ),
              label: Text(_privateKeyExpanded
                  ? _text('Collapse', '折叠')
                  : _text('Expand', '展开')),
              onPressed: () {
                setState(() {
                  _privateKeyExpanded = !_privateKeyExpanded;
                });
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildJumpHostField() {
    final strings = _strings(context);
    return TextFormField(
      controller: _jumpHostController,
      decoration: InputDecoration(
        labelText: strings.jumpHost,
        hintText: strings.jumpHostHint,
        prefixIcon: const Icon(Icons.hub_outlined),
      ),
    );
  }

  Widget _buildJumpPortField() {
    final strings = _strings(context);
    return TextFormField(
      controller: _jumpPortController,
      decoration: InputDecoration(
        labelText: strings.jumpPort,
        hintText: '22',
      ),
      keyboardType: TextInputType.number,
    );
  }

  Widget _buildJumpUsernameField() {
    final strings = _strings(context);
    return TextFormField(
      controller: _jumpUsernameController,
      decoration: InputDecoration(
        labelText: strings.jumpUsername,
        hintText: strings.optional,
      ),
    );
  }

  Widget _buildLaunchModeSelector() {
    final strings = _strings(context);
    final supportsTmux = _serverPlatform == ServerPlatform.linux;
    final selectedLaunchMode =
        supportsTmux ? _launchMode : TerminalLaunchMode.ssh;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<TerminalLaunchMode>(
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(
                value: TerminalLaunchMode.ssh,
                label: Text('SSH', maxLines: 1),
                icon: Icon(Icons.terminal, size: 18),
              ),
              if (supportsTmux)
                const ButtonSegment(
                  value: TerminalLaunchMode.tmux,
                  label: Text('SSH + tmux', maxLines: 1),
                  icon: Icon(Icons.tab_rounded, size: 18),
                ),
            ],
            selected: {selectedLaunchMode},
            onSelectionChanged: (set) =>
                setState(() => _launchMode = set.first),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          !supportsTmux
              ? _text(
                  'Windows OpenSSH uses a normal interactive shell. tmux is only available if you connect to Linux/WSL and tmux is installed.',
                  'Windows OpenSSH 使用普通交互式 shell。tmux 只适用于 Linux/WSL 且服务器已安装 tmux 的场景。',
                )
              : _launchMode == TerminalLaunchMode.tmux
                  ? strings.tmuxModeDescription
                  : strings.sshModeDescription,
          style: TextStyle(
            fontSize: 12,
            color:
                Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.62),
          ),
        ),
      ],
    );
  }

  Widget _buildServerPlatformSelector() {
    final isWindows = _serverPlatform == ServerPlatform.windows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _text('Server system', '服务器系统'),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<ServerPlatform>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: ServerPlatform.linux,
                label: Text('Linux', maxLines: 1),
                icon: Icon(Icons.dns_outlined, size: 18),
              ),
              ButtonSegment(
                value: ServerPlatform.windows,
                label: Text('Windows', maxLines: 1),
                icon: Icon(Icons.desktop_windows_outlined, size: 18),
              ),
            ],
            selected: {_serverPlatform},
            onSelectionChanged: (set) {
              setState(() {
                _serverPlatform = set.first;
                if (_serverPlatform == ServerPlatform.windows) {
                  _launchMode = TerminalLaunchMode.ssh;
                }
              });
            },
          ),
        ),
        const SizedBox(height: 6),
        Text(
          isWindows
              ? _text(
                  'Windows monitoring uses PowerShell diagnostics; terminal mode stays plain SSH.',
                  'Windows 监控会使用 PowerShell 诊断命令；终端模式固定为普通 SSH。',
                )
              : _text(
                  'Default. Supports normal SSH and SSH + tmux when tmux is installed on the server.',
                  '默认选项。服务器安装 tmux 时支持普通 SSH 和 SSH + tmux。',
                ),
          style: TextStyle(
            fontSize: 12,
            color:
                Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.62),
          ),
        ),
      ],
    );
  }

  Widget _buildTmuxAutoDeleteField() {
    final strings = _strings(context);
    return TextFormField(
      controller: _tmuxAutoDeleteController,
      decoration: InputDecoration(
        labelText: strings.tmuxAutoDeleteMinutes,
        hintText: '10',
        helperText: strings.tmuxAutoDeleteHelp,
        prefixIcon: const Icon(Icons.timer_outlined),
      ),
      keyboardType: TextInputType.number,
      validator: (value) {
        if (_launchMode != TerminalLaunchMode.tmux) return null;
        final minutes = int.tryParse(value?.trim() ?? '');
        if (minutes == null || minutes < 1) return strings.minOneMinute;
        if (minutes > 1440) return strings.max1440Minutes;
        return null;
      },
    );
  }

  Widget _buildKeepAliveSwitch() {
    final strings = _strings(context);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(strings.keepAliveTitle),
      subtitle:
          Text(strings.keepAliveSubtitle, style: const TextStyle(fontSize: 12)),
      value: _keepAlive,
      activeThumbColor: Theme.of(context).colorScheme.secondary,
      onChanged: (value) => setState(() => _keepAlive = value),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final connectionViewModel = context.read<ConnectionViewModel>();

    ConnectionConfig? config;
    try {
      final effectiveLaunchMode = _serverPlatform == ServerPlatform.windows
          ? TerminalLaunchMode.ssh
          : _launchMode;
      final existing =
          isEditing ? connectionViewModel.getConnection(widget.editId!) : null;
      final host = _hostController.text.trim();
      final port = int.parse(_portController.text.trim());
      final keepHostKeyTrust =
          existing != null && existing.host == host && existing.port == port;
      config = ConnectionConfig(
        id: isEditing ? widget.editId! : const Uuid().v4(),
        name: _nameController.text.trim(),
        host: host,
        port: port,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        privateKey: _privateKeyController.text,
        authMethod: _authMethod,
        launchMode: effectiveLaunchMode,
        serverPlatform: _serverPlatform,
        tmuxAutoDeleteSeconds: _tmuxAutoDeleteSecondsFromInput(),
        keepAlive: _keepAlive,
        hostKeyFingerprint:
            keepHostKeyTrust ? existing.hostKeyFingerprint : null,
        hostKeyAlgorithm: keepHostKeyTrust ? existing.hostKeyAlgorithm : null,
        hostKeyTrustedAt: keepHostKeyTrust ? existing.hostKeyTrustedAt : null,
        jumpHost: _jumpHostController.text.isNotEmpty
            ? _jumpHostController.text.trim()
            : null,
        jumpPort: _jumpPortController.text.isNotEmpty
            ? int.tryParse(_jumpPortController.text.trim())
            : null,
        jumpUsername: _jumpUsernameController.text.isNotEmpty
            ? _jumpUsernameController.text.trim()
            : null,
      );

      final success = await connectionViewModel.verifyAndSaveConnection(
        config: config,
        isEditing: isEditing,
        rawPassword: _passwordController.text,
        rawPrivateKey: _privateKeyController.text,
        confirmDisconnectCallback: _confirmDisconnectActiveWindows,
        onUnknownHostKey: (request) =>
            showSshHostKeyTrustDialog(context, request),
      );

      if (success && mounted) {
        Navigator.pop(context, config.id);
      }
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to save connection config or verify SSH login',
        error: e,
        stackTrace: stackTrace,
        details: config == null
            ? null
            : 'host=${config.host} port=${config.port} user=${config.username} authMethod=${config.authMethod.name}',
      );
      if (mounted) {
        await _showSaveError(e);
      }
    }
  }

  String _text(String en, String zh) {
    return context.read<AppSettings>().isEnglish ? en : zh;
  }

  Future<void> _showSaveError(Object error) async {
    final strings = AppStrings(context.read<AppSettings>().language);
    final guidance = context.read<AppSettings>().isEnglish
        ? 'Please check the host address, port, username, password or private key, then save again.'
        : '请检查主机地址、端口、用户名、密码或私钥后重新保存。';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.save),
        content: Text(
          '${strings.saveFailed(error)}\n\n'
          '$guidance',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDisconnectActiveWindows(int windowCount) async {
    final strings = AppStrings(context.read<AppSettings>().language);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.saveWillCloseWindowsTitle),
        content: Text(strings.saveWillCloseWindowsContent(windowCount)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(strings.saveAndDisconnect),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
