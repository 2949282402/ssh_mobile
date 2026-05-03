import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/connection.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';

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
  bool _keepAlive = true;
  bool _obscurePassword = true;
  bool _isSaving = false;
  bool _isLoadingSecrets = false;

  bool get isEditing => widget.editId != null;

  int _secondsToDisplayMinutes(int seconds) {
    return ((seconds + 59) ~/ 60).clamp(1, 1440);
  }

  int _tmuxAutoDeleteSecondsFromInput() {
    final minutes = int.tryParse(_tmuxAutoDeleteController.text.trim()) ?? 10;
    return minutes.clamp(1, 1440) * 60;
  }

  @override
  void initState() {
    super.initState();
    if (isEditing) _loadExistingConfig();
  }

  void _loadExistingConfig() {
    final storage = context.read<StorageService>();
    final config = storage.getConnection(widget.editId!);
    if (config == null) return;

    _nameController.text = config.name;
    _hostController.text = config.host;
    _portController.text = config.port.toString();
    _usernameController.text = config.username;
    _authMethod = config.authMethod;
    _launchMode = config.launchMode;
    _keepAlive = config.keepAlive;
    _tmuxAutoDeleteController.text =
        _secondsToDisplayMinutes(config.tmuxAutoDeleteSeconds).toString();
    _jumpHostController.text = config.jumpHost ?? '';
    _jumpPortController.text = config.jumpPort?.toString() ?? '22';
    _jumpUsernameController.text = config.jumpUsername ?? '';

    _loadSecrets(config.id);
  }

  Future<void> _loadSecrets(String id) async {
    setState(() => _isLoadingSecrets = true);

    final storage = context.read<StorageService>();
    final password = await storage.getPassword(id);
    final privateKey = await storage.getPrivateKey(id);

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
    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? '编辑连接' : '添加连接'),
        actions: [
          TextButton.icon(
            onPressed: _isSaving || _isLoadingSecrets ? null : _save,
            icon: _isSaving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: Text(_isSaving ? '保存中...' : '保存'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
          children: [
            if (_isLoadingSecrets) ...[
              const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: 12),
            ],
            _section('基本信息'),
            _buildNameField(),
            const SizedBox(height: 16),
            _section('连接信息'),
            _buildHostField(),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(flex: 2, child: _buildPortField()),
                const SizedBox(width: 12),
                Expanded(flex: 3, child: _buildUsernameField()),
              ],
            ),
            const SizedBox(height: 20),
            _section('认证方式'),
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
            const SizedBox(height: 20),
            _section('跳板机（可选）'),
            _buildJumpHostField(),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(flex: 2, child: _buildJumpPortField()),
                const SizedBox(width: 12),
                Expanded(flex: 3, child: _buildJumpUsernameField()),
              ],
            ),
            const SizedBox(height: 20),
            _section('高级选项'),
            _buildLaunchModeSelector(),
            if (_launchMode == TerminalLaunchMode.tmux) ...[
              const SizedBox(height: 12),
              _buildTmuxAutoDeleteField(),
            ],
            const SizedBox(height: 12),
            _buildKeepAliveSwitch(),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _buildNameField() {
    return TextFormField(
      controller: _nameController,
      decoration: const InputDecoration(
        labelText: '连接名称',
        hintText: '我的服务器',
        prefixIcon: Icon(Icons.label_outline),
      ),
      validator: (value) =>
          value == null || value.trim().isEmpty ? '请输入连接名称' : null,
    );
  }

  Widget _buildHostField() {
    return TextFormField(
      controller: _hostController,
      decoration: const InputDecoration(
        labelText: '主机地址',
        hintText: '192.168.1.1 或 example.com',
        prefixIcon: Icon(Icons.computer),
      ),
      keyboardType: TextInputType.url,
      validator: (value) =>
          value == null || value.trim().isEmpty ? '请输入主机地址' : null,
    );
  }

  Widget _buildPortField() {
    return TextFormField(
      controller: _portController,
      decoration: const InputDecoration(
        labelText: '端口',
        hintText: '22',
        prefixIcon: Icon(Icons.numbers),
      ),
      keyboardType: TextInputType.number,
      validator: (value) {
        final port = int.tryParse(value ?? '');
        if (port == null || port < 1 || port > 65535) return '无效端口';
        return null;
      },
    );
  }

  Widget _buildUsernameField() {
    return TextFormField(
      controller: _usernameController,
      decoration: const InputDecoration(
        labelText: '用户名',
        hintText: 'root',
        prefixIcon: Icon(Icons.person_outline),
      ),
      validator: (value) =>
          value == null || value.trim().isEmpty ? '请输入用户名' : null,
    );
  }

  Widget _buildAuthMethodSelector() {
    return SegmentedButton<AuthMethod>(
      segments: const [
        ButtonSegment(
          value: AuthMethod.password,
          label: Text('密码'),
          icon: Icon(Icons.lock_outline, size: 18),
        ),
        ButtonSegment(
          value: AuthMethod.privateKey,
          label: Text('私钥'),
          icon: Icon(Icons.key, size: 18),
        ),
        ButtonSegment(
          value: AuthMethod.both,
          label: Text('私钥+密码'),
          icon: Icon(Icons.enhanced_encryption, size: 18),
        ),
      ],
      selected: {_authMethod},
      onSelectionChanged: (set) => setState(() => _authMethod = set.first),
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordController,
      obscureText: _obscurePassword,
      decoration: InputDecoration(
        labelText: '密码',
        hintText: '输入 SSH 密码',
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
          return '密码认证需要输入密码';
        }
        return null;
      },
    );
  }

  Widget _buildPrivateKeyField() {
    return TextFormField(
      controller: _privateKeyController,
      maxLines: 4,
      decoration: const InputDecoration(
        labelText: 'SSH 私钥',
        hintText:
            '-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----',
        prefixIcon: Icon(Icons.key),
        alignLabelWithHint: true,
      ),
      validator: (value) {
        if (_authMethod == AuthMethod.privateKey &&
            (value == null || value.trim().isEmpty)) {
          return '私钥认证需要输入私钥内容';
        }
        return null;
      },
    );
  }

  Widget _buildJumpHostField() {
    return TextFormField(
      controller: _jumpHostController,
      decoration: const InputDecoration(
        labelText: '跳板机地址',
        hintText: '可选，留空则直连',
        prefixIcon: Icon(Icons.hub_outlined),
      ),
    );
  }

  Widget _buildJumpPortField() {
    return TextFormField(
      controller: _jumpPortController,
      decoration: const InputDecoration(
        labelText: '跳板机端口',
        hintText: '22',
      ),
      keyboardType: TextInputType.number,
    );
  }

  Widget _buildJumpUsernameField() {
    return TextFormField(
      controller: _jumpUsernameController,
      decoration: const InputDecoration(
        labelText: '跳板机用户名',
        hintText: '可选',
      ),
    );
  }

  Widget _buildLaunchModeSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<TerminalLaunchMode>(
          segments: const [
            ButtonSegment(
              value: TerminalLaunchMode.ssh,
              label: Text('SSH'),
              icon: Icon(Icons.terminal, size: 18),
            ),
            ButtonSegment(
              value: TerminalLaunchMode.tmux,
              label: Text('SSH + tmux'),
              icon: Icon(Icons.tab_rounded, size: 18),
            ),
          ],
          selected: {_launchMode},
          onSelectionChanged: (set) => setState(() => _launchMode = set.first),
        ),
        const SizedBox(height: 6),
        Text(
          _launchMode == TerminalLaunchMode.tmux
              ? '连接 SSH 后自动进入与当前窗口同名的 tmux 会话。'
              : '打开普通交互式 SSH shell。',
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
    return TextFormField(
      controller: _tmuxAutoDeleteController,
      decoration: const InputDecoration(
        labelText: 'tmux 无连接自动删除等待时间（分钟）',
        hintText: '10',
        helperText: '单位：分钟。断开后无人重新连接，超过该时间自动删除 tmux 会话。',
        prefixIcon: Icon(Icons.timer_outlined),
      ),
      keyboardType: TextInputType.number,
      validator: (value) {
        if (_launchMode != TerminalLaunchMode.tmux) return null;
        final minutes = int.tryParse(value?.trim() ?? '');
        if (minutes == null || minutes < 1) return '最少 1 分钟';
        if (minutes > 1440) return '最多 1440 分钟';
        return null;
      },
    );
  }

  Widget _buildKeepAliveSwitch() {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('后台保持连接'),
      subtitle: const Text(
        'Android 使用前台服务和 keep-alive 尽量维持 SSH 连接。',
        style: TextStyle(fontSize: 12),
      ),
      value: _keepAlive,
      activeThumbColor: AppTheme.terminalGreen,
      onChanged: (value) => setState(() => _keepAlive = value),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final ssh = context.read<SshService>();
    final relatedWindowCount =
        isEditing ? ssh.sessionCountForConnection(widget.editId!) : 0;
    if (relatedWindowCount > 0) {
      final confirmed = await _confirmDisconnectActiveWindows(
        relatedWindowCount,
      );
      if (!confirmed || !mounted) return;
    }

    setState(() => _isSaving = true);

    try {
      final storage = context.read<StorageService>();
      final config = ConnectionConfig(
        id: isEditing ? widget.editId! : const Uuid().v4(),
        name: _nameController.text.trim(),
        host: _hostController.text.trim(),
        port: int.parse(_portController.text.trim()),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        privateKey: _privateKeyController.text,
        authMethod: _authMethod,
        launchMode: _launchMode,
        tmuxAutoDeleteSeconds: _tmuxAutoDeleteSecondsFromInput(),
        keepAlive: _keepAlive,
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

      if (isEditing) {
        await storage.updateConnection(config);
        if (relatedWindowCount > 0) {
          await ssh.disconnectSessionsForConnection(config.id);
        }
      } else {
        await storage.addConnection(config);
      }

      if (mounted) Navigator.pop(context, config.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<bool> _confirmDisconnectActiveWindows(int windowCount) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存后将关闭相关窗口'),
        content: Text(
          '当前配置有关联的 $windowCount 个终端窗口。保存修改后，这些旧窗口会自动关闭，避免继续向旧 SSH 或旧 tmux 会话发送输入。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('保存并断开'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
