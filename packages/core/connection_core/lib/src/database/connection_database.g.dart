// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'connection_database.dart';

// ignore_for_file: type=lint
class $ConnectionTableTable extends ConnectionTable
    with TableInfo<$ConnectionTableTable, ConnectionTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConnectionTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hostMeta = const VerificationMeta('host');
  @override
  late final GeneratedColumn<String> host = GeneratedColumn<String>(
    'host',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
    'port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _authMethodMeta = const VerificationMeta(
    'authMethod',
  );
  @override
  late final GeneratedColumn<String> authMethod = GeneratedColumn<String>(
    'auth_method',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _terminalWidthMeta = const VerificationMeta(
    'terminalWidth',
  );
  @override
  late final GeneratedColumn<int> terminalWidth = GeneratedColumn<int>(
    'terminal_width',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _terminalHeightMeta = const VerificationMeta(
    'terminalHeight',
  );
  @override
  late final GeneratedColumn<int> terminalHeight = GeneratedColumn<int>(
    'terminal_height',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _keepAliveMeta = const VerificationMeta(
    'keepAlive',
  );
  @override
  late final GeneratedColumn<bool> keepAlive = GeneratedColumn<bool>(
    'keep_alive',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("keep_alive" IN (0, 1))',
    ),
  );
  static const VerificationMeta _keepAliveIntervalMeta = const VerificationMeta(
    'keepAliveInterval',
  );
  @override
  late final GeneratedColumn<int> keepAliveInterval = GeneratedColumn<int>(
    'keep_alive_interval',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _launchModeMeta = const VerificationMeta(
    'launchMode',
  );
  @override
  late final GeneratedColumn<String> launchMode = GeneratedColumn<String>(
    'launch_mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverPlatformMeta = const VerificationMeta(
    'serverPlatform',
  );
  @override
  late final GeneratedColumn<String> serverPlatform = GeneratedColumn<String>(
    'server_platform',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tmuxAutoDeleteSecondsMeta =
      const VerificationMeta('tmuxAutoDeleteSeconds');
  @override
  late final GeneratedColumn<int> tmuxAutoDeleteSeconds = GeneratedColumn<int>(
    'tmux_auto_delete_seconds',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hostKeyFingerprintMeta =
      const VerificationMeta('hostKeyFingerprint');
  @override
  late final GeneratedColumn<String> hostKeyFingerprint =
      GeneratedColumn<String>(
        'host_key_fingerprint',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _hostKeyAlgorithmMeta = const VerificationMeta(
    'hostKeyAlgorithm',
  );
  @override
  late final GeneratedColumn<String> hostKeyAlgorithm = GeneratedColumn<String>(
    'host_key_algorithm',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _hostKeyTrustedAtMeta = const VerificationMeta(
    'hostKeyTrustedAt',
  );
  @override
  late final GeneratedColumn<int> hostKeyTrustedAt = GeneratedColumn<int>(
    'host_key_trusted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _jumpHostMeta = const VerificationMeta(
    'jumpHost',
  );
  @override
  late final GeneratedColumn<String> jumpHost = GeneratedColumn<String>(
    'jump_host',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _jumpPortMeta = const VerificationMeta(
    'jumpPort',
  );
  @override
  late final GeneratedColumn<int> jumpPort = GeneratedColumn<int>(
    'jump_port',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _jumpUsernameMeta = const VerificationMeta(
    'jumpUsername',
  );
  @override
  late final GeneratedColumn<String> jumpUsername = GeneratedColumn<String>(
    'jump_username',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _groupMeta = const VerificationMeta('group');
  @override
  late final GeneratedColumn<String> group = GeneratedColumn<String>(
    'group',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    host,
    port,
    username,
    authMethod,
    terminalWidth,
    terminalHeight,
    keepAlive,
    keepAliveInterval,
    launchMode,
    serverPlatform,
    tmuxAutoDeleteSeconds,
    hostKeyFingerprint,
    hostKeyAlgorithm,
    hostKeyTrustedAt,
    jumpHost,
    jumpPort,
    jumpUsername,
    group,
    createdAt,
    updatedAt,
    sortOrder,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'connection_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConnectionTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('host')) {
      context.handle(
        _hostMeta,
        host.isAcceptableOrUnknown(data['host']!, _hostMeta),
      );
    } else if (isInserting) {
      context.missing(_hostMeta);
    }
    if (data.containsKey('port')) {
      context.handle(
        _portMeta,
        port.isAcceptableOrUnknown(data['port']!, _portMeta),
      );
    } else if (isInserting) {
      context.missing(_portMeta);
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    } else if (isInserting) {
      context.missing(_usernameMeta);
    }
    if (data.containsKey('auth_method')) {
      context.handle(
        _authMethodMeta,
        authMethod.isAcceptableOrUnknown(data['auth_method']!, _authMethodMeta),
      );
    } else if (isInserting) {
      context.missing(_authMethodMeta);
    }
    if (data.containsKey('terminal_width')) {
      context.handle(
        _terminalWidthMeta,
        terminalWidth.isAcceptableOrUnknown(
          data['terminal_width']!,
          _terminalWidthMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_terminalWidthMeta);
    }
    if (data.containsKey('terminal_height')) {
      context.handle(
        _terminalHeightMeta,
        terminalHeight.isAcceptableOrUnknown(
          data['terminal_height']!,
          _terminalHeightMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_terminalHeightMeta);
    }
    if (data.containsKey('keep_alive')) {
      context.handle(
        _keepAliveMeta,
        keepAlive.isAcceptableOrUnknown(data['keep_alive']!, _keepAliveMeta),
      );
    } else if (isInserting) {
      context.missing(_keepAliveMeta);
    }
    if (data.containsKey('keep_alive_interval')) {
      context.handle(
        _keepAliveIntervalMeta,
        keepAliveInterval.isAcceptableOrUnknown(
          data['keep_alive_interval']!,
          _keepAliveIntervalMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_keepAliveIntervalMeta);
    }
    if (data.containsKey('launch_mode')) {
      context.handle(
        _launchModeMeta,
        launchMode.isAcceptableOrUnknown(data['launch_mode']!, _launchModeMeta),
      );
    } else if (isInserting) {
      context.missing(_launchModeMeta);
    }
    if (data.containsKey('server_platform')) {
      context.handle(
        _serverPlatformMeta,
        serverPlatform.isAcceptableOrUnknown(
          data['server_platform']!,
          _serverPlatformMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverPlatformMeta);
    }
    if (data.containsKey('tmux_auto_delete_seconds')) {
      context.handle(
        _tmuxAutoDeleteSecondsMeta,
        tmuxAutoDeleteSeconds.isAcceptableOrUnknown(
          data['tmux_auto_delete_seconds']!,
          _tmuxAutoDeleteSecondsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_tmuxAutoDeleteSecondsMeta);
    }
    if (data.containsKey('host_key_fingerprint')) {
      context.handle(
        _hostKeyFingerprintMeta,
        hostKeyFingerprint.isAcceptableOrUnknown(
          data['host_key_fingerprint']!,
          _hostKeyFingerprintMeta,
        ),
      );
    }
    if (data.containsKey('host_key_algorithm')) {
      context.handle(
        _hostKeyAlgorithmMeta,
        hostKeyAlgorithm.isAcceptableOrUnknown(
          data['host_key_algorithm']!,
          _hostKeyAlgorithmMeta,
        ),
      );
    }
    if (data.containsKey('host_key_trusted_at')) {
      context.handle(
        _hostKeyTrustedAtMeta,
        hostKeyTrustedAt.isAcceptableOrUnknown(
          data['host_key_trusted_at']!,
          _hostKeyTrustedAtMeta,
        ),
      );
    }
    if (data.containsKey('jump_host')) {
      context.handle(
        _jumpHostMeta,
        jumpHost.isAcceptableOrUnknown(data['jump_host']!, _jumpHostMeta),
      );
    }
    if (data.containsKey('jump_port')) {
      context.handle(
        _jumpPortMeta,
        jumpPort.isAcceptableOrUnknown(data['jump_port']!, _jumpPortMeta),
      );
    }
    if (data.containsKey('jump_username')) {
      context.handle(
        _jumpUsernameMeta,
        jumpUsername.isAcceptableOrUnknown(
          data['jump_username']!,
          _jumpUsernameMeta,
        ),
      );
    }
    if (data.containsKey('group')) {
      context.handle(
        _groupMeta,
        group.isAcceptableOrUnknown(data['group']!, _groupMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ConnectionTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConnectionTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      host: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}host'],
      )!,
      port: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}port'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      authMethod: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}auth_method'],
      )!,
      terminalWidth: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}terminal_width'],
      )!,
      terminalHeight: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}terminal_height'],
      )!,
      keepAlive: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}keep_alive'],
      )!,
      keepAliveInterval: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}keep_alive_interval'],
      )!,
      launchMode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}launch_mode'],
      )!,
      serverPlatform: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_platform'],
      )!,
      tmuxAutoDeleteSeconds: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tmux_auto_delete_seconds'],
      )!,
      hostKeyFingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}host_key_fingerprint'],
      ),
      hostKeyAlgorithm: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}host_key_algorithm'],
      ),
      hostKeyTrustedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}host_key_trusted_at'],
      ),
      jumpHost: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}jump_host'],
      ),
      jumpPort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}jump_port'],
      ),
      jumpUsername: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}jump_username'],
      ),
      group: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
    );
  }

  @override
  $ConnectionTableTable createAlias(String alias) {
    return $ConnectionTableTable(attachedDatabase, alias);
  }
}

class ConnectionTableData extends DataClass
    implements Insertable<ConnectionTableData> {
  /// 稳定的连接业务 id，作为主键而不是 SQLite 自增 id。
  final String id;

  /// 用户可见名称。
  final String name;

  /// SSH 主机和端口。
  final String host;
  final int port;

  /// SSH 登录用户；密码和私钥不在本表。
  final String username;
  final String authMethod;

  /// 终端和保活配置。
  final int terminalWidth;
  final int terminalHeight;
  final bool keepAlive;
  final int keepAliveInterval;
  final String launchMode;
  final String serverPlatform;
  final int tmuxAutoDeleteSeconds;

  /// Host Key 信任元数据。
  final String? hostKeyFingerprint;
  final String? hostKeyAlgorithm;
  final int? hostKeyTrustedAt;

  /// Jump Host 和分组配置。
  final String? jumpHost;
  final int? jumpPort;
  final String? jumpUsername;
  final String? group;

  /// 创建/更新时间使用 UTC 毫秒，避免平台时区改变排序语义。
  final int createdAt;
  final int updatedAt;

  /// 列表拖拽顺序；不依赖数据库隐含 rowid。
  final int sortOrder;
  const ConnectionTableData({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    required this.terminalWidth,
    required this.terminalHeight,
    required this.keepAlive,
    required this.keepAliveInterval,
    required this.launchMode,
    required this.serverPlatform,
    required this.tmuxAutoDeleteSeconds,
    this.hostKeyFingerprint,
    this.hostKeyAlgorithm,
    this.hostKeyTrustedAt,
    this.jumpHost,
    this.jumpPort,
    this.jumpUsername,
    this.group,
    required this.createdAt,
    required this.updatedAt,
    required this.sortOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['host'] = Variable<String>(host);
    map['port'] = Variable<int>(port);
    map['username'] = Variable<String>(username);
    map['auth_method'] = Variable<String>(authMethod);
    map['terminal_width'] = Variable<int>(terminalWidth);
    map['terminal_height'] = Variable<int>(terminalHeight);
    map['keep_alive'] = Variable<bool>(keepAlive);
    map['keep_alive_interval'] = Variable<int>(keepAliveInterval);
    map['launch_mode'] = Variable<String>(launchMode);
    map['server_platform'] = Variable<String>(serverPlatform);
    map['tmux_auto_delete_seconds'] = Variable<int>(tmuxAutoDeleteSeconds);
    if (!nullToAbsent || hostKeyFingerprint != null) {
      map['host_key_fingerprint'] = Variable<String>(hostKeyFingerprint);
    }
    if (!nullToAbsent || hostKeyAlgorithm != null) {
      map['host_key_algorithm'] = Variable<String>(hostKeyAlgorithm);
    }
    if (!nullToAbsent || hostKeyTrustedAt != null) {
      map['host_key_trusted_at'] = Variable<int>(hostKeyTrustedAt);
    }
    if (!nullToAbsent || jumpHost != null) {
      map['jump_host'] = Variable<String>(jumpHost);
    }
    if (!nullToAbsent || jumpPort != null) {
      map['jump_port'] = Variable<int>(jumpPort);
    }
    if (!nullToAbsent || jumpUsername != null) {
      map['jump_username'] = Variable<String>(jumpUsername);
    }
    if (!nullToAbsent || group != null) {
      map['group'] = Variable<String>(group);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  ConnectionTableCompanion toCompanion(bool nullToAbsent) {
    return ConnectionTableCompanion(
      id: Value(id),
      name: Value(name),
      host: Value(host),
      port: Value(port),
      username: Value(username),
      authMethod: Value(authMethod),
      terminalWidth: Value(terminalWidth),
      terminalHeight: Value(terminalHeight),
      keepAlive: Value(keepAlive),
      keepAliveInterval: Value(keepAliveInterval),
      launchMode: Value(launchMode),
      serverPlatform: Value(serverPlatform),
      tmuxAutoDeleteSeconds: Value(tmuxAutoDeleteSeconds),
      hostKeyFingerprint: hostKeyFingerprint == null && nullToAbsent
          ? const Value.absent()
          : Value(hostKeyFingerprint),
      hostKeyAlgorithm: hostKeyAlgorithm == null && nullToAbsent
          ? const Value.absent()
          : Value(hostKeyAlgorithm),
      hostKeyTrustedAt: hostKeyTrustedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(hostKeyTrustedAt),
      jumpHost: jumpHost == null && nullToAbsent
          ? const Value.absent()
          : Value(jumpHost),
      jumpPort: jumpPort == null && nullToAbsent
          ? const Value.absent()
          : Value(jumpPort),
      jumpUsername: jumpUsername == null && nullToAbsent
          ? const Value.absent()
          : Value(jumpUsername),
      group: group == null && nullToAbsent
          ? const Value.absent()
          : Value(group),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      sortOrder: Value(sortOrder),
    );
  }

  factory ConnectionTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConnectionTableData(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      host: serializer.fromJson<String>(json['host']),
      port: serializer.fromJson<int>(json['port']),
      username: serializer.fromJson<String>(json['username']),
      authMethod: serializer.fromJson<String>(json['authMethod']),
      terminalWidth: serializer.fromJson<int>(json['terminalWidth']),
      terminalHeight: serializer.fromJson<int>(json['terminalHeight']),
      keepAlive: serializer.fromJson<bool>(json['keepAlive']),
      keepAliveInterval: serializer.fromJson<int>(json['keepAliveInterval']),
      launchMode: serializer.fromJson<String>(json['launchMode']),
      serverPlatform: serializer.fromJson<String>(json['serverPlatform']),
      tmuxAutoDeleteSeconds: serializer.fromJson<int>(
        json['tmuxAutoDeleteSeconds'],
      ),
      hostKeyFingerprint: serializer.fromJson<String?>(
        json['hostKeyFingerprint'],
      ),
      hostKeyAlgorithm: serializer.fromJson<String?>(json['hostKeyAlgorithm']),
      hostKeyTrustedAt: serializer.fromJson<int?>(json['hostKeyTrustedAt']),
      jumpHost: serializer.fromJson<String?>(json['jumpHost']),
      jumpPort: serializer.fromJson<int?>(json['jumpPort']),
      jumpUsername: serializer.fromJson<String?>(json['jumpUsername']),
      group: serializer.fromJson<String?>(json['group']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'host': serializer.toJson<String>(host),
      'port': serializer.toJson<int>(port),
      'username': serializer.toJson<String>(username),
      'authMethod': serializer.toJson<String>(authMethod),
      'terminalWidth': serializer.toJson<int>(terminalWidth),
      'terminalHeight': serializer.toJson<int>(terminalHeight),
      'keepAlive': serializer.toJson<bool>(keepAlive),
      'keepAliveInterval': serializer.toJson<int>(keepAliveInterval),
      'launchMode': serializer.toJson<String>(launchMode),
      'serverPlatform': serializer.toJson<String>(serverPlatform),
      'tmuxAutoDeleteSeconds': serializer.toJson<int>(tmuxAutoDeleteSeconds),
      'hostKeyFingerprint': serializer.toJson<String?>(hostKeyFingerprint),
      'hostKeyAlgorithm': serializer.toJson<String?>(hostKeyAlgorithm),
      'hostKeyTrustedAt': serializer.toJson<int?>(hostKeyTrustedAt),
      'jumpHost': serializer.toJson<String?>(jumpHost),
      'jumpPort': serializer.toJson<int?>(jumpPort),
      'jumpUsername': serializer.toJson<String?>(jumpUsername),
      'group': serializer.toJson<String?>(group),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  ConnectionTableData copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    String? authMethod,
    int? terminalWidth,
    int? terminalHeight,
    bool? keepAlive,
    int? keepAliveInterval,
    String? launchMode,
    String? serverPlatform,
    int? tmuxAutoDeleteSeconds,
    Value<String?> hostKeyFingerprint = const Value.absent(),
    Value<String?> hostKeyAlgorithm = const Value.absent(),
    Value<int?> hostKeyTrustedAt = const Value.absent(),
    Value<String?> jumpHost = const Value.absent(),
    Value<int?> jumpPort = const Value.absent(),
    Value<String?> jumpUsername = const Value.absent(),
    Value<String?> group = const Value.absent(),
    int? createdAt,
    int? updatedAt,
    int? sortOrder,
  }) => ConnectionTableData(
    id: id ?? this.id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    username: username ?? this.username,
    authMethod: authMethod ?? this.authMethod,
    terminalWidth: terminalWidth ?? this.terminalWidth,
    terminalHeight: terminalHeight ?? this.terminalHeight,
    keepAlive: keepAlive ?? this.keepAlive,
    keepAliveInterval: keepAliveInterval ?? this.keepAliveInterval,
    launchMode: launchMode ?? this.launchMode,
    serverPlatform: serverPlatform ?? this.serverPlatform,
    tmuxAutoDeleteSeconds: tmuxAutoDeleteSeconds ?? this.tmuxAutoDeleteSeconds,
    hostKeyFingerprint: hostKeyFingerprint.present
        ? hostKeyFingerprint.value
        : this.hostKeyFingerprint,
    hostKeyAlgorithm: hostKeyAlgorithm.present
        ? hostKeyAlgorithm.value
        : this.hostKeyAlgorithm,
    hostKeyTrustedAt: hostKeyTrustedAt.present
        ? hostKeyTrustedAt.value
        : this.hostKeyTrustedAt,
    jumpHost: jumpHost.present ? jumpHost.value : this.jumpHost,
    jumpPort: jumpPort.present ? jumpPort.value : this.jumpPort,
    jumpUsername: jumpUsername.present ? jumpUsername.value : this.jumpUsername,
    group: group.present ? group.value : this.group,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    sortOrder: sortOrder ?? this.sortOrder,
  );
  ConnectionTableData copyWithCompanion(ConnectionTableCompanion data) {
    return ConnectionTableData(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      host: data.host.present ? data.host.value : this.host,
      port: data.port.present ? data.port.value : this.port,
      username: data.username.present ? data.username.value : this.username,
      authMethod: data.authMethod.present
          ? data.authMethod.value
          : this.authMethod,
      terminalWidth: data.terminalWidth.present
          ? data.terminalWidth.value
          : this.terminalWidth,
      terminalHeight: data.terminalHeight.present
          ? data.terminalHeight.value
          : this.terminalHeight,
      keepAlive: data.keepAlive.present ? data.keepAlive.value : this.keepAlive,
      keepAliveInterval: data.keepAliveInterval.present
          ? data.keepAliveInterval.value
          : this.keepAliveInterval,
      launchMode: data.launchMode.present
          ? data.launchMode.value
          : this.launchMode,
      serverPlatform: data.serverPlatform.present
          ? data.serverPlatform.value
          : this.serverPlatform,
      tmuxAutoDeleteSeconds: data.tmuxAutoDeleteSeconds.present
          ? data.tmuxAutoDeleteSeconds.value
          : this.tmuxAutoDeleteSeconds,
      hostKeyFingerprint: data.hostKeyFingerprint.present
          ? data.hostKeyFingerprint.value
          : this.hostKeyFingerprint,
      hostKeyAlgorithm: data.hostKeyAlgorithm.present
          ? data.hostKeyAlgorithm.value
          : this.hostKeyAlgorithm,
      hostKeyTrustedAt: data.hostKeyTrustedAt.present
          ? data.hostKeyTrustedAt.value
          : this.hostKeyTrustedAt,
      jumpHost: data.jumpHost.present ? data.jumpHost.value : this.jumpHost,
      jumpPort: data.jumpPort.present ? data.jumpPort.value : this.jumpPort,
      jumpUsername: data.jumpUsername.present
          ? data.jumpUsername.value
          : this.jumpUsername,
      group: data.group.present ? data.group.value : this.group,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConnectionTableData(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('username: $username, ')
          ..write('authMethod: $authMethod, ')
          ..write('terminalWidth: $terminalWidth, ')
          ..write('terminalHeight: $terminalHeight, ')
          ..write('keepAlive: $keepAlive, ')
          ..write('keepAliveInterval: $keepAliveInterval, ')
          ..write('launchMode: $launchMode, ')
          ..write('serverPlatform: $serverPlatform, ')
          ..write('tmuxAutoDeleteSeconds: $tmuxAutoDeleteSeconds, ')
          ..write('hostKeyFingerprint: $hostKeyFingerprint, ')
          ..write('hostKeyAlgorithm: $hostKeyAlgorithm, ')
          ..write('hostKeyTrustedAt: $hostKeyTrustedAt, ')
          ..write('jumpHost: $jumpHost, ')
          ..write('jumpPort: $jumpPort, ')
          ..write('jumpUsername: $jumpUsername, ')
          ..write('group: $group, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    name,
    host,
    port,
    username,
    authMethod,
    terminalWidth,
    terminalHeight,
    keepAlive,
    keepAliveInterval,
    launchMode,
    serverPlatform,
    tmuxAutoDeleteSeconds,
    hostKeyFingerprint,
    hostKeyAlgorithm,
    hostKeyTrustedAt,
    jumpHost,
    jumpPort,
    jumpUsername,
    group,
    createdAt,
    updatedAt,
    sortOrder,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConnectionTableData &&
          other.id == this.id &&
          other.name == this.name &&
          other.host == this.host &&
          other.port == this.port &&
          other.username == this.username &&
          other.authMethod == this.authMethod &&
          other.terminalWidth == this.terminalWidth &&
          other.terminalHeight == this.terminalHeight &&
          other.keepAlive == this.keepAlive &&
          other.keepAliveInterval == this.keepAliveInterval &&
          other.launchMode == this.launchMode &&
          other.serverPlatform == this.serverPlatform &&
          other.tmuxAutoDeleteSeconds == this.tmuxAutoDeleteSeconds &&
          other.hostKeyFingerprint == this.hostKeyFingerprint &&
          other.hostKeyAlgorithm == this.hostKeyAlgorithm &&
          other.hostKeyTrustedAt == this.hostKeyTrustedAt &&
          other.jumpHost == this.jumpHost &&
          other.jumpPort == this.jumpPort &&
          other.jumpUsername == this.jumpUsername &&
          other.group == this.group &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.sortOrder == this.sortOrder);
}

class ConnectionTableCompanion extends UpdateCompanion<ConnectionTableData> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> host;
  final Value<int> port;
  final Value<String> username;
  final Value<String> authMethod;
  final Value<int> terminalWidth;
  final Value<int> terminalHeight;
  final Value<bool> keepAlive;
  final Value<int> keepAliveInterval;
  final Value<String> launchMode;
  final Value<String> serverPlatform;
  final Value<int> tmuxAutoDeleteSeconds;
  final Value<String?> hostKeyFingerprint;
  final Value<String?> hostKeyAlgorithm;
  final Value<int?> hostKeyTrustedAt;
  final Value<String?> jumpHost;
  final Value<int?> jumpPort;
  final Value<String?> jumpUsername;
  final Value<String?> group;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> sortOrder;
  final Value<int> rowid;
  const ConnectionTableCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.host = const Value.absent(),
    this.port = const Value.absent(),
    this.username = const Value.absent(),
    this.authMethod = const Value.absent(),
    this.terminalWidth = const Value.absent(),
    this.terminalHeight = const Value.absent(),
    this.keepAlive = const Value.absent(),
    this.keepAliveInterval = const Value.absent(),
    this.launchMode = const Value.absent(),
    this.serverPlatform = const Value.absent(),
    this.tmuxAutoDeleteSeconds = const Value.absent(),
    this.hostKeyFingerprint = const Value.absent(),
    this.hostKeyAlgorithm = const Value.absent(),
    this.hostKeyTrustedAt = const Value.absent(),
    this.jumpHost = const Value.absent(),
    this.jumpPort = const Value.absent(),
    this.jumpUsername = const Value.absent(),
    this.group = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConnectionTableCompanion.insert({
    required String id,
    required String name,
    required String host,
    required int port,
    required String username,
    required String authMethod,
    required int terminalWidth,
    required int terminalHeight,
    required bool keepAlive,
    required int keepAliveInterval,
    required String launchMode,
    required String serverPlatform,
    required int tmuxAutoDeleteSeconds,
    this.hostKeyFingerprint = const Value.absent(),
    this.hostKeyAlgorithm = const Value.absent(),
    this.hostKeyTrustedAt = const Value.absent(),
    this.jumpHost = const Value.absent(),
    this.jumpPort = const Value.absent(),
    this.jumpUsername = const Value.absent(),
    this.group = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       host = Value(host),
       port = Value(port),
       username = Value(username),
       authMethod = Value(authMethod),
       terminalWidth = Value(terminalWidth),
       terminalHeight = Value(terminalHeight),
       keepAlive = Value(keepAlive),
       keepAliveInterval = Value(keepAliveInterval),
       launchMode = Value(launchMode),
       serverPlatform = Value(serverPlatform),
       tmuxAutoDeleteSeconds = Value(tmuxAutoDeleteSeconds),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<ConnectionTableData> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? host,
    Expression<int>? port,
    Expression<String>? username,
    Expression<String>? authMethod,
    Expression<int>? terminalWidth,
    Expression<int>? terminalHeight,
    Expression<bool>? keepAlive,
    Expression<int>? keepAliveInterval,
    Expression<String>? launchMode,
    Expression<String>? serverPlatform,
    Expression<int>? tmuxAutoDeleteSeconds,
    Expression<String>? hostKeyFingerprint,
    Expression<String>? hostKeyAlgorithm,
    Expression<int>? hostKeyTrustedAt,
    Expression<String>? jumpHost,
    Expression<int>? jumpPort,
    Expression<String>? jumpUsername,
    Expression<String>? group,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? sortOrder,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (host != null) 'host': host,
      if (port != null) 'port': port,
      if (username != null) 'username': username,
      if (authMethod != null) 'auth_method': authMethod,
      if (terminalWidth != null) 'terminal_width': terminalWidth,
      if (terminalHeight != null) 'terminal_height': terminalHeight,
      if (keepAlive != null) 'keep_alive': keepAlive,
      if (keepAliveInterval != null) 'keep_alive_interval': keepAliveInterval,
      if (launchMode != null) 'launch_mode': launchMode,
      if (serverPlatform != null) 'server_platform': serverPlatform,
      if (tmuxAutoDeleteSeconds != null)
        'tmux_auto_delete_seconds': tmuxAutoDeleteSeconds,
      if (hostKeyFingerprint != null)
        'host_key_fingerprint': hostKeyFingerprint,
      if (hostKeyAlgorithm != null) 'host_key_algorithm': hostKeyAlgorithm,
      if (hostKeyTrustedAt != null) 'host_key_trusted_at': hostKeyTrustedAt,
      if (jumpHost != null) 'jump_host': jumpHost,
      if (jumpPort != null) 'jump_port': jumpPort,
      if (jumpUsername != null) 'jump_username': jumpUsername,
      if (group != null) 'group': group,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConnectionTableCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? host,
    Value<int>? port,
    Value<String>? username,
    Value<String>? authMethod,
    Value<int>? terminalWidth,
    Value<int>? terminalHeight,
    Value<bool>? keepAlive,
    Value<int>? keepAliveInterval,
    Value<String>? launchMode,
    Value<String>? serverPlatform,
    Value<int>? tmuxAutoDeleteSeconds,
    Value<String?>? hostKeyFingerprint,
    Value<String?>? hostKeyAlgorithm,
    Value<int?>? hostKeyTrustedAt,
    Value<String?>? jumpHost,
    Value<int?>? jumpPort,
    Value<String?>? jumpUsername,
    Value<String?>? group,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? sortOrder,
    Value<int>? rowid,
  }) {
    return ConnectionTableCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      terminalWidth: terminalWidth ?? this.terminalWidth,
      terminalHeight: terminalHeight ?? this.terminalHeight,
      keepAlive: keepAlive ?? this.keepAlive,
      keepAliveInterval: keepAliveInterval ?? this.keepAliveInterval,
      launchMode: launchMode ?? this.launchMode,
      serverPlatform: serverPlatform ?? this.serverPlatform,
      tmuxAutoDeleteSeconds:
          tmuxAutoDeleteSeconds ?? this.tmuxAutoDeleteSeconds,
      hostKeyFingerprint: hostKeyFingerprint ?? this.hostKeyFingerprint,
      hostKeyAlgorithm: hostKeyAlgorithm ?? this.hostKeyAlgorithm,
      hostKeyTrustedAt: hostKeyTrustedAt ?? this.hostKeyTrustedAt,
      jumpHost: jumpHost ?? this.jumpHost,
      jumpPort: jumpPort ?? this.jumpPort,
      jumpUsername: jumpUsername ?? this.jumpUsername,
      group: group ?? this.group,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sortOrder: sortOrder ?? this.sortOrder,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (host.present) {
      map['host'] = Variable<String>(host.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (authMethod.present) {
      map['auth_method'] = Variable<String>(authMethod.value);
    }
    if (terminalWidth.present) {
      map['terminal_width'] = Variable<int>(terminalWidth.value);
    }
    if (terminalHeight.present) {
      map['terminal_height'] = Variable<int>(terminalHeight.value);
    }
    if (keepAlive.present) {
      map['keep_alive'] = Variable<bool>(keepAlive.value);
    }
    if (keepAliveInterval.present) {
      map['keep_alive_interval'] = Variable<int>(keepAliveInterval.value);
    }
    if (launchMode.present) {
      map['launch_mode'] = Variable<String>(launchMode.value);
    }
    if (serverPlatform.present) {
      map['server_platform'] = Variable<String>(serverPlatform.value);
    }
    if (tmuxAutoDeleteSeconds.present) {
      map['tmux_auto_delete_seconds'] = Variable<int>(
        tmuxAutoDeleteSeconds.value,
      );
    }
    if (hostKeyFingerprint.present) {
      map['host_key_fingerprint'] = Variable<String>(hostKeyFingerprint.value);
    }
    if (hostKeyAlgorithm.present) {
      map['host_key_algorithm'] = Variable<String>(hostKeyAlgorithm.value);
    }
    if (hostKeyTrustedAt.present) {
      map['host_key_trusted_at'] = Variable<int>(hostKeyTrustedAt.value);
    }
    if (jumpHost.present) {
      map['jump_host'] = Variable<String>(jumpHost.value);
    }
    if (jumpPort.present) {
      map['jump_port'] = Variable<int>(jumpPort.value);
    }
    if (jumpUsername.present) {
      map['jump_username'] = Variable<String>(jumpUsername.value);
    }
    if (group.present) {
      map['group'] = Variable<String>(group.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConnectionTableCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('username: $username, ')
          ..write('authMethod: $authMethod, ')
          ..write('terminalWidth: $terminalWidth, ')
          ..write('terminalHeight: $terminalHeight, ')
          ..write('keepAlive: $keepAlive, ')
          ..write('keepAliveInterval: $keepAliveInterval, ')
          ..write('launchMode: $launchMode, ')
          ..write('serverPlatform: $serverPlatform, ')
          ..write('tmuxAutoDeleteSeconds: $tmuxAutoDeleteSeconds, ')
          ..write('hostKeyFingerprint: $hostKeyFingerprint, ')
          ..write('hostKeyAlgorithm: $hostKeyAlgorithm, ')
          ..write('hostKeyTrustedAt: $hostKeyTrustedAt, ')
          ..write('jumpHost: $jumpHost, ')
          ..write('jumpPort: $jumpPort, ')
          ..write('jumpUsername: $jumpUsername, ')
          ..write('group: $group, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$ConnectionDatabase extends GeneratedDatabase {
  _$ConnectionDatabase(QueryExecutor e) : super(e);
  $ConnectionDatabaseManager get managers => $ConnectionDatabaseManager(this);
  late final $ConnectionTableTable connectionTable = $ConnectionTableTable(
    this,
  );
  late final ConnectionDao connectionDao = ConnectionDao(
    this as ConnectionDatabase,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [connectionTable];
}

typedef $$ConnectionTableTableCreateCompanionBuilder =
    ConnectionTableCompanion Function({
      required String id,
      required String name,
      required String host,
      required int port,
      required String username,
      required String authMethod,
      required int terminalWidth,
      required int terminalHeight,
      required bool keepAlive,
      required int keepAliveInterval,
      required String launchMode,
      required String serverPlatform,
      required int tmuxAutoDeleteSeconds,
      Value<String?> hostKeyFingerprint,
      Value<String?> hostKeyAlgorithm,
      Value<int?> hostKeyTrustedAt,
      Value<String?> jumpHost,
      Value<int?> jumpPort,
      Value<String?> jumpUsername,
      Value<String?> group,
      required int createdAt,
      required int updatedAt,
      Value<int> sortOrder,
      Value<int> rowid,
    });
typedef $$ConnectionTableTableUpdateCompanionBuilder =
    ConnectionTableCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> host,
      Value<int> port,
      Value<String> username,
      Value<String> authMethod,
      Value<int> terminalWidth,
      Value<int> terminalHeight,
      Value<bool> keepAlive,
      Value<int> keepAliveInterval,
      Value<String> launchMode,
      Value<String> serverPlatform,
      Value<int> tmuxAutoDeleteSeconds,
      Value<String?> hostKeyFingerprint,
      Value<String?> hostKeyAlgorithm,
      Value<int?> hostKeyTrustedAt,
      Value<String?> jumpHost,
      Value<int?> jumpPort,
      Value<String?> jumpUsername,
      Value<String?> group,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> sortOrder,
      Value<int> rowid,
    });

class $$ConnectionTableTableFilterComposer
    extends Composer<_$ConnectionDatabase, $ConnectionTableTable> {
  $$ConnectionTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get host => $composableBuilder(
    column: $table.host,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get authMethod => $composableBuilder(
    column: $table.authMethod,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get terminalWidth => $composableBuilder(
    column: $table.terminalWidth,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get terminalHeight => $composableBuilder(
    column: $table.terminalHeight,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get keepAlive => $composableBuilder(
    column: $table.keepAlive,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get keepAliveInterval => $composableBuilder(
    column: $table.keepAliveInterval,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get launchMode => $composableBuilder(
    column: $table.launchMode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverPlatform => $composableBuilder(
    column: $table.serverPlatform,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get tmuxAutoDeleteSeconds => $composableBuilder(
    column: $table.tmuxAutoDeleteSeconds,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get hostKeyFingerprint => $composableBuilder(
    column: $table.hostKeyFingerprint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get hostKeyAlgorithm => $composableBuilder(
    column: $table.hostKeyAlgorithm,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get hostKeyTrustedAt => $composableBuilder(
    column: $table.hostKeyTrustedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get jumpHost => $composableBuilder(
    column: $table.jumpHost,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get jumpPort => $composableBuilder(
    column: $table.jumpPort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get jumpUsername => $composableBuilder(
    column: $table.jumpUsername,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get group => $composableBuilder(
    column: $table.group,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ConnectionTableTableOrderingComposer
    extends Composer<_$ConnectionDatabase, $ConnectionTableTable> {
  $$ConnectionTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get host => $composableBuilder(
    column: $table.host,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get authMethod => $composableBuilder(
    column: $table.authMethod,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get terminalWidth => $composableBuilder(
    column: $table.terminalWidth,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get terminalHeight => $composableBuilder(
    column: $table.terminalHeight,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get keepAlive => $composableBuilder(
    column: $table.keepAlive,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get keepAliveInterval => $composableBuilder(
    column: $table.keepAliveInterval,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get launchMode => $composableBuilder(
    column: $table.launchMode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverPlatform => $composableBuilder(
    column: $table.serverPlatform,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get tmuxAutoDeleteSeconds => $composableBuilder(
    column: $table.tmuxAutoDeleteSeconds,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get hostKeyFingerprint => $composableBuilder(
    column: $table.hostKeyFingerprint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get hostKeyAlgorithm => $composableBuilder(
    column: $table.hostKeyAlgorithm,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get hostKeyTrustedAt => $composableBuilder(
    column: $table.hostKeyTrustedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get jumpHost => $composableBuilder(
    column: $table.jumpHost,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get jumpPort => $composableBuilder(
    column: $table.jumpPort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get jumpUsername => $composableBuilder(
    column: $table.jumpUsername,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get group => $composableBuilder(
    column: $table.group,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ConnectionTableTableAnnotationComposer
    extends Composer<_$ConnectionDatabase, $ConnectionTableTable> {
  $$ConnectionTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get host =>
      $composableBuilder(column: $table.host, builder: (column) => column);

  GeneratedColumn<int> get port =>
      $composableBuilder(column: $table.port, builder: (column) => column);

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get authMethod => $composableBuilder(
    column: $table.authMethod,
    builder: (column) => column,
  );

  GeneratedColumn<int> get terminalWidth => $composableBuilder(
    column: $table.terminalWidth,
    builder: (column) => column,
  );

  GeneratedColumn<int> get terminalHeight => $composableBuilder(
    column: $table.terminalHeight,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get keepAlive =>
      $composableBuilder(column: $table.keepAlive, builder: (column) => column);

  GeneratedColumn<int> get keepAliveInterval => $composableBuilder(
    column: $table.keepAliveInterval,
    builder: (column) => column,
  );

  GeneratedColumn<String> get launchMode => $composableBuilder(
    column: $table.launchMode,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverPlatform => $composableBuilder(
    column: $table.serverPlatform,
    builder: (column) => column,
  );

  GeneratedColumn<int> get tmuxAutoDeleteSeconds => $composableBuilder(
    column: $table.tmuxAutoDeleteSeconds,
    builder: (column) => column,
  );

  GeneratedColumn<String> get hostKeyFingerprint => $composableBuilder(
    column: $table.hostKeyFingerprint,
    builder: (column) => column,
  );

  GeneratedColumn<String> get hostKeyAlgorithm => $composableBuilder(
    column: $table.hostKeyAlgorithm,
    builder: (column) => column,
  );

  GeneratedColumn<int> get hostKeyTrustedAt => $composableBuilder(
    column: $table.hostKeyTrustedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get jumpHost =>
      $composableBuilder(column: $table.jumpHost, builder: (column) => column);

  GeneratedColumn<int> get jumpPort =>
      $composableBuilder(column: $table.jumpPort, builder: (column) => column);

  GeneratedColumn<String> get jumpUsername => $composableBuilder(
    column: $table.jumpUsername,
    builder: (column) => column,
  );

  GeneratedColumn<String> get group =>
      $composableBuilder(column: $table.group, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);
}

class $$ConnectionTableTableTableManager
    extends
        RootTableManager<
          _$ConnectionDatabase,
          $ConnectionTableTable,
          ConnectionTableData,
          $$ConnectionTableTableFilterComposer,
          $$ConnectionTableTableOrderingComposer,
          $$ConnectionTableTableAnnotationComposer,
          $$ConnectionTableTableCreateCompanionBuilder,
          $$ConnectionTableTableUpdateCompanionBuilder,
          (
            ConnectionTableData,
            BaseReferences<
              _$ConnectionDatabase,
              $ConnectionTableTable,
              ConnectionTableData
            >,
          ),
          ConnectionTableData,
          PrefetchHooks Function()
        > {
  $$ConnectionTableTableTableManager(
    _$ConnectionDatabase db,
    $ConnectionTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConnectionTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConnectionTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConnectionTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> host = const Value.absent(),
                Value<int> port = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String> authMethod = const Value.absent(),
                Value<int> terminalWidth = const Value.absent(),
                Value<int> terminalHeight = const Value.absent(),
                Value<bool> keepAlive = const Value.absent(),
                Value<int> keepAliveInterval = const Value.absent(),
                Value<String> launchMode = const Value.absent(),
                Value<String> serverPlatform = const Value.absent(),
                Value<int> tmuxAutoDeleteSeconds = const Value.absent(),
                Value<String?> hostKeyFingerprint = const Value.absent(),
                Value<String?> hostKeyAlgorithm = const Value.absent(),
                Value<int?> hostKeyTrustedAt = const Value.absent(),
                Value<String?> jumpHost = const Value.absent(),
                Value<int?> jumpPort = const Value.absent(),
                Value<String?> jumpUsername = const Value.absent(),
                Value<String?> group = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConnectionTableCompanion(
                id: id,
                name: name,
                host: host,
                port: port,
                username: username,
                authMethod: authMethod,
                terminalWidth: terminalWidth,
                terminalHeight: terminalHeight,
                keepAlive: keepAlive,
                keepAliveInterval: keepAliveInterval,
                launchMode: launchMode,
                serverPlatform: serverPlatform,
                tmuxAutoDeleteSeconds: tmuxAutoDeleteSeconds,
                hostKeyFingerprint: hostKeyFingerprint,
                hostKeyAlgorithm: hostKeyAlgorithm,
                hostKeyTrustedAt: hostKeyTrustedAt,
                jumpHost: jumpHost,
                jumpPort: jumpPort,
                jumpUsername: jumpUsername,
                group: group,
                createdAt: createdAt,
                updatedAt: updatedAt,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String host,
                required int port,
                required String username,
                required String authMethod,
                required int terminalWidth,
                required int terminalHeight,
                required bool keepAlive,
                required int keepAliveInterval,
                required String launchMode,
                required String serverPlatform,
                required int tmuxAutoDeleteSeconds,
                Value<String?> hostKeyFingerprint = const Value.absent(),
                Value<String?> hostKeyAlgorithm = const Value.absent(),
                Value<int?> hostKeyTrustedAt = const Value.absent(),
                Value<String?> jumpHost = const Value.absent(),
                Value<int?> jumpPort = const Value.absent(),
                Value<String?> jumpUsername = const Value.absent(),
                Value<String?> group = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConnectionTableCompanion.insert(
                id: id,
                name: name,
                host: host,
                port: port,
                username: username,
                authMethod: authMethod,
                terminalWidth: terminalWidth,
                terminalHeight: terminalHeight,
                keepAlive: keepAlive,
                keepAliveInterval: keepAliveInterval,
                launchMode: launchMode,
                serverPlatform: serverPlatform,
                tmuxAutoDeleteSeconds: tmuxAutoDeleteSeconds,
                hostKeyFingerprint: hostKeyFingerprint,
                hostKeyAlgorithm: hostKeyAlgorithm,
                hostKeyTrustedAt: hostKeyTrustedAt,
                jumpHost: jumpHost,
                jumpPort: jumpPort,
                jumpUsername: jumpUsername,
                group: group,
                createdAt: createdAt,
                updatedAt: updatedAt,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ConnectionTableTableProcessedTableManager =
    ProcessedTableManager<
      _$ConnectionDatabase,
      $ConnectionTableTable,
      ConnectionTableData,
      $$ConnectionTableTableFilterComposer,
      $$ConnectionTableTableOrderingComposer,
      $$ConnectionTableTableAnnotationComposer,
      $$ConnectionTableTableCreateCompanionBuilder,
      $$ConnectionTableTableUpdateCompanionBuilder,
      (
        ConnectionTableData,
        BaseReferences<
          _$ConnectionDatabase,
          $ConnectionTableTable,
          ConnectionTableData
        >,
      ),
      ConnectionTableData,
      PrefetchHooks Function()
    >;

class $ConnectionDatabaseManager {
  final _$ConnectionDatabase _db;
  $ConnectionDatabaseManager(this._db);
  $$ConnectionTableTableTableManager get connectionTable =>
      $$ConnectionTableTableTableManager(_db, _db.connectionTable);
}

mixin _$ConnectionDaoMixin on DatabaseAccessor<ConnectionDatabase> {
  $ConnectionTableTable get connectionTable => attachedDatabase.connectionTable;
  ConnectionDaoManager get managers => ConnectionDaoManager(this);
}

class ConnectionDaoManager {
  final _$ConnectionDaoMixin _db;
  ConnectionDaoManager(this._db);
  $$ConnectionTableTableTableManager get connectionTable =>
      $$ConnectionTableTableTableManager(
        _db.attachedDatabase,
        _db.connectionTable,
      );
}
