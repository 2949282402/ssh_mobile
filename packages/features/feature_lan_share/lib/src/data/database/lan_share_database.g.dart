// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'lan_share_database.dart';

// ignore_for_file: type=lint
class $LanTransferRecordsTable extends LanTransferRecords
    with TableInfo<$LanTransferRecordsTable, LanTransferRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LanTransferRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderIdMeta = const VerificationMeta(
    'senderId',
  );
  @override
  late final GeneratedColumn<String> senderId = GeneratedColumn<String>(
    'sender_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderAliasMeta = const VerificationMeta(
    'senderAlias',
  );
  @override
  late final GeneratedColumn<String> senderAlias = GeneratedColumn<String>(
    'sender_alias',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _receiverIdMeta = const VerificationMeta(
    'receiverId',
  );
  @override
  late final GeneratedColumn<String> receiverId = GeneratedColumn<String>(
    'receiver_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadTypeMeta = const VerificationMeta(
    'payloadType',
  );
  @override
  late final GeneratedColumn<String> payloadType = GeneratedColumn<String>(
    'payload_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _textContentMeta = const VerificationMeta(
    'textContent',
  );
  @override
  late final GeneratedColumn<String> textContent = GeneratedColumn<String>(
    'text_content',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fileNameMeta = const VerificationMeta(
    'fileName',
  );
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
    'file_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fileSizeMeta = const VerificationMeta(
    'fileSize',
  );
  @override
  late final GeneratedColumn<int> fileSize = GeneratedColumn<int>(
    'file_size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _localPathMeta = const VerificationMeta(
    'localPath',
  );
  @override
  late final GeneratedColumn<String> localPath = GeneratedColumn<String>(
    'local_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _manifestJsonMeta = const VerificationMeta(
    'manifestJson',
  );
  @override
  late final GeneratedColumn<String> manifestJson = GeneratedColumn<String>(
    'manifest_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bytesTransferredMeta = const VerificationMeta(
    'bytesTransferred',
  );
  @override
  late final GeneratedColumn<int> bytesTransferred = GeneratedColumn<int>(
    'bytes_transferred',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
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
  static const VerificationMeta _isIncomingMeta = const VerificationMeta(
    'isIncoming',
  );
  @override
  late final GeneratedColumn<bool> isIncoming = GeneratedColumn<bool>(
    'is_incoming',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_incoming" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isRecalledMeta = const VerificationMeta(
    'isRecalled',
  );
  @override
  late final GeneratedColumn<bool> isRecalled = GeneratedColumn<bool>(
    'is_recalled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_recalled" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _sftpServerIdMeta = const VerificationMeta(
    'sftpServerId',
  );
  @override
  late final GeneratedColumn<String> sftpServerId = GeneratedColumn<String>(
    'sftp_server_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sftpRemotePathMeta = const VerificationMeta(
    'sftpRemotePath',
  );
  @override
  late final GeneratedColumn<String> sftpRemotePath = GeneratedColumn<String>(
    'sftp_remote_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _transportMeta = const VerificationMeta(
    'transport',
  );
  @override
  late final GeneratedColumn<String> transport = GeneratedColumn<String>(
    'transport',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _routeTypeMeta = const VerificationMeta(
    'routeType',
  );
  @override
  late final GeneratedColumn<String> routeType = GeneratedColumn<String>(
    'route_type',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _avgRttMeta = const VerificationMeta('avgRtt');
  @override
  late final GeneratedColumn<int> avgRtt = GeneratedColumn<int>(
    'avg_rtt',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bytesTotalMeta = const VerificationMeta(
    'bytesTotal',
  );
  @override
  late final GeneratedColumn<int> bytesTotal = GeneratedColumn<int>(
    'bytes_total',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _failureReasonMeta = const VerificationMeta(
    'failureReason',
  );
  @override
  late final GeneratedColumn<String> failureReason = GeneratedColumn<String>(
    'failure_reason',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    senderId,
    senderAlias,
    receiverId,
    payloadType,
    textContent,
    fileName,
    fileSize,
    localPath,
    manifestJson,
    status,
    bytesTransferred,
    createdAt,
    isIncoming,
    isRecalled,
    sftpServerId,
    sftpRemotePath,
    transport,
    routeType,
    avgRtt,
    bytesTotal,
    failureReason,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'lan_transfer_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<LanTransferRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('sender_id')) {
      context.handle(
        _senderIdMeta,
        senderId.isAcceptableOrUnknown(data['sender_id']!, _senderIdMeta),
      );
    } else if (isInserting) {
      context.missing(_senderIdMeta);
    }
    if (data.containsKey('sender_alias')) {
      context.handle(
        _senderAliasMeta,
        senderAlias.isAcceptableOrUnknown(
          data['sender_alias']!,
          _senderAliasMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_senderAliasMeta);
    }
    if (data.containsKey('receiver_id')) {
      context.handle(
        _receiverIdMeta,
        receiverId.isAcceptableOrUnknown(data['receiver_id']!, _receiverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_receiverIdMeta);
    }
    if (data.containsKey('payload_type')) {
      context.handle(
        _payloadTypeMeta,
        payloadType.isAcceptableOrUnknown(
          data['payload_type']!,
          _payloadTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadTypeMeta);
    }
    if (data.containsKey('text_content')) {
      context.handle(
        _textContentMeta,
        textContent.isAcceptableOrUnknown(
          data['text_content']!,
          _textContentMeta,
        ),
      );
    }
    if (data.containsKey('file_name')) {
      context.handle(
        _fileNameMeta,
        fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta),
      );
    }
    if (data.containsKey('file_size')) {
      context.handle(
        _fileSizeMeta,
        fileSize.isAcceptableOrUnknown(data['file_size']!, _fileSizeMeta),
      );
    }
    if (data.containsKey('local_path')) {
      context.handle(
        _localPathMeta,
        localPath.isAcceptableOrUnknown(data['local_path']!, _localPathMeta),
      );
    }
    if (data.containsKey('manifest_json')) {
      context.handle(
        _manifestJsonMeta,
        manifestJson.isAcceptableOrUnknown(
          data['manifest_json']!,
          _manifestJsonMeta,
        ),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('bytes_transferred')) {
      context.handle(
        _bytesTransferredMeta,
        bytesTransferred.isAcceptableOrUnknown(
          data['bytes_transferred']!,
          _bytesTransferredMeta,
        ),
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
    if (data.containsKey('is_incoming')) {
      context.handle(
        _isIncomingMeta,
        isIncoming.isAcceptableOrUnknown(data['is_incoming']!, _isIncomingMeta),
      );
    }
    if (data.containsKey('is_recalled')) {
      context.handle(
        _isRecalledMeta,
        isRecalled.isAcceptableOrUnknown(data['is_recalled']!, _isRecalledMeta),
      );
    }
    if (data.containsKey('sftp_server_id')) {
      context.handle(
        _sftpServerIdMeta,
        sftpServerId.isAcceptableOrUnknown(
          data['sftp_server_id']!,
          _sftpServerIdMeta,
        ),
      );
    }
    if (data.containsKey('sftp_remote_path')) {
      context.handle(
        _sftpRemotePathMeta,
        sftpRemotePath.isAcceptableOrUnknown(
          data['sftp_remote_path']!,
          _sftpRemotePathMeta,
        ),
      );
    }
    if (data.containsKey('transport')) {
      context.handle(
        _transportMeta,
        transport.isAcceptableOrUnknown(data['transport']!, _transportMeta),
      );
    }
    if (data.containsKey('route_type')) {
      context.handle(
        _routeTypeMeta,
        routeType.isAcceptableOrUnknown(data['route_type']!, _routeTypeMeta),
      );
    }
    if (data.containsKey('avg_rtt')) {
      context.handle(
        _avgRttMeta,
        avgRtt.isAcceptableOrUnknown(data['avg_rtt']!, _avgRttMeta),
      );
    }
    if (data.containsKey('bytes_total')) {
      context.handle(
        _bytesTotalMeta,
        bytesTotal.isAcceptableOrUnknown(data['bytes_total']!, _bytesTotalMeta),
      );
    }
    if (data.containsKey('failure_reason')) {
      context.handle(
        _failureReasonMeta,
        failureReason.isAcceptableOrUnknown(
          data['failure_reason']!,
          _failureReasonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LanTransferRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LanTransferRecord(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      senderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_id'],
      )!,
      senderAlias: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_alias'],
      )!,
      receiverId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}receiver_id'],
      )!,
      payloadType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_type'],
      )!,
      textContent: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}text_content'],
      ),
      fileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_name'],
      ),
      fileSize: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}file_size'],
      )!,
      localPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_path'],
      ),
      manifestJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}manifest_json'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      bytesTransferred: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bytes_transferred'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      isIncoming: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_incoming'],
      )!,
      isRecalled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_recalled'],
      )!,
      sftpServerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sftp_server_id'],
      ),
      sftpRemotePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sftp_remote_path'],
      ),
      transport: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}transport'],
      ),
      routeType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}route_type'],
      ),
      avgRtt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}avg_rtt'],
      ),
      bytesTotal: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bytes_total'],
      ),
      failureReason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}failure_reason'],
      ),
    );
  }

  @override
  $LanTransferRecordsTable createAlias(String alias) {
    return $LanTransferRecordsTable(attachedDatabase, alias);
  }
}

class LanTransferRecord extends DataClass
    implements Insertable<LanTransferRecord> {
  final String id;
  final String senderId;
  final String senderAlias;
  final String receiverId;
  final String payloadType;
  final String? textContent;
  final String? fileName;
  final int fileSize;
  final String? localPath;
  final String? manifestJson;
  final String status;
  final int bytesTransferred;
  final int createdAt;
  final bool isIncoming;
  final bool isRecalled;
  final String? sftpServerId;
  final String? sftpRemotePath;
  final String? transport;
  final String? routeType;
  final int? avgRtt;
  final int? bytesTotal;
  final String? failureReason;
  const LanTransferRecord({
    required this.id,
    required this.senderId,
    required this.senderAlias,
    required this.receiverId,
    required this.payloadType,
    this.textContent,
    this.fileName,
    required this.fileSize,
    this.localPath,
    this.manifestJson,
    required this.status,
    required this.bytesTransferred,
    required this.createdAt,
    required this.isIncoming,
    required this.isRecalled,
    this.sftpServerId,
    this.sftpRemotePath,
    this.transport,
    this.routeType,
    this.avgRtt,
    this.bytesTotal,
    this.failureReason,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['sender_id'] = Variable<String>(senderId);
    map['sender_alias'] = Variable<String>(senderAlias);
    map['receiver_id'] = Variable<String>(receiverId);
    map['payload_type'] = Variable<String>(payloadType);
    if (!nullToAbsent || textContent != null) {
      map['text_content'] = Variable<String>(textContent);
    }
    if (!nullToAbsent || fileName != null) {
      map['file_name'] = Variable<String>(fileName);
    }
    map['file_size'] = Variable<int>(fileSize);
    if (!nullToAbsent || localPath != null) {
      map['local_path'] = Variable<String>(localPath);
    }
    if (!nullToAbsent || manifestJson != null) {
      map['manifest_json'] = Variable<String>(manifestJson);
    }
    map['status'] = Variable<String>(status);
    map['bytes_transferred'] = Variable<int>(bytesTransferred);
    map['created_at'] = Variable<int>(createdAt);
    map['is_incoming'] = Variable<bool>(isIncoming);
    map['is_recalled'] = Variable<bool>(isRecalled);
    if (!nullToAbsent || sftpServerId != null) {
      map['sftp_server_id'] = Variable<String>(sftpServerId);
    }
    if (!nullToAbsent || sftpRemotePath != null) {
      map['sftp_remote_path'] = Variable<String>(sftpRemotePath);
    }
    if (!nullToAbsent || transport != null) {
      map['transport'] = Variable<String>(transport);
    }
    if (!nullToAbsent || routeType != null) {
      map['route_type'] = Variable<String>(routeType);
    }
    if (!nullToAbsent || avgRtt != null) {
      map['avg_rtt'] = Variable<int>(avgRtt);
    }
    if (!nullToAbsent || bytesTotal != null) {
      map['bytes_total'] = Variable<int>(bytesTotal);
    }
    if (!nullToAbsent || failureReason != null) {
      map['failure_reason'] = Variable<String>(failureReason);
    }
    return map;
  }

  LanTransferRecordsCompanion toCompanion(bool nullToAbsent) {
    return LanTransferRecordsCompanion(
      id: Value(id),
      senderId: Value(senderId),
      senderAlias: Value(senderAlias),
      receiverId: Value(receiverId),
      payloadType: Value(payloadType),
      textContent: textContent == null && nullToAbsent
          ? const Value.absent()
          : Value(textContent),
      fileName: fileName == null && nullToAbsent
          ? const Value.absent()
          : Value(fileName),
      fileSize: Value(fileSize),
      localPath: localPath == null && nullToAbsent
          ? const Value.absent()
          : Value(localPath),
      manifestJson: manifestJson == null && nullToAbsent
          ? const Value.absent()
          : Value(manifestJson),
      status: Value(status),
      bytesTransferred: Value(bytesTransferred),
      createdAt: Value(createdAt),
      isIncoming: Value(isIncoming),
      isRecalled: Value(isRecalled),
      sftpServerId: sftpServerId == null && nullToAbsent
          ? const Value.absent()
          : Value(sftpServerId),
      sftpRemotePath: sftpRemotePath == null && nullToAbsent
          ? const Value.absent()
          : Value(sftpRemotePath),
      transport: transport == null && nullToAbsent
          ? const Value.absent()
          : Value(transport),
      routeType: routeType == null && nullToAbsent
          ? const Value.absent()
          : Value(routeType),
      avgRtt: avgRtt == null && nullToAbsent
          ? const Value.absent()
          : Value(avgRtt),
      bytesTotal: bytesTotal == null && nullToAbsent
          ? const Value.absent()
          : Value(bytesTotal),
      failureReason: failureReason == null && nullToAbsent
          ? const Value.absent()
          : Value(failureReason),
    );
  }

  factory LanTransferRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LanTransferRecord(
      id: serializer.fromJson<String>(json['id']),
      senderId: serializer.fromJson<String>(json['senderId']),
      senderAlias: serializer.fromJson<String>(json['senderAlias']),
      receiverId: serializer.fromJson<String>(json['receiverId']),
      payloadType: serializer.fromJson<String>(json['payloadType']),
      textContent: serializer.fromJson<String?>(json['textContent']),
      fileName: serializer.fromJson<String?>(json['fileName']),
      fileSize: serializer.fromJson<int>(json['fileSize']),
      localPath: serializer.fromJson<String?>(json['localPath']),
      manifestJson: serializer.fromJson<String?>(json['manifestJson']),
      status: serializer.fromJson<String>(json['status']),
      bytesTransferred: serializer.fromJson<int>(json['bytesTransferred']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      isIncoming: serializer.fromJson<bool>(json['isIncoming']),
      isRecalled: serializer.fromJson<bool>(json['isRecalled']),
      sftpServerId: serializer.fromJson<String?>(json['sftpServerId']),
      sftpRemotePath: serializer.fromJson<String?>(json['sftpRemotePath']),
      transport: serializer.fromJson<String?>(json['transport']),
      routeType: serializer.fromJson<String?>(json['routeType']),
      avgRtt: serializer.fromJson<int?>(json['avgRtt']),
      bytesTotal: serializer.fromJson<int?>(json['bytesTotal']),
      failureReason: serializer.fromJson<String?>(json['failureReason']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'senderId': serializer.toJson<String>(senderId),
      'senderAlias': serializer.toJson<String>(senderAlias),
      'receiverId': serializer.toJson<String>(receiverId),
      'payloadType': serializer.toJson<String>(payloadType),
      'textContent': serializer.toJson<String?>(textContent),
      'fileName': serializer.toJson<String?>(fileName),
      'fileSize': serializer.toJson<int>(fileSize),
      'localPath': serializer.toJson<String?>(localPath),
      'manifestJson': serializer.toJson<String?>(manifestJson),
      'status': serializer.toJson<String>(status),
      'bytesTransferred': serializer.toJson<int>(bytesTransferred),
      'createdAt': serializer.toJson<int>(createdAt),
      'isIncoming': serializer.toJson<bool>(isIncoming),
      'isRecalled': serializer.toJson<bool>(isRecalled),
      'sftpServerId': serializer.toJson<String?>(sftpServerId),
      'sftpRemotePath': serializer.toJson<String?>(sftpRemotePath),
      'transport': serializer.toJson<String?>(transport),
      'routeType': serializer.toJson<String?>(routeType),
      'avgRtt': serializer.toJson<int?>(avgRtt),
      'bytesTotal': serializer.toJson<int?>(bytesTotal),
      'failureReason': serializer.toJson<String?>(failureReason),
    };
  }

  LanTransferRecord copyWith({
    String? id,
    String? senderId,
    String? senderAlias,
    String? receiverId,
    String? payloadType,
    Value<String?> textContent = const Value.absent(),
    Value<String?> fileName = const Value.absent(),
    int? fileSize,
    Value<String?> localPath = const Value.absent(),
    Value<String?> manifestJson = const Value.absent(),
    String? status,
    int? bytesTransferred,
    int? createdAt,
    bool? isIncoming,
    bool? isRecalled,
    Value<String?> sftpServerId = const Value.absent(),
    Value<String?> sftpRemotePath = const Value.absent(),
    Value<String?> transport = const Value.absent(),
    Value<String?> routeType = const Value.absent(),
    Value<int?> avgRtt = const Value.absent(),
    Value<int?> bytesTotal = const Value.absent(),
    Value<String?> failureReason = const Value.absent(),
  }) => LanTransferRecord(
    id: id ?? this.id,
    senderId: senderId ?? this.senderId,
    senderAlias: senderAlias ?? this.senderAlias,
    receiverId: receiverId ?? this.receiverId,
    payloadType: payloadType ?? this.payloadType,
    textContent: textContent.present ? textContent.value : this.textContent,
    fileName: fileName.present ? fileName.value : this.fileName,
    fileSize: fileSize ?? this.fileSize,
    localPath: localPath.present ? localPath.value : this.localPath,
    manifestJson: manifestJson.present ? manifestJson.value : this.manifestJson,
    status: status ?? this.status,
    bytesTransferred: bytesTransferred ?? this.bytesTransferred,
    createdAt: createdAt ?? this.createdAt,
    isIncoming: isIncoming ?? this.isIncoming,
    isRecalled: isRecalled ?? this.isRecalled,
    sftpServerId: sftpServerId.present ? sftpServerId.value : this.sftpServerId,
    sftpRemotePath: sftpRemotePath.present
        ? sftpRemotePath.value
        : this.sftpRemotePath,
    transport: transport.present ? transport.value : this.transport,
    routeType: routeType.present ? routeType.value : this.routeType,
    avgRtt: avgRtt.present ? avgRtt.value : this.avgRtt,
    bytesTotal: bytesTotal.present ? bytesTotal.value : this.bytesTotal,
    failureReason: failureReason.present
        ? failureReason.value
        : this.failureReason,
  );
  LanTransferRecord copyWithCompanion(LanTransferRecordsCompanion data) {
    return LanTransferRecord(
      id: data.id.present ? data.id.value : this.id,
      senderId: data.senderId.present ? data.senderId.value : this.senderId,
      senderAlias: data.senderAlias.present
          ? data.senderAlias.value
          : this.senderAlias,
      receiverId: data.receiverId.present
          ? data.receiverId.value
          : this.receiverId,
      payloadType: data.payloadType.present
          ? data.payloadType.value
          : this.payloadType,
      textContent: data.textContent.present
          ? data.textContent.value
          : this.textContent,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      fileSize: data.fileSize.present ? data.fileSize.value : this.fileSize,
      localPath: data.localPath.present ? data.localPath.value : this.localPath,
      manifestJson: data.manifestJson.present
          ? data.manifestJson.value
          : this.manifestJson,
      status: data.status.present ? data.status.value : this.status,
      bytesTransferred: data.bytesTransferred.present
          ? data.bytesTransferred.value
          : this.bytesTransferred,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      isIncoming: data.isIncoming.present
          ? data.isIncoming.value
          : this.isIncoming,
      isRecalled: data.isRecalled.present
          ? data.isRecalled.value
          : this.isRecalled,
      sftpServerId: data.sftpServerId.present
          ? data.sftpServerId.value
          : this.sftpServerId,
      sftpRemotePath: data.sftpRemotePath.present
          ? data.sftpRemotePath.value
          : this.sftpRemotePath,
      transport: data.transport.present ? data.transport.value : this.transport,
      routeType: data.routeType.present ? data.routeType.value : this.routeType,
      avgRtt: data.avgRtt.present ? data.avgRtt.value : this.avgRtt,
      bytesTotal: data.bytesTotal.present
          ? data.bytesTotal.value
          : this.bytesTotal,
      failureReason: data.failureReason.present
          ? data.failureReason.value
          : this.failureReason,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LanTransferRecord(')
          ..write('id: $id, ')
          ..write('senderId: $senderId, ')
          ..write('senderAlias: $senderAlias, ')
          ..write('receiverId: $receiverId, ')
          ..write('payloadType: $payloadType, ')
          ..write('textContent: $textContent, ')
          ..write('fileName: $fileName, ')
          ..write('fileSize: $fileSize, ')
          ..write('localPath: $localPath, ')
          ..write('manifestJson: $manifestJson, ')
          ..write('status: $status, ')
          ..write('bytesTransferred: $bytesTransferred, ')
          ..write('createdAt: $createdAt, ')
          ..write('isIncoming: $isIncoming, ')
          ..write('isRecalled: $isRecalled, ')
          ..write('sftpServerId: $sftpServerId, ')
          ..write('sftpRemotePath: $sftpRemotePath, ')
          ..write('transport: $transport, ')
          ..write('routeType: $routeType, ')
          ..write('avgRtt: $avgRtt, ')
          ..write('bytesTotal: $bytesTotal, ')
          ..write('failureReason: $failureReason')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    senderId,
    senderAlias,
    receiverId,
    payloadType,
    textContent,
    fileName,
    fileSize,
    localPath,
    manifestJson,
    status,
    bytesTransferred,
    createdAt,
    isIncoming,
    isRecalled,
    sftpServerId,
    sftpRemotePath,
    transport,
    routeType,
    avgRtt,
    bytesTotal,
    failureReason,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LanTransferRecord &&
          other.id == this.id &&
          other.senderId == this.senderId &&
          other.senderAlias == this.senderAlias &&
          other.receiverId == this.receiverId &&
          other.payloadType == this.payloadType &&
          other.textContent == this.textContent &&
          other.fileName == this.fileName &&
          other.fileSize == this.fileSize &&
          other.localPath == this.localPath &&
          other.manifestJson == this.manifestJson &&
          other.status == this.status &&
          other.bytesTransferred == this.bytesTransferred &&
          other.createdAt == this.createdAt &&
          other.isIncoming == this.isIncoming &&
          other.isRecalled == this.isRecalled &&
          other.sftpServerId == this.sftpServerId &&
          other.sftpRemotePath == this.sftpRemotePath &&
          other.transport == this.transport &&
          other.routeType == this.routeType &&
          other.avgRtt == this.avgRtt &&
          other.bytesTotal == this.bytesTotal &&
          other.failureReason == this.failureReason);
}

class LanTransferRecordsCompanion extends UpdateCompanion<LanTransferRecord> {
  final Value<String> id;
  final Value<String> senderId;
  final Value<String> senderAlias;
  final Value<String> receiverId;
  final Value<String> payloadType;
  final Value<String?> textContent;
  final Value<String?> fileName;
  final Value<int> fileSize;
  final Value<String?> localPath;
  final Value<String?> manifestJson;
  final Value<String> status;
  final Value<int> bytesTransferred;
  final Value<int> createdAt;
  final Value<bool> isIncoming;
  final Value<bool> isRecalled;
  final Value<String?> sftpServerId;
  final Value<String?> sftpRemotePath;
  final Value<String?> transport;
  final Value<String?> routeType;
  final Value<int?> avgRtt;
  final Value<int?> bytesTotal;
  final Value<String?> failureReason;
  final Value<int> rowid;
  const LanTransferRecordsCompanion({
    this.id = const Value.absent(),
    this.senderId = const Value.absent(),
    this.senderAlias = const Value.absent(),
    this.receiverId = const Value.absent(),
    this.payloadType = const Value.absent(),
    this.textContent = const Value.absent(),
    this.fileName = const Value.absent(),
    this.fileSize = const Value.absent(),
    this.localPath = const Value.absent(),
    this.manifestJson = const Value.absent(),
    this.status = const Value.absent(),
    this.bytesTransferred = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.isIncoming = const Value.absent(),
    this.isRecalled = const Value.absent(),
    this.sftpServerId = const Value.absent(),
    this.sftpRemotePath = const Value.absent(),
    this.transport = const Value.absent(),
    this.routeType = const Value.absent(),
    this.avgRtt = const Value.absent(),
    this.bytesTotal = const Value.absent(),
    this.failureReason = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LanTransferRecordsCompanion.insert({
    required String id,
    required String senderId,
    required String senderAlias,
    required String receiverId,
    required String payloadType,
    this.textContent = const Value.absent(),
    this.fileName = const Value.absent(),
    this.fileSize = const Value.absent(),
    this.localPath = const Value.absent(),
    this.manifestJson = const Value.absent(),
    required String status,
    this.bytesTransferred = const Value.absent(),
    required int createdAt,
    this.isIncoming = const Value.absent(),
    this.isRecalled = const Value.absent(),
    this.sftpServerId = const Value.absent(),
    this.sftpRemotePath = const Value.absent(),
    this.transport = const Value.absent(),
    this.routeType = const Value.absent(),
    this.avgRtt = const Value.absent(),
    this.bytesTotal = const Value.absent(),
    this.failureReason = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       senderId = Value(senderId),
       senderAlias = Value(senderAlias),
       receiverId = Value(receiverId),
       payloadType = Value(payloadType),
       status = Value(status),
       createdAt = Value(createdAt);
  static Insertable<LanTransferRecord> custom({
    Expression<String>? id,
    Expression<String>? senderId,
    Expression<String>? senderAlias,
    Expression<String>? receiverId,
    Expression<String>? payloadType,
    Expression<String>? textContent,
    Expression<String>? fileName,
    Expression<int>? fileSize,
    Expression<String>? localPath,
    Expression<String>? manifestJson,
    Expression<String>? status,
    Expression<int>? bytesTransferred,
    Expression<int>? createdAt,
    Expression<bool>? isIncoming,
    Expression<bool>? isRecalled,
    Expression<String>? sftpServerId,
    Expression<String>? sftpRemotePath,
    Expression<String>? transport,
    Expression<String>? routeType,
    Expression<int>? avgRtt,
    Expression<int>? bytesTotal,
    Expression<String>? failureReason,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (senderId != null) 'sender_id': senderId,
      if (senderAlias != null) 'sender_alias': senderAlias,
      if (receiverId != null) 'receiver_id': receiverId,
      if (payloadType != null) 'payload_type': payloadType,
      if (textContent != null) 'text_content': textContent,
      if (fileName != null) 'file_name': fileName,
      if (fileSize != null) 'file_size': fileSize,
      if (localPath != null) 'local_path': localPath,
      if (manifestJson != null) 'manifest_json': manifestJson,
      if (status != null) 'status': status,
      if (bytesTransferred != null) 'bytes_transferred': bytesTransferred,
      if (createdAt != null) 'created_at': createdAt,
      if (isIncoming != null) 'is_incoming': isIncoming,
      if (isRecalled != null) 'is_recalled': isRecalled,
      if (sftpServerId != null) 'sftp_server_id': sftpServerId,
      if (sftpRemotePath != null) 'sftp_remote_path': sftpRemotePath,
      if (transport != null) 'transport': transport,
      if (routeType != null) 'route_type': routeType,
      if (avgRtt != null) 'avg_rtt': avgRtt,
      if (bytesTotal != null) 'bytes_total': bytesTotal,
      if (failureReason != null) 'failure_reason': failureReason,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LanTransferRecordsCompanion copyWith({
    Value<String>? id,
    Value<String>? senderId,
    Value<String>? senderAlias,
    Value<String>? receiverId,
    Value<String>? payloadType,
    Value<String?>? textContent,
    Value<String?>? fileName,
    Value<int>? fileSize,
    Value<String?>? localPath,
    Value<String?>? manifestJson,
    Value<String>? status,
    Value<int>? bytesTransferred,
    Value<int>? createdAt,
    Value<bool>? isIncoming,
    Value<bool>? isRecalled,
    Value<String?>? sftpServerId,
    Value<String?>? sftpRemotePath,
    Value<String?>? transport,
    Value<String?>? routeType,
    Value<int?>? avgRtt,
    Value<int?>? bytesTotal,
    Value<String?>? failureReason,
    Value<int>? rowid,
  }) {
    return LanTransferRecordsCompanion(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      senderAlias: senderAlias ?? this.senderAlias,
      receiverId: receiverId ?? this.receiverId,
      payloadType: payloadType ?? this.payloadType,
      textContent: textContent ?? this.textContent,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      localPath: localPath ?? this.localPath,
      manifestJson: manifestJson ?? this.manifestJson,
      status: status ?? this.status,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      createdAt: createdAt ?? this.createdAt,
      isIncoming: isIncoming ?? this.isIncoming,
      isRecalled: isRecalled ?? this.isRecalled,
      sftpServerId: sftpServerId ?? this.sftpServerId,
      sftpRemotePath: sftpRemotePath ?? this.sftpRemotePath,
      transport: transport ?? this.transport,
      routeType: routeType ?? this.routeType,
      avgRtt: avgRtt ?? this.avgRtt,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      failureReason: failureReason ?? this.failureReason,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (senderId.present) {
      map['sender_id'] = Variable<String>(senderId.value);
    }
    if (senderAlias.present) {
      map['sender_alias'] = Variable<String>(senderAlias.value);
    }
    if (receiverId.present) {
      map['receiver_id'] = Variable<String>(receiverId.value);
    }
    if (payloadType.present) {
      map['payload_type'] = Variable<String>(payloadType.value);
    }
    if (textContent.present) {
      map['text_content'] = Variable<String>(textContent.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (fileSize.present) {
      map['file_size'] = Variable<int>(fileSize.value);
    }
    if (localPath.present) {
      map['local_path'] = Variable<String>(localPath.value);
    }
    if (manifestJson.present) {
      map['manifest_json'] = Variable<String>(manifestJson.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (bytesTransferred.present) {
      map['bytes_transferred'] = Variable<int>(bytesTransferred.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (isIncoming.present) {
      map['is_incoming'] = Variable<bool>(isIncoming.value);
    }
    if (isRecalled.present) {
      map['is_recalled'] = Variable<bool>(isRecalled.value);
    }
    if (sftpServerId.present) {
      map['sftp_server_id'] = Variable<String>(sftpServerId.value);
    }
    if (sftpRemotePath.present) {
      map['sftp_remote_path'] = Variable<String>(sftpRemotePath.value);
    }
    if (transport.present) {
      map['transport'] = Variable<String>(transport.value);
    }
    if (routeType.present) {
      map['route_type'] = Variable<String>(routeType.value);
    }
    if (avgRtt.present) {
      map['avg_rtt'] = Variable<int>(avgRtt.value);
    }
    if (bytesTotal.present) {
      map['bytes_total'] = Variable<int>(bytesTotal.value);
    }
    if (failureReason.present) {
      map['failure_reason'] = Variable<String>(failureReason.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LanTransferRecordsCompanion(')
          ..write('id: $id, ')
          ..write('senderId: $senderId, ')
          ..write('senderAlias: $senderAlias, ')
          ..write('receiverId: $receiverId, ')
          ..write('payloadType: $payloadType, ')
          ..write('textContent: $textContent, ')
          ..write('fileName: $fileName, ')
          ..write('fileSize: $fileSize, ')
          ..write('localPath: $localPath, ')
          ..write('manifestJson: $manifestJson, ')
          ..write('status: $status, ')
          ..write('bytesTransferred: $bytesTransferred, ')
          ..write('createdAt: $createdAt, ')
          ..write('isIncoming: $isIncoming, ')
          ..write('isRecalled: $isRecalled, ')
          ..write('sftpServerId: $sftpServerId, ')
          ..write('sftpRemotePath: $sftpRemotePath, ')
          ..write('transport: $transport, ')
          ..write('routeType: $routeType, ')
          ..write('avgRtt: $avgRtt, ')
          ..write('bytesTotal: $bytesTotal, ')
          ..write('failureReason: $failureReason, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LanPairingMetadataTable extends LanPairingMetadata
    with TableInfo<$LanPairingMetadataTable, LanPairingMetadataData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LanPairingMetadataTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _aliasMeta = const VerificationMeta('alias');
  @override
  late final GeneratedColumn<String> alias = GeneratedColumn<String>(
    'alias',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceTypeMeta = const VerificationMeta(
    'deviceType',
  );
  @override
  late final GeneratedColumn<String> deviceType = GeneratedColumn<String>(
    'device_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('mobile'),
  );
  static const VerificationMeta _ipMeta = const VerificationMeta('ip');
  @override
  late final GeneratedColumn<String> ip = GeneratedColumn<String>(
    'ip',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
    'port',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastSeenMeta = const VerificationMeta(
    'lastSeen',
  );
  @override
  late final GeneratedColumn<int> lastSeen = GeneratedColumn<int>(
    'last_seen',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    deviceId,
    alias,
    deviceType,
    ip,
    port,
    lastSeen,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'lan_pairing_metadata';
  @override
  VerificationContext validateIntegrity(
    Insertable<LanPairingMetadataData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('alias')) {
      context.handle(
        _aliasMeta,
        alias.isAcceptableOrUnknown(data['alias']!, _aliasMeta),
      );
    } else if (isInserting) {
      context.missing(_aliasMeta);
    }
    if (data.containsKey('device_type')) {
      context.handle(
        _deviceTypeMeta,
        deviceType.isAcceptableOrUnknown(data['device_type']!, _deviceTypeMeta),
      );
    }
    if (data.containsKey('ip')) {
      context.handle(_ipMeta, ip.isAcceptableOrUnknown(data['ip']!, _ipMeta));
    }
    if (data.containsKey('port')) {
      context.handle(
        _portMeta,
        port.isAcceptableOrUnknown(data['port']!, _portMeta),
      );
    }
    if (data.containsKey('last_seen')) {
      context.handle(
        _lastSeenMeta,
        lastSeen.isAcceptableOrUnknown(data['last_seen']!, _lastSeenMeta),
      );
    } else if (isInserting) {
      context.missing(_lastSeenMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {deviceId};
  @override
  LanPairingMetadataData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LanPairingMetadataData(
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      alias: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}alias'],
      )!,
      deviceType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_type'],
      )!,
      ip: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ip'],
      ),
      port: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}port'],
      ),
      lastSeen: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_seen'],
      )!,
    );
  }

  @override
  $LanPairingMetadataTable createAlias(String alias) {
    return $LanPairingMetadataTable(attachedDatabase, alias);
  }
}

class LanPairingMetadataData extends DataClass
    implements Insertable<LanPairingMetadataData> {
  final String deviceId;
  final String alias;
  final String deviceType;
  final String? ip;
  final int? port;
  final int lastSeen;
  const LanPairingMetadataData({
    required this.deviceId,
    required this.alias,
    required this.deviceType,
    this.ip,
    this.port,
    required this.lastSeen,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['device_id'] = Variable<String>(deviceId);
    map['alias'] = Variable<String>(alias);
    map['device_type'] = Variable<String>(deviceType);
    if (!nullToAbsent || ip != null) {
      map['ip'] = Variable<String>(ip);
    }
    if (!nullToAbsent || port != null) {
      map['port'] = Variable<int>(port);
    }
    map['last_seen'] = Variable<int>(lastSeen);
    return map;
  }

  LanPairingMetadataCompanion toCompanion(bool nullToAbsent) {
    return LanPairingMetadataCompanion(
      deviceId: Value(deviceId),
      alias: Value(alias),
      deviceType: Value(deviceType),
      ip: ip == null && nullToAbsent ? const Value.absent() : Value(ip),
      port: port == null && nullToAbsent ? const Value.absent() : Value(port),
      lastSeen: Value(lastSeen),
    );
  }

  factory LanPairingMetadataData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LanPairingMetadataData(
      deviceId: serializer.fromJson<String>(json['deviceId']),
      alias: serializer.fromJson<String>(json['alias']),
      deviceType: serializer.fromJson<String>(json['deviceType']),
      ip: serializer.fromJson<String?>(json['ip']),
      port: serializer.fromJson<int?>(json['port']),
      lastSeen: serializer.fromJson<int>(json['lastSeen']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'deviceId': serializer.toJson<String>(deviceId),
      'alias': serializer.toJson<String>(alias),
      'deviceType': serializer.toJson<String>(deviceType),
      'ip': serializer.toJson<String?>(ip),
      'port': serializer.toJson<int?>(port),
      'lastSeen': serializer.toJson<int>(lastSeen),
    };
  }

  LanPairingMetadataData copyWith({
    String? deviceId,
    String? alias,
    String? deviceType,
    Value<String?> ip = const Value.absent(),
    Value<int?> port = const Value.absent(),
    int? lastSeen,
  }) => LanPairingMetadataData(
    deviceId: deviceId ?? this.deviceId,
    alias: alias ?? this.alias,
    deviceType: deviceType ?? this.deviceType,
    ip: ip.present ? ip.value : this.ip,
    port: port.present ? port.value : this.port,
    lastSeen: lastSeen ?? this.lastSeen,
  );
  LanPairingMetadataData copyWithCompanion(LanPairingMetadataCompanion data) {
    return LanPairingMetadataData(
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      alias: data.alias.present ? data.alias.value : this.alias,
      deviceType: data.deviceType.present
          ? data.deviceType.value
          : this.deviceType,
      ip: data.ip.present ? data.ip.value : this.ip,
      port: data.port.present ? data.port.value : this.port,
      lastSeen: data.lastSeen.present ? data.lastSeen.value : this.lastSeen,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LanPairingMetadataData(')
          ..write('deviceId: $deviceId, ')
          ..write('alias: $alias, ')
          ..write('deviceType: $deviceType, ')
          ..write('ip: $ip, ')
          ..write('port: $port, ')
          ..write('lastSeen: $lastSeen')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(deviceId, alias, deviceType, ip, port, lastSeen);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LanPairingMetadataData &&
          other.deviceId == this.deviceId &&
          other.alias == this.alias &&
          other.deviceType == this.deviceType &&
          other.ip == this.ip &&
          other.port == this.port &&
          other.lastSeen == this.lastSeen);
}

class LanPairingMetadataCompanion
    extends UpdateCompanion<LanPairingMetadataData> {
  final Value<String> deviceId;
  final Value<String> alias;
  final Value<String> deviceType;
  final Value<String?> ip;
  final Value<int?> port;
  final Value<int> lastSeen;
  final Value<int> rowid;
  const LanPairingMetadataCompanion({
    this.deviceId = const Value.absent(),
    this.alias = const Value.absent(),
    this.deviceType = const Value.absent(),
    this.ip = const Value.absent(),
    this.port = const Value.absent(),
    this.lastSeen = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LanPairingMetadataCompanion.insert({
    required String deviceId,
    required String alias,
    this.deviceType = const Value.absent(),
    this.ip = const Value.absent(),
    this.port = const Value.absent(),
    required int lastSeen,
    this.rowid = const Value.absent(),
  }) : deviceId = Value(deviceId),
       alias = Value(alias),
       lastSeen = Value(lastSeen);
  static Insertable<LanPairingMetadataData> custom({
    Expression<String>? deviceId,
    Expression<String>? alias,
    Expression<String>? deviceType,
    Expression<String>? ip,
    Expression<int>? port,
    Expression<int>? lastSeen,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (deviceId != null) 'device_id': deviceId,
      if (alias != null) 'alias': alias,
      if (deviceType != null) 'device_type': deviceType,
      if (ip != null) 'ip': ip,
      if (port != null) 'port': port,
      if (lastSeen != null) 'last_seen': lastSeen,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LanPairingMetadataCompanion copyWith({
    Value<String>? deviceId,
    Value<String>? alias,
    Value<String>? deviceType,
    Value<String?>? ip,
    Value<int?>? port,
    Value<int>? lastSeen,
    Value<int>? rowid,
  }) {
    return LanPairingMetadataCompanion(
      deviceId: deviceId ?? this.deviceId,
      alias: alias ?? this.alias,
      deviceType: deviceType ?? this.deviceType,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      lastSeen: lastSeen ?? this.lastSeen,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (alias.present) {
      map['alias'] = Variable<String>(alias.value);
    }
    if (deviceType.present) {
      map['device_type'] = Variable<String>(deviceType.value);
    }
    if (ip.present) {
      map['ip'] = Variable<String>(ip.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (lastSeen.present) {
      map['last_seen'] = Variable<int>(lastSeen.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LanPairingMetadataCompanion(')
          ..write('deviceId: $deviceId, ')
          ..write('alias: $alias, ')
          ..write('deviceType: $deviceType, ')
          ..write('ip: $ip, ')
          ..write('port: $port, ')
          ..write('lastSeen: $lastSeen, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$LanShareDatabase extends GeneratedDatabase {
  _$LanShareDatabase(QueryExecutor e) : super(e);
  $LanShareDatabaseManager get managers => $LanShareDatabaseManager(this);
  late final $LanTransferRecordsTable lanTransferRecords =
      $LanTransferRecordsTable(this);
  late final $LanPairingMetadataTable lanPairingMetadata =
      $LanPairingMetadataTable(this);
  late final LanHistoryDao lanHistoryDao = LanHistoryDao(
    this as LanShareDatabase,
  );
  late final LanPairingMetadataDao lanPairingMetadataDao =
      LanPairingMetadataDao(this as LanShareDatabase);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    lanTransferRecords,
    lanPairingMetadata,
  ];
}

typedef $$LanTransferRecordsTableCreateCompanionBuilder =
    LanTransferRecordsCompanion Function({
      required String id,
      required String senderId,
      required String senderAlias,
      required String receiverId,
      required String payloadType,
      Value<String?> textContent,
      Value<String?> fileName,
      Value<int> fileSize,
      Value<String?> localPath,
      Value<String?> manifestJson,
      required String status,
      Value<int> bytesTransferred,
      required int createdAt,
      Value<bool> isIncoming,
      Value<bool> isRecalled,
      Value<String?> sftpServerId,
      Value<String?> sftpRemotePath,
      Value<String?> transport,
      Value<String?> routeType,
      Value<int?> avgRtt,
      Value<int?> bytesTotal,
      Value<String?> failureReason,
      Value<int> rowid,
    });
typedef $$LanTransferRecordsTableUpdateCompanionBuilder =
    LanTransferRecordsCompanion Function({
      Value<String> id,
      Value<String> senderId,
      Value<String> senderAlias,
      Value<String> receiverId,
      Value<String> payloadType,
      Value<String?> textContent,
      Value<String?> fileName,
      Value<int> fileSize,
      Value<String?> localPath,
      Value<String?> manifestJson,
      Value<String> status,
      Value<int> bytesTransferred,
      Value<int> createdAt,
      Value<bool> isIncoming,
      Value<bool> isRecalled,
      Value<String?> sftpServerId,
      Value<String?> sftpRemotePath,
      Value<String?> transport,
      Value<String?> routeType,
      Value<int?> avgRtt,
      Value<int?> bytesTotal,
      Value<String?> failureReason,
      Value<int> rowid,
    });

class $$LanTransferRecordsTableFilterComposer
    extends Composer<_$LanShareDatabase, $LanTransferRecordsTable> {
  $$LanTransferRecordsTableFilterComposer({
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

  ColumnFilters<String> get senderId => $composableBuilder(
    column: $table.senderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderAlias => $composableBuilder(
    column: $table.senderAlias,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get receiverId => $composableBuilder(
    column: $table.receiverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadType => $composableBuilder(
    column: $table.payloadType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get textContent => $composableBuilder(
    column: $table.textContent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get fileSize => $composableBuilder(
    column: $table.fileSize,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get manifestJson => $composableBuilder(
    column: $table.manifestJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bytesTransferred => $composableBuilder(
    column: $table.bytesTransferred,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isIncoming => $composableBuilder(
    column: $table.isIncoming,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isRecalled => $composableBuilder(
    column: $table.isRecalled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sftpServerId => $composableBuilder(
    column: $table.sftpServerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sftpRemotePath => $composableBuilder(
    column: $table.sftpRemotePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get transport => $composableBuilder(
    column: $table.transport,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get routeType => $composableBuilder(
    column: $table.routeType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get avgRtt => $composableBuilder(
    column: $table.avgRtt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bytesTotal => $composableBuilder(
    column: $table.bytesTotal,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get failureReason => $composableBuilder(
    column: $table.failureReason,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LanTransferRecordsTableOrderingComposer
    extends Composer<_$LanShareDatabase, $LanTransferRecordsTable> {
  $$LanTransferRecordsTableOrderingComposer({
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

  ColumnOrderings<String> get senderId => $composableBuilder(
    column: $table.senderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderAlias => $composableBuilder(
    column: $table.senderAlias,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get receiverId => $composableBuilder(
    column: $table.receiverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadType => $composableBuilder(
    column: $table.payloadType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get textContent => $composableBuilder(
    column: $table.textContent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get fileSize => $composableBuilder(
    column: $table.fileSize,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get manifestJson => $composableBuilder(
    column: $table.manifestJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bytesTransferred => $composableBuilder(
    column: $table.bytesTransferred,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isIncoming => $composableBuilder(
    column: $table.isIncoming,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isRecalled => $composableBuilder(
    column: $table.isRecalled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sftpServerId => $composableBuilder(
    column: $table.sftpServerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sftpRemotePath => $composableBuilder(
    column: $table.sftpRemotePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get transport => $composableBuilder(
    column: $table.transport,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get routeType => $composableBuilder(
    column: $table.routeType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get avgRtt => $composableBuilder(
    column: $table.avgRtt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bytesTotal => $composableBuilder(
    column: $table.bytesTotal,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get failureReason => $composableBuilder(
    column: $table.failureReason,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LanTransferRecordsTableAnnotationComposer
    extends Composer<_$LanShareDatabase, $LanTransferRecordsTable> {
  $$LanTransferRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get senderId =>
      $composableBuilder(column: $table.senderId, builder: (column) => column);

  GeneratedColumn<String> get senderAlias => $composableBuilder(
    column: $table.senderAlias,
    builder: (column) => column,
  );

  GeneratedColumn<String> get receiverId => $composableBuilder(
    column: $table.receiverId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get payloadType => $composableBuilder(
    column: $table.payloadType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get textContent => $composableBuilder(
    column: $table.textContent,
    builder: (column) => column,
  );

  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<int> get fileSize =>
      $composableBuilder(column: $table.fileSize, builder: (column) => column);

  GeneratedColumn<String> get localPath =>
      $composableBuilder(column: $table.localPath, builder: (column) => column);

  GeneratedColumn<String> get manifestJson => $composableBuilder(
    column: $table.manifestJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get bytesTransferred => $composableBuilder(
    column: $table.bytesTransferred,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<bool> get isIncoming => $composableBuilder(
    column: $table.isIncoming,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isRecalled => $composableBuilder(
    column: $table.isRecalled,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sftpServerId => $composableBuilder(
    column: $table.sftpServerId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sftpRemotePath => $composableBuilder(
    column: $table.sftpRemotePath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get transport =>
      $composableBuilder(column: $table.transport, builder: (column) => column);

  GeneratedColumn<String> get routeType =>
      $composableBuilder(column: $table.routeType, builder: (column) => column);

  GeneratedColumn<int> get avgRtt =>
      $composableBuilder(column: $table.avgRtt, builder: (column) => column);

  GeneratedColumn<int> get bytesTotal => $composableBuilder(
    column: $table.bytesTotal,
    builder: (column) => column,
  );

  GeneratedColumn<String> get failureReason => $composableBuilder(
    column: $table.failureReason,
    builder: (column) => column,
  );
}

class $$LanTransferRecordsTableTableManager
    extends
        RootTableManager<
          _$LanShareDatabase,
          $LanTransferRecordsTable,
          LanTransferRecord,
          $$LanTransferRecordsTableFilterComposer,
          $$LanTransferRecordsTableOrderingComposer,
          $$LanTransferRecordsTableAnnotationComposer,
          $$LanTransferRecordsTableCreateCompanionBuilder,
          $$LanTransferRecordsTableUpdateCompanionBuilder,
          (
            LanTransferRecord,
            BaseReferences<
              _$LanShareDatabase,
              $LanTransferRecordsTable,
              LanTransferRecord
            >,
          ),
          LanTransferRecord,
          PrefetchHooks Function()
        > {
  $$LanTransferRecordsTableTableManager(
    _$LanShareDatabase db,
    $LanTransferRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LanTransferRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LanTransferRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LanTransferRecordsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> senderId = const Value.absent(),
                Value<String> senderAlias = const Value.absent(),
                Value<String> receiverId = const Value.absent(),
                Value<String> payloadType = const Value.absent(),
                Value<String?> textContent = const Value.absent(),
                Value<String?> fileName = const Value.absent(),
                Value<int> fileSize = const Value.absent(),
                Value<String?> localPath = const Value.absent(),
                Value<String?> manifestJson = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> bytesTransferred = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<bool> isIncoming = const Value.absent(),
                Value<bool> isRecalled = const Value.absent(),
                Value<String?> sftpServerId = const Value.absent(),
                Value<String?> sftpRemotePath = const Value.absent(),
                Value<String?> transport = const Value.absent(),
                Value<String?> routeType = const Value.absent(),
                Value<int?> avgRtt = const Value.absent(),
                Value<int?> bytesTotal = const Value.absent(),
                Value<String?> failureReason = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LanTransferRecordsCompanion(
                id: id,
                senderId: senderId,
                senderAlias: senderAlias,
                receiverId: receiverId,
                payloadType: payloadType,
                textContent: textContent,
                fileName: fileName,
                fileSize: fileSize,
                localPath: localPath,
                manifestJson: manifestJson,
                status: status,
                bytesTransferred: bytesTransferred,
                createdAt: createdAt,
                isIncoming: isIncoming,
                isRecalled: isRecalled,
                sftpServerId: sftpServerId,
                sftpRemotePath: sftpRemotePath,
                transport: transport,
                routeType: routeType,
                avgRtt: avgRtt,
                bytesTotal: bytesTotal,
                failureReason: failureReason,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String senderId,
                required String senderAlias,
                required String receiverId,
                required String payloadType,
                Value<String?> textContent = const Value.absent(),
                Value<String?> fileName = const Value.absent(),
                Value<int> fileSize = const Value.absent(),
                Value<String?> localPath = const Value.absent(),
                Value<String?> manifestJson = const Value.absent(),
                required String status,
                Value<int> bytesTransferred = const Value.absent(),
                required int createdAt,
                Value<bool> isIncoming = const Value.absent(),
                Value<bool> isRecalled = const Value.absent(),
                Value<String?> sftpServerId = const Value.absent(),
                Value<String?> sftpRemotePath = const Value.absent(),
                Value<String?> transport = const Value.absent(),
                Value<String?> routeType = const Value.absent(),
                Value<int?> avgRtt = const Value.absent(),
                Value<int?> bytesTotal = const Value.absent(),
                Value<String?> failureReason = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LanTransferRecordsCompanion.insert(
                id: id,
                senderId: senderId,
                senderAlias: senderAlias,
                receiverId: receiverId,
                payloadType: payloadType,
                textContent: textContent,
                fileName: fileName,
                fileSize: fileSize,
                localPath: localPath,
                manifestJson: manifestJson,
                status: status,
                bytesTransferred: bytesTransferred,
                createdAt: createdAt,
                isIncoming: isIncoming,
                isRecalled: isRecalled,
                sftpServerId: sftpServerId,
                sftpRemotePath: sftpRemotePath,
                transport: transport,
                routeType: routeType,
                avgRtt: avgRtt,
                bytesTotal: bytesTotal,
                failureReason: failureReason,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LanTransferRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$LanShareDatabase,
      $LanTransferRecordsTable,
      LanTransferRecord,
      $$LanTransferRecordsTableFilterComposer,
      $$LanTransferRecordsTableOrderingComposer,
      $$LanTransferRecordsTableAnnotationComposer,
      $$LanTransferRecordsTableCreateCompanionBuilder,
      $$LanTransferRecordsTableUpdateCompanionBuilder,
      (
        LanTransferRecord,
        BaseReferences<
          _$LanShareDatabase,
          $LanTransferRecordsTable,
          LanTransferRecord
        >,
      ),
      LanTransferRecord,
      PrefetchHooks Function()
    >;
typedef $$LanPairingMetadataTableCreateCompanionBuilder =
    LanPairingMetadataCompanion Function({
      required String deviceId,
      required String alias,
      Value<String> deviceType,
      Value<String?> ip,
      Value<int?> port,
      required int lastSeen,
      Value<int> rowid,
    });
typedef $$LanPairingMetadataTableUpdateCompanionBuilder =
    LanPairingMetadataCompanion Function({
      Value<String> deviceId,
      Value<String> alias,
      Value<String> deviceType,
      Value<String?> ip,
      Value<int?> port,
      Value<int> lastSeen,
      Value<int> rowid,
    });

class $$LanPairingMetadataTableFilterComposer
    extends Composer<_$LanShareDatabase, $LanPairingMetadataTable> {
  $$LanPairingMetadataTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get alias => $composableBuilder(
    column: $table.alias,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceType => $composableBuilder(
    column: $table.deviceType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ip => $composableBuilder(
    column: $table.ip,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastSeen => $composableBuilder(
    column: $table.lastSeen,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LanPairingMetadataTableOrderingComposer
    extends Composer<_$LanShareDatabase, $LanPairingMetadataTable> {
  $$LanPairingMetadataTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get alias => $composableBuilder(
    column: $table.alias,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceType => $composableBuilder(
    column: $table.deviceType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ip => $composableBuilder(
    column: $table.ip,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastSeen => $composableBuilder(
    column: $table.lastSeen,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LanPairingMetadataTableAnnotationComposer
    extends Composer<_$LanShareDatabase, $LanPairingMetadataTable> {
  $$LanPairingMetadataTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<String> get alias =>
      $composableBuilder(column: $table.alias, builder: (column) => column);

  GeneratedColumn<String> get deviceType => $composableBuilder(
    column: $table.deviceType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get ip =>
      $composableBuilder(column: $table.ip, builder: (column) => column);

  GeneratedColumn<int> get port =>
      $composableBuilder(column: $table.port, builder: (column) => column);

  GeneratedColumn<int> get lastSeen =>
      $composableBuilder(column: $table.lastSeen, builder: (column) => column);
}

class $$LanPairingMetadataTableTableManager
    extends
        RootTableManager<
          _$LanShareDatabase,
          $LanPairingMetadataTable,
          LanPairingMetadataData,
          $$LanPairingMetadataTableFilterComposer,
          $$LanPairingMetadataTableOrderingComposer,
          $$LanPairingMetadataTableAnnotationComposer,
          $$LanPairingMetadataTableCreateCompanionBuilder,
          $$LanPairingMetadataTableUpdateCompanionBuilder,
          (
            LanPairingMetadataData,
            BaseReferences<
              _$LanShareDatabase,
              $LanPairingMetadataTable,
              LanPairingMetadataData
            >,
          ),
          LanPairingMetadataData,
          PrefetchHooks Function()
        > {
  $$LanPairingMetadataTableTableManager(
    _$LanShareDatabase db,
    $LanPairingMetadataTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LanPairingMetadataTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LanPairingMetadataTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LanPairingMetadataTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> deviceId = const Value.absent(),
                Value<String> alias = const Value.absent(),
                Value<String> deviceType = const Value.absent(),
                Value<String?> ip = const Value.absent(),
                Value<int?> port = const Value.absent(),
                Value<int> lastSeen = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LanPairingMetadataCompanion(
                deviceId: deviceId,
                alias: alias,
                deviceType: deviceType,
                ip: ip,
                port: port,
                lastSeen: lastSeen,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String deviceId,
                required String alias,
                Value<String> deviceType = const Value.absent(),
                Value<String?> ip = const Value.absent(),
                Value<int?> port = const Value.absent(),
                required int lastSeen,
                Value<int> rowid = const Value.absent(),
              }) => LanPairingMetadataCompanion.insert(
                deviceId: deviceId,
                alias: alias,
                deviceType: deviceType,
                ip: ip,
                port: port,
                lastSeen: lastSeen,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LanPairingMetadataTableProcessedTableManager =
    ProcessedTableManager<
      _$LanShareDatabase,
      $LanPairingMetadataTable,
      LanPairingMetadataData,
      $$LanPairingMetadataTableFilterComposer,
      $$LanPairingMetadataTableOrderingComposer,
      $$LanPairingMetadataTableAnnotationComposer,
      $$LanPairingMetadataTableCreateCompanionBuilder,
      $$LanPairingMetadataTableUpdateCompanionBuilder,
      (
        LanPairingMetadataData,
        BaseReferences<
          _$LanShareDatabase,
          $LanPairingMetadataTable,
          LanPairingMetadataData
        >,
      ),
      LanPairingMetadataData,
      PrefetchHooks Function()
    >;

class $LanShareDatabaseManager {
  final _$LanShareDatabase _db;
  $LanShareDatabaseManager(this._db);
  $$LanTransferRecordsTableTableManager get lanTransferRecords =>
      $$LanTransferRecordsTableTableManager(_db, _db.lanTransferRecords);
  $$LanPairingMetadataTableTableManager get lanPairingMetadata =>
      $$LanPairingMetadataTableTableManager(_db, _db.lanPairingMetadata);
}

mixin _$LanHistoryDaoMixin on DatabaseAccessor<LanShareDatabase> {
  $LanTransferRecordsTable get lanTransferRecords =>
      attachedDatabase.lanTransferRecords;
  LanHistoryDaoManager get managers => LanHistoryDaoManager(this);
}

class LanHistoryDaoManager {
  final _$LanHistoryDaoMixin _db;
  LanHistoryDaoManager(this._db);
  $$LanTransferRecordsTableTableManager get lanTransferRecords =>
      $$LanTransferRecordsTableTableManager(
        _db.attachedDatabase,
        _db.lanTransferRecords,
      );
}

mixin _$LanPairingMetadataDaoMixin on DatabaseAccessor<LanShareDatabase> {
  $LanPairingMetadataTable get lanPairingMetadata =>
      attachedDatabase.lanPairingMetadata;
  LanPairingMetadataDaoManager get managers =>
      LanPairingMetadataDaoManager(this);
}

class LanPairingMetadataDaoManager {
  final _$LanPairingMetadataDaoMixin _db;
  LanPairingMetadataDaoManager(this._db);
  $$LanPairingMetadataTableTableManager get lanPairingMetadata =>
      $$LanPairingMetadataTableTableManager(
        _db.attachedDatabase,
        _db.lanPairingMetadata,
      );
}
