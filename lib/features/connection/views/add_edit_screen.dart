import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/connection.dart';
import '../../../../services/app_log_service.dart';
import '../../../../services/app_settings.dart';
import '../../../../utils/responsive.dart';
import '../../../../widgets/ssh_host_key_trust_dialog.dart';
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
  TerminalLaunchMode _launchMode = TerminalLaunchMode.ssh;
  ServerPlatform _serverPlatform = ServerPlatform.linux;
  bool _keepAlive = true;
  bool _obscurePassword = true;
  bool _isLoadingSecrets = false;
  bool _jumpHostExpanded = false;
  bool _advancedOptionsExpanded = false;

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
    _advancedOptionsExpanded = config.serverPlatform != ServerPlatform.linux ||
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

    final isDesktop = isDesktopLayout(context);

    final portAndUserRow = isDesktop
        ? Row(
            children: [
              Expanded(flex: 2, child: _buildPortField()),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: _buildUsernameField()),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildPortField(),
              const SizedBox(height: 12),
              _buildUsernameField(),
            ],
          );

    final jumpPortAndUserRow = isDesktop
        ? Row(
            children: [
              Expanded(flex: 2, child: _buildJumpPortField()),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: _buildJumpUsernameField()),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildJumpPortField(),
              const SizedBox(height: 12),
              _buildJumpUsernameField(),
            ],
          );

    final stickyActionBar = SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton(
            onPressed: isSaving || _isLoadingSecrets ? null : _save,
            child: isSaving
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(strings.saving),
                    ],
                  )
                : Text(
                    strings.language == AppLanguage.en
                        ? 'Verify & Save'
                        : '验证并保存',
                  ),
          ),
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? strings.editConnection : strings.addConnection),
        actions: [
          IconButton(
            onPressed: isSaving || _isLoadingSecrets ? null : _save,
            icon: isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            tooltip: strings.save,
          ),
        ],
      ),
      bottomNavigationBar:
          MediaQuery.viewInsetsOf(context).bottom > 0 ? null : stickyActionBar,
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
                  // 基础信息分组
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: ShadCard(
                      title: _section(strings.basicInfo),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 10),
                          _buildNameField(),
                        ],
                      ),
                    ),
                  ),

                  // 连接信息分组
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: ShadCard(
                      title: _section(strings.connectionInfo),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 10),
                          _buildHostField(),
                          const SizedBox(height: 12),
                          portAndUserRow,
                        ],
                      ),
                    ),
                  ),

                  // 认证信息分组
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: ShadCard(
                      title: _section(strings.authMethod),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 10),
                          _buildAuthMethodSelector(),
                          const SizedBox(height: 12),
                          if (_authMethod == AuthMethod.password ||
                              _authMethod == AuthMethod.both) ...[
                            _buildPasswordField(),
                            const SizedBox(height: 12),
                          ],
                          if (_authMethod == AuthMethod.privateKey ||
                              _authMethod == AuthMethod.both) ...[
                            _buildPrivateKeyField(),
                            const SizedBox(height: 12),
                          ],
                        ],
                      ),
                    ),
                  ),

                  // 跳板机分组（默认折叠）
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: ShadCard(
                      title: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _section(strings.jumpHostOptional),
                          IconButton(
                            icon: Icon(_jumpHostExpanded
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded),
                            onPressed: () => setState(
                                () => _jumpHostExpanded = !_jumpHostExpanded),
                          ),
                        ],
                      ),
                      child: _jumpHostExpanded
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 10),
                                _buildJumpHostField(),
                                const SizedBox(height: 12),
                                jumpPortAndUserRow,
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),

                  // 高级选项分组（默认折叠）
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: ShadCard(
                      title: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _section(strings.advancedOptions),
                          IconButton(
                            icon: Icon(_advancedOptionsExpanded
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded),
                            onPressed: () => setState(() =>
                                _advancedOptionsExpanded =
                                    !_advancedOptionsExpanded),
                          ),
                        ],
                      ),
                      child: _advancedOptionsExpanded
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 10),
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
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _section(String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w800,
        color: Theme.of(context).colorScheme.primary,
        letterSpacing: 0.6,
      ),
    );
  }

  Widget _buildNameField() {
    final strings = _strings(context);
    return ShadInputFormField(
      id: 'name',
      controller: _nameController,
      label: Text(strings.connectionName),
      placeholder: Text(strings.connectionNameHint),
      leading: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Icon(Icons.label_outline, size: 18),
      ),
      validator: (value) =>
          value.trim().isEmpty ? strings.enterConnectionName : null,
    );
  }

  Widget _buildHostField() {
    final strings = _strings(context);
    return ShadInputFormField(
      id: 'host',
      controller: _hostController,
      label: Text(strings.hostAddress),
      placeholder: Text(strings.hostAddressHint),
      leading: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Icon(Icons.computer, size: 18),
      ),
      keyboardType: TextInputType.url,
      validator: (value) =>
          value.trim().isEmpty ? strings.enterHostAddress : null,
    );
  }

  Widget _buildPortField() {
    final strings = _strings(context);
    return ShadInputFormField(
      id: 'port',
      controller: _portController,
      label: Text(strings.port),
      placeholder: const Text('22'),
      leading: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Icon(Icons.numbers, size: 18),
      ),
      keyboardType: TextInputType.number,
      validator: (value) {
        final port = int.tryParse(value);
        if (port == null || port < 1 || port > 65535) {
          return strings.invalidPort;
        }
        return null;
      },
    );
  }

  Widget _buildUsernameField() {
    final strings = _strings(context);
    return ShadInputFormField(
      id: 'username',
      controller: _usernameController,
      label: Text(strings.username),
      placeholder: const Text('root'),
      leading: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Icon(Icons.person_outline, size: 18),
      ),
      validator: (value) => value.trim().isEmpty ? strings.enterUsername : null,
    );
  }

  Widget _buildAuthMethodSelector() {
    final strings = _strings(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(
          label: Text(strings.password),
          avatar: const Icon(Icons.lock_outline, size: 16),
          selected: _authMethod == AuthMethod.password,
          onSelected: (selected) {
            if (selected) setState(() => _authMethod = AuthMethod.password);
          },
        ),
        ChoiceChip(
          label: Text(strings.privateKey),
          avatar: const Icon(Icons.key, size: 16),
          selected: _authMethod == AuthMethod.privateKey,
          onSelected: (selected) {
            if (selected) setState(() => _authMethod = AuthMethod.privateKey);
          },
        ),
        ChoiceChip(
          label: Text(strings.privateKeyPassword),
          avatar: const Icon(Icons.enhanced_encryption, size: 16),
          selected: _authMethod == AuthMethod.both,
          onSelected: (selected) {
            if (selected) setState(() => _authMethod = AuthMethod.both);
          },
        ),
      ],
    );
  }

  Widget _buildPasswordField() {
    final strings = _strings(context);
    return ShadInputFormField(
      id: 'password',
      controller: _passwordController,
      obscureText: _obscurePassword,
      label: Text(strings.password),
      placeholder: Text(strings.passwordHint),
      leading: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Icon(Icons.lock_outline, size: 18),
      ),
      trailing: IconButton(
        icon: Icon(
          _obscurePassword ? Icons.visibility_off : Icons.visibility,
          size: 18,
        ),
        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
      ),
      validator: (value) {
        if (_authMethod == AuthMethod.password && value.trim().isEmpty) {
          return strings.passwordRequired;
        }
        return null;
      },
    );
  }

  Widget _buildPrivateKeyField() {
    final strings = _strings(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              strings.sshPrivateKey,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            TextButton.icon(
              icon: const Icon(Icons.paste_rounded, size: 16),
              label: Text(_text('Paste', '粘贴')),
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) {
                  setState(() {
                    _privateKeyController.text = data!.text!;
                  });
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 6),
        ShadInputFormField(
          id: 'privateKey',
          controller: _privateKeyController,
          maxLines: null,
          minLines: 4,
          placeholder: const Text(
            '-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----',
          ),
          leading: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.key, size: 18),
          ),
          validator: (value) {
            if (_authMethod == AuthMethod.privateKey && value.trim().isEmpty) {
              return strings.privateKeyRequired;
            }
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildJumpHostField() {
    final strings = _strings(context);
    return ShadInputFormField(
      id: 'jumpHost',
      controller: _jumpHostController,
      label: Text(strings.jumpHost),
      placeholder: Text(strings.jumpHostHint),
      leading: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Icon(Icons.hub_outlined, size: 18),
      ),
    );
  }

  Widget _buildJumpPortField() {
    final strings = _strings(context);
    return ShadInputFormField(
      id: 'jumpPort',
      controller: _jumpPortController,
      label: Text(strings.jumpPort),
      placeholder: const Text('22'),
    );
  }

  Widget _buildJumpUsernameField() {
    final strings = _strings(context);
    return ShadInputFormField(
      id: 'jumpUsername',
      controller: _jumpUsernameController,
      label: Text(strings.jumpUsername),
      placeholder: Text(strings.optional),
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
    return ShadInputFormField(
      id: 'tmuxAutoDelete',
      controller: _tmuxAutoDeleteController,
      label: Text(strings.tmuxAutoDeleteMinutes),
      placeholder: const Text('10'),
      description: Text(strings.tmuxAutoDeleteHelp),
      leading: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Icon(Icons.timer_outlined, size: 18),
      ),
      keyboardType: TextInputType.number,
      validator: (value) {
        if (_launchMode != TerminalLaunchMode.tmux) return null;
        final minutes = int.tryParse(value.trim());
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
