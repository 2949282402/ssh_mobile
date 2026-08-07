part of 'add_edit_screen.dart';

extension _AddEditFormFields on _AddEditScreenState {
  Widget _buildNameField(ConnectionStrings strings) {
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

  Widget _buildHostField(ConnectionStrings strings) {
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

  Widget _buildPortField(ConnectionStrings strings) {
    return ShadInputFormField(
      id: 'port',
      controller: _portController,
      label: Text(strings.port),
      placeholder: const Text(ConnectionUiTokens.defaultPortText),
      leading: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Icon(Icons.numbers, size: 18),
      ),
      keyboardType: TextInputType.number,
      validator: (value) {
        final port = int.tryParse(value);
        if (port == null ||
            port < ConnectionUiTokens.minPort ||
            port > ConnectionUiTokens.maxPort) {
          return strings.invalidPort;
        }
        return null;
      },
    );
  }

  Widget _buildUsernameField(ConnectionStrings strings) {
    return ShadInputFormField(
      id: 'username',
      controller: _usernameController,
      label: Text(strings.username),
      placeholder: const Text(ConnectionUiTokens.defaultUsernameText),
      leading: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Icon(Icons.person_outline, size: 18),
      ),
      validator: (value) => value.trim().isEmpty ? strings.enterUsername : null,
    );
  }

  Widget _buildAuthMethodSelector(
    ConnectionStrings strings,
    ColorScheme colorScheme,
  ) {
    Widget buildChip({
      required String label,
      required IconData icon,
      required AuthMethod method,
    }) {
      final selected = _authMethod == method;
      return FilterChip(
        selected: selected,
        label: Text(label),
        avatar: Icon(
          icon,
          size: 16,
          color: selected
              ? colorScheme.onPrimaryContainer
              : colorScheme.onSurfaceVariant,
        ),
        showCheckmark: false,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ConnectionUiTokens.radiusSmall),
          side: BorderSide(
            color: selected
                ? colorScheme.primary
                : colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        selectedColor: colorScheme.primaryContainer,
        labelStyle: TextStyle(
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          color: selected
              ? colorScheme.onPrimaryContainer
              : colorScheme.onSurface,
        ),
        onSelected: (val) {
          if (val) _updateState(() => _authMethod = method);
        },
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        buildChip(
          label: strings.password,
          icon: Icons.lock_outline,
          method: AuthMethod.password,
        ),
        buildChip(
          label: strings.privateKey,
          icon: Icons.key_outlined,
          method: AuthMethod.privateKey,
        ),
        buildChip(
          label: strings.privateKeyPassword,
          icon: Icons.enhanced_encryption_outlined,
          method: AuthMethod.both,
        ),
      ],
    );
  }

  Widget _buildPasswordField(ConnectionStrings strings) {
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
        tooltip: _obscurePassword ? strings.showPassword : strings.hidePassword,
        icon: Icon(
          _obscurePassword ? Icons.visibility_off : Icons.visibility,
          size: 18,
        ),
        onPressed: () =>
            _updateState(() => _obscurePassword = !_obscurePassword),
      ),
      validator: (value) {
        if ((_authMethod == AuthMethod.password ||
                _authMethod == AuthMethod.both) &&
            value.trim().isEmpty) {
          return strings.passwordRequired;
        }
        return null;
      },
    );
  }

  Widget _buildPrivateKeyField(ConnectionStrings strings) {
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
              label: Text(strings.paste),
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) {
                  _updateState(() {
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
            if ((_authMethod == AuthMethod.privateKey ||
                    _authMethod == AuthMethod.both) &&
                value.trim().isEmpty) {
              return strings.privateKeyRequired;
            }
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildJumpHostField(ConnectionStrings strings) {
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

  Widget _buildJumpPortField(ConnectionStrings strings) {
    return ShadInputFormField(
      id: 'jumpPort',
      controller: _jumpPortController,
      label: Text(strings.jumpPort),
      placeholder: const Text(ConnectionUiTokens.defaultPortText),
      keyboardType: TextInputType.number,
      validator: (value) {
        if (_jumpHostController.text.trim().isEmpty) return null;
        final port = int.tryParse(value.trim());
        if (port == null ||
            port < ConnectionUiTokens.minPort ||
            port > ConnectionUiTokens.maxPort) {
          return strings.invalidPort;
        }
        return null;
      },
    );
  }

  Widget _buildJumpUsernameField(ConnectionStrings strings) {
    return ShadInputFormField(
      id: 'jumpUsername',
      controller: _jumpUsernameController,
      label: Text(strings.jumpUsername),
      placeholder: Text(strings.optional),
    );
  }
}
