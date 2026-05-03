import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/connection.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';

class AddEditScreen extends StatefulWidget {
  final String? editId; // null = 新增，非null = 编辑

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

  AuthMethod _authMethod = AuthMethod.password;
  bool _keepAlive = true;
  bool _obscurePassword = true;
  bool _isSaving = false;
  bool _isLoadingSecrets = false;

  bool get isEditing => widget.editId != null;

  @override
  void initState() {
    super.initState();
    if (isEditing) {
      _loadExistingConfig();
    }
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
    _keepAlive = config.keepAlive;
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
          padding: const EdgeInsets.all(16),
          children: [
            if (_isLoadingSecrets) ...[
              const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: 12),
            ],
            _buildSectionHeader('基本信息'),
            const SizedBox(height: 8),
            _buildNameField(),
            const SizedBox(height: 16),
            _buildSectionHeader('连接信息'),
            const SizedBox(height: 8),
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
            _buildSectionHeader('认证方式'),
            const SizedBox(height: 8),
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
            _buildSectionHeader('跳板机（可选）'),
            const SizedBox(height: 8),
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
            _buildSectionHeader('高级选项'),
            const SizedBox(height: 8),
            _buildKeepAliveSwitch(),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: AppTheme.darkTheme.colorScheme.primary,
        letterSpacing: 1,
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
      validator: (v) => (v == null || v.trim().isEmpty) ? '请输入名称' : null,
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
      validator: (v) => (v == null || v.trim().isEmpty) ? '请输入主机地址' : null,
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
      validator: (v) {
        if (v == null || v.isEmpty) return '必填';
        final port = int.tryParse(v);
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
      validator: (v) => (v == null || v.trim().isEmpty) ? '请输入用户名' : null,
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
      onSelectionChanged: (set) {
        setState(() => _authMethod = set.first);
      },
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
      validator: (v) {
        if (_authMethod == AuthMethod.password &&
            (v == null || v.trim().isEmpty)) {
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
      validator: (v) {
        if (_authMethod == AuthMethod.privateKey &&
            (v == null || v.trim().isEmpty)) {
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

  Widget _buildKeepAliveSwitch() {
    return SwitchListTile(
      title: const Text('后台保持连接'),
      subtitle: const Text(
        '启用后 App 退到后台时保持 SSH 连接不中断\n（Android 依赖前台服务通知）',
        style: TextStyle(fontSize: 12),
      ),
      value: _keepAlive,
      activeThumbColor: AppTheme.terminalGreen,
      onChanged: (v) => setState(() => _keepAlive = v),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

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
      } else {
        await storage.addConnection(config);
      }

      if (mounted) {
        Navigator.pop(context, true);
      }
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
}
