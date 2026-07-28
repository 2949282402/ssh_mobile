import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';
import 'package:uuid/uuid.dart';

enum TransportKind { quicDirect, relayFallback }

class TransferSession {
  const TransferSession({
    required this.transferId,
    required this.peerId,
    required this.filePath,
    required this.transport,
  });

  final String transferId;
  final String peerId;
  final String filePath;
  final TransportKind transport;
}

class TransferEvent {
  const TransferEvent({
    required this.transferId,
    required this.bytesTransferred,
    required this.totalBytes,
    this.error,
    this.completed = false,
    this.localPath,
    this.transport,
  });

  final String transferId;
  final int bytesTransferred;
  final int totalBytes;
  final String? error;
  final bool completed;
  final String? localPath;
  final TransportKind? transport;
}

class NativeIncomingTransferOffer {
  const NativeIncomingTransferOffer({
    required this.transferId,
    required this.peerId,
    required this.fileName,
    required this.fileSize,
  });

  final String transferId;
  final String peerId;
  final String fileName;
  final int fileSize;
}

abstract interface class TransferTransport {
  Future<TransferSession> send({
    required String transferId,
    required String peerId,
    required String filePath,
  });

  Future<void> cancel(String transferId);

  Stream<TransferEvent> get events;
}

abstract interface class PeerConfigurableTransferTransport
    implements TransferTransport {
  Future<void> registerAndConnectPeer({
    required String peerId,
    required String endpointAddress,
    required Uint8List identityPublicKey,
    required Uint8List e2ePublicKey,
  });
}

class QuicTransferTransport implements PeerConfigurableTransferTransport {
  QuicTransferTransport(this._runtime)
    : _nativeSubscription = _runtime.rawEvents.listen(null) {
    _nativeSubscription.onData(_handleNativeEvent);
  }

  static const _protocolVersion = 1;
  final NativeNetworkRuntime _runtime;
  final StreamController<TransferEvent> _eventController =
      StreamController<TransferEvent>.broadcast();
  final StreamController<NativeIncomingTransferOffer> _incomingOfferController =
      StreamController<NativeIncomingTransferOffer>.broadcast();
  final Map<String, String> _commandTransfers = <String, String>{};
  final Map<String, Completer<void>> _pendingCommands =
      <String, Completer<void>>{};
  final Map<String, Completer<void>> _pendingTransfers =
      <String, Completer<void>>{};
  final Map<String, String> _peerRoutes = <String, String>{};
  final Map<String, String> _transferPeers = <String, String>{};
  final StreamSubscription<Uint8List> _nativeSubscription;

  @override
  Stream<TransferEvent> get events => _eventController.stream;
  Stream<NativeIncomingTransferOffer> get incomingOffers =>
      _incomingOfferController.stream;

  Future<void> configure({
    required String deviceId,
    required Uint8List identityPrivateKey,
    required Uint8List e2ePrivateKey,
    required String listenAddress,
    required String receiveDirectory,
  }) => _sendAndWait(
    _NetworkProto.configureRuntimeCommand(
      commandId: const Uuid().v4(),
      deviceId: deviceId,
      identityPrivateKey: identityPrivateKey,
      e2ePrivateKey: e2ePrivateKey,
      listenAddress: listenAddress,
      receiveDirectory: receiveDirectory,
    ),
    timeout: const Duration(seconds: 15),
  );

  @override
  Future<void> registerAndConnectPeer({
    required String peerId,
    required String endpointAddress,
    required Uint8List identityPublicKey,
    required Uint8List e2ePublicKey,
  }) async {
    await registerPeer(
      peerId: peerId,
      endpointAddress: endpointAddress,
      identityPublicKey: identityPublicKey,
      e2ePublicKey: e2ePublicKey,
    );
    await connectPeer(peerId);
  }

  Future<void> registerPeer({
    required String peerId,
    required String endpointAddress,
    required Uint8List identityPublicKey,
    required Uint8List e2ePublicKey,
  }) => _sendAndWait(
    _NetworkProto.upsertPeerCommand(
      commandId: const Uuid().v4(),
      peerId: peerId,
      endpointAddress: endpointAddress,
      identityPublicKey: identityPublicKey,
      e2ePublicKey: e2ePublicKey,
    ),
  );

  Future<void> connectPeer(String peerId) => _sendAndWait(
    _NetworkProto.connectPeerCommand(
      commandId: const Uuid().v4(),
      peerId: peerId,
    ),
    timeout: const Duration(seconds: 12),
  );

  Future<void> respondToIncoming({
    required String transferId,
    required bool accept,
  }) => _sendAndWait(
    _NetworkProto.respondIncomingTransferCommand(
      commandId: const Uuid().v4(),
      transferId: transferId,
      accept: accept,
    ),
  );

  Future<void> configureRelay({
    required String relayUrl,
    required String relayCredential,
    required Uint8List relaySigningSeed,
  }) => _sendAndWait(
    _NetworkProto.configureRelayCommand(
      commandId: const Uuid().v4(),
      relayUrl: relayUrl,
      relayCredential: relayCredential,
      relaySigningSeed: relaySigningSeed,
    ),
    timeout: const Duration(seconds: 15),
  );

  @override
  Future<TransferSession> send({
    required String transferId,
    required String peerId,
    required String filePath,
  }) async {
    if (peerId.trim().isEmpty) {
      throw ArgumentError.value(peerId, 'peerId', 'must not be empty');
    }
    final file = File(filePath);
    if (!await file.exists()) {
      throw ArgumentError.value(filePath, 'filePath', 'file does not exist');
    }

    final commandId = const Uuid().v4();
    final command = _NetworkProto.sendFileCommand(
      commandId: commandId,
      transferId: transferId,
      peerId: peerId,
      filePath: file.absolute.path,
    );
    _commandTransfers[commandId] = transferId;
    final accepted = Completer<void>();
    final completed = Completer<void>();
    _pendingCommands[commandId] = accepted;
    _pendingTransfers[transferId] = completed;
    _transferPeers[transferId] = peerId;
    final result = _runtime.sendCommand(command);
    if (result != 0) {
      _pendingCommands.remove(commandId);
      _commandTransfers.remove(commandId);
      _pendingTransfers.remove(transferId);
      _transferPeers.remove(transferId);
      throw StateError('Native send command failed ($result).');
    }
    try {
      await accepted.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _commandTransfers.remove(commandId);
      _pendingTransfers.remove(transferId);
      _transferPeers.remove(transferId);
      rethrow;
    } finally {
      _pendingCommands.remove(commandId);
    }
    try {
      await completed.future;
    } finally {
      _pendingTransfers.remove(transferId);
      _commandTransfers.remove(commandId);
      _transferPeers.remove(transferId);
    }
    return TransferSession(
      transferId: transferId,
      peerId: peerId,
      filePath: file.absolute.path,
      transport: _peerRoutes[peerId] == 'relay'
          ? TransportKind.relayFallback
          : TransportKind.quicDirect,
    );
  }

  @override
  Future<void> cancel(String transferId) async {
    if (transferId.isEmpty) {
      throw ArgumentError.value(transferId, 'transferId', 'must not be empty');
    }
    final commandId = const Uuid().v4();
    _commandTransfers[commandId] = transferId;
    final accepted = Completer<void>();
    _pendingCommands[commandId] = accepted;
    final result = _runtime.sendCommand(
      _NetworkProto.cancelTransferCommand(
        commandId: commandId,
        transferId: transferId,
      ),
    );
    if (result != 0) {
      _pendingCommands.remove(commandId);
      _commandTransfers.remove(commandId);
      throw StateError('Native cancel command failed ($result).');
    }
    try {
      await accepted.future.timeout(const Duration(seconds: 3));
      _commandTransfers.remove(commandId);
    } on TimeoutException {
      _commandTransfers.remove(commandId);
      rethrow;
    } finally {
      _pendingCommands.remove(commandId);
    }
  }

  void _handleNativeEvent(Uint8List bytes) {
    try {
      final event = _NetworkProto.decodeEvent(bytes);
      if (event.protocolVersion != _protocolVersion) {
        throw const FormatException('Unsupported native event version.');
      }
      if (event.commandId != null) {
        final pending = _pendingCommands[event.commandId!];
        if (pending != null && !pending.isCompleted) {
          if (event.commandAccepted) {
            pending.complete();
          } else {
            final transferId = _commandTransfers.remove(event.commandId);
            if (transferId != null) {
              _pendingTransfers.remove(transferId);
              _transferPeers.remove(transferId);
            }
            pending.completeError(
              StateError(event.error ?? 'Native command was rejected.'),
            );
          }
        }
        return;
      }
      if (event.peerId != null) {
        if (event.peerState == 'connected') {
          _peerRoutes[event.peerId!] = event.activeRoute ?? '';
        } else {
          _peerRoutes.remove(event.peerId);
        }
        return;
      }
      if (event.transferId != null) {
        final incomingOffer = event.incomingOffer;
        if (incomingOffer != null) {
          _transferPeers[incomingOffer.transferId] = incomingOffer.peerId;
          _incomingOfferController.add(incomingOffer);
          return;
        }
        final peerId = _transferPeers[event.transferId!];
        final transport = _transportForPeer(peerId);
        _eventController.add(
          TransferEvent(
            transferId: event.transferId!,
            bytesTransferred: event.bytesTransferred,
            totalBytes: event.totalBytes,
            completed: event.transferCompleted,
            localPath: event.localPath,
            transport: transport,
          ),
        );
        if (event.transferCompleted) {
          final pending = _pendingTransfers[event.transferId!];
          if (pending != null && !pending.isCompleted) pending.complete();
          _transferPeers.remove(event.transferId);
        }
        return;
      }
      final eventError = event.error;
      if (eventError != null) {
        final transferId = event.eventId.endsWith('/error')
            ? event.eventId.substring(0, event.eventId.length - 6)
            : '';
        final pending = _pendingTransfers.remove(transferId);
        final peerId = _transferPeers.remove(transferId);
        if (pending != null && !pending.isCompleted) {
          pending.completeError(StateError(eventError));
        }
        _eventController.add(
          TransferEvent(
            transferId: transferId,
            bytesTransferred: 0,
            totalBytes: 0,
            error: eventError,
            transport: _transportForPeer(peerId),
          ),
        );
      }
    } on FormatException catch (error) {
      _eventController.add(
        TransferEvent(
          transferId: '',
          bytesTransferred: 0,
          totalBytes: 0,
          error: error.message,
        ),
      );
    }
  }

  Future<void> dispose() async {
    await _nativeSubscription.cancel();
    for (final pending in _pendingCommands.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('QUIC transport was disposed.'));
      }
    }
    _pendingCommands.clear();
    for (final pending in _pendingTransfers.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('QUIC transport was disposed.'));
      }
    }
    _pendingTransfers.clear();
    _commandTransfers.clear();
    _peerRoutes.clear();
    _transferPeers.clear();
    await _eventController.close();
    await _incomingOfferController.close();
  }

  Future<void> _sendAndWait(
    Uint8List command, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final commandId = _NetworkProto.commandId(command);
    final accepted = Completer<void>();
    _pendingCommands[commandId] = accepted;
    final result = _runtime.sendCommand(command);
    if (result != 0) {
      _pendingCommands.remove(commandId);
      throw StateError('Native network command failed ($result).');
    }
    try {
      await accepted.future.timeout(timeout);
    } finally {
      _pendingCommands.remove(commandId);
    }
  }

  TransportKind _transportForPeer(String? peerId) =>
      peerId != null && _peerRoutes[peerId] == 'relay'
      ? TransportKind.relayFallback
      : TransportKind.quicDirect;
}

class AdaptiveTransferTransport implements PeerConfigurableTransferTransport {
  AdaptiveTransferTransport({required this.direct}) {
    _directSubscription = direct.events.listen(_events.add);
  }

  final QuicTransferTransport direct;
  final StreamController<TransferEvent> _events =
      StreamController<TransferEvent>.broadcast();
  late final StreamSubscription<TransferEvent> _directSubscription;
  bool _nativeRelayConfigured = false;

  @override
  Stream<TransferEvent> get events => _events.stream;
  Stream<NativeIncomingTransferOffer> get incomingOffers =>
      direct.incomingOffers;

  Future<void> respondToIncoming({
    required String transferId,
    required bool accept,
  }) => direct.respondToIncoming(transferId: transferId, accept: accept);

  bool get nativeRelayConfigured => _nativeRelayConfigured;

  Future<void> configureRelay({
    required String relayUrl,
    required String relayCredential,
    required Uint8List relaySigningSeed,
  }) async {
    await direct.configureRelay(
      relayUrl: relayUrl,
      relayCredential: relayCredential,
      relaySigningSeed: relaySigningSeed,
    );
    _nativeRelayConfigured = true;
  }

  @override
  Future<void> registerAndConnectPeer({
    required String peerId,
    required String endpointAddress,
    required Uint8List identityPublicKey,
    required Uint8List e2ePublicKey,
  }) => direct.registerAndConnectPeer(
    peerId: peerId,
    endpointAddress: endpointAddress,
    identityPublicKey: identityPublicKey,
    e2ePublicKey: e2ePublicKey,
  );

  @override
  Future<TransferSession> send({
    required String transferId,
    required String peerId,
    required String filePath,
  }) => direct.send(transferId: transferId, peerId: peerId, filePath: filePath);

  @override
  Future<void> cancel(String transferId) => direct.cancel(transferId);

  Future<void> dispose() async {
    await _directSubscription.cancel();
    await direct.dispose();
    await _events.close();
  }
}

class _DecodedNetworkEvent {
  const _DecodedNetworkEvent({
    required this.eventId,
    required this.protocolVersion,
    this.transferId,
    this.bytesTransferred = 0,
    this.totalBytes = 0,
    this.error,
    this.commandId,
    this.commandAccepted = false,
    this.transferCompleted = false,
    this.localPath,
    this.incomingOffer,
    this.peerId,
    this.peerState,
    this.activeRoute,
  });

  final String eventId;
  final int protocolVersion;
  final String? transferId;
  final int bytesTransferred;
  final int totalBytes;
  final String? error;
  final String? commandId;
  final bool commandAccepted;
  final bool transferCompleted;
  final String? localPath;
  final NativeIncomingTransferOffer? incomingOffer;
  final String? peerId;
  final String? peerState;
  final String? activeRoute;
}

class _NetworkProto {
  static Uint8List configureRuntimeCommand({
    required String commandId,
    required String deviceId,
    required Uint8List identityPrivateKey,
    required Uint8List e2ePrivateKey,
    required String listenAddress,
    required String receiveDirectory,
  }) {
    final payload = _ProtoWriter()
      ..string(1, deviceId)
      ..bytesField(2, identityPrivateKey)
      ..bytesField(3, e2ePrivateKey)
      ..string(4, listenAddress)
      ..string(5, receiveDirectory);
    return _command(commandId, 13, payload.takeBytes());
  }

  static Uint8List upsertPeerCommand({
    required String commandId,
    required String peerId,
    required String endpointAddress,
    required Uint8List identityPublicKey,
    required Uint8List e2ePublicKey,
  }) {
    final payload = _ProtoWriter()
      ..string(1, peerId)
      ..string(2, endpointAddress)
      ..bytesField(3, identityPublicKey)
      ..bytesField(4, e2ePublicKey);
    return _command(commandId, 14, payload.takeBytes());
  }

  static Uint8List connectPeerCommand({
    required String commandId,
    required String peerId,
  }) {
    final payload = _ProtoWriter()
      ..string(1, peerId)
      ..varint(2, 0);
    return _command(commandId, 10, payload.takeBytes());
  }

  static Uint8List respondIncomingTransferCommand({
    required String commandId,
    required String transferId,
    required bool accept,
  }) {
    final payload = _ProtoWriter()
      ..string(1, transferId)
      ..varint(2, accept ? 1 : 0);
    return _command(commandId, 15, payload.takeBytes());
  }

  static Uint8List configureRelayCommand({
    required String commandId,
    required String relayUrl,
    required String relayCredential,
    required Uint8List relaySigningSeed,
  }) {
    final payload = _ProtoWriter()
      ..string(1, relayUrl)
      ..string(2, relayCredential)
      ..bytesField(3, relaySigningSeed);
    return _command(commandId, 16, payload.takeBytes());
  }

  static Uint8List _command(String commandId, int field, Uint8List payload) =>
      (_ProtoWriter()
            ..string(1, commandId)
            ..varint(2, QuicTransferTransport._protocolVersion)
            ..message(field, payload))
          .takeBytes();

  static String commandId(Uint8List command) {
    final reader = _ProtoReader(command);
    while (!reader.isDone) {
      final field = reader.field();
      if (field.number == 1) {
        return utf8.decode(reader.bytes(field.wireType));
      }
      reader.skip(field.wireType);
    }
    throw const FormatException('Native command has no command ID.');
  }

  static Uint8List sendFileCommand({
    required String commandId,
    required String transferId,
    required String peerId,
    required String filePath,
  }) {
    final payload = _ProtoWriter()
      ..string(1, transferId)
      ..string(2, peerId)
      ..string(3, filePath);
    return (_ProtoWriter()
          ..string(1, commandId)
          ..varint(2, QuicTransferTransport._protocolVersion)
          ..message(11, payload.takeBytes()))
        .takeBytes();
  }

  static Uint8List cancelTransferCommand({
    required String commandId,
    required String transferId,
  }) {
    final payload = _ProtoWriter()..string(1, transferId);
    return (_ProtoWriter()
          ..string(1, commandId)
          ..varint(2, QuicTransferTransport._protocolVersion)
          ..message(12, payload.takeBytes()))
        .takeBytes();
  }

  static _DecodedNetworkEvent decodeEvent(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    var eventId = '';
    var protocolVersion = 0;
    String? transferId;
    var bytesTransferred = 0;
    var totalBytes = 0;
    String? error;
    String? commandId;
    var commandAccepted = false;
    var transferCompleted = false;
    String? localPath;
    NativeIncomingTransferOffer? incomingOffer;
    String? peerId;
    String? peerState;
    String? activeRoute;

    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          eventId = utf8.decode(reader.bytes(field.wireType));
        case 3:
          protocolVersion = reader.varint(field.wireType);
        case 10:
          final peer = _ProtoReader(reader.bytes(field.wireType));
          while (!peer.isDone) {
            final nested = peer.field();
            switch (nested.number) {
              case 1:
                peerId = utf8.decode(peer.bytes(nested.wireType));
              case 2:
                peerState = utf8.decode(peer.bytes(nested.wireType));
              case 3:
                activeRoute = utf8.decode(peer.bytes(nested.wireType));
              default:
                peer.skip(nested.wireType);
            }
          }
        case 11:
          final progress = _ProtoReader(reader.bytes(field.wireType));
          while (!progress.isDone) {
            final nested = progress.field();
            switch (nested.number) {
              case 1:
                transferId = utf8.decode(progress.bytes(nested.wireType));
              case 2:
                bytesTransferred = progress.varint(nested.wireType);
              case 3:
                totalBytes = progress.varint(nested.wireType);
              default:
                progress.skip(nested.wireType);
            }
          }
        case 12:
          error = _decodeNetworkError(reader.bytes(field.wireType));
        case 13:
          final result = _ProtoReader(reader.bytes(field.wireType));
          while (!result.isDone) {
            final nested = result.field();
            switch (nested.number) {
              case 1:
                commandId = utf8.decode(result.bytes(nested.wireType));
              case 2:
                commandAccepted = result.varint(nested.wireType) != 0;
              case 3:
                error = _decodeNetworkError(result.bytes(nested.wireType));
              default:
                result.skip(nested.wireType);
            }
          }
        case 15:
          final completed = _ProtoReader(reader.bytes(field.wireType));
          while (!completed.isDone) {
            final nested = completed.field();
            if (nested.number == 1) {
              transferId = utf8.decode(completed.bytes(nested.wireType));
              transferCompleted = true;
            } else if (nested.number == 2) {
              localPath = utf8.decode(completed.bytes(nested.wireType));
            } else {
              completed.skip(nested.wireType);
            }
          }
        case 14:
          final offer = _ProtoReader(reader.bytes(field.wireType));
          var offeredTransferId = '';
          var peerId = '';
          var fileName = '';
          var fileSize = 0;
          while (!offer.isDone) {
            final nested = offer.field();
            switch (nested.number) {
              case 1:
                offeredTransferId = utf8.decode(offer.bytes(nested.wireType));
              case 2:
                peerId = utf8.decode(offer.bytes(nested.wireType));
              case 3:
                fileName = utf8.decode(offer.bytes(nested.wireType));
              case 4:
                fileSize = offer.varint(nested.wireType);
              default:
                offer.skip(nested.wireType);
            }
          }
          transferId = offeredTransferId;
          incomingOffer = NativeIncomingTransferOffer(
            transferId: offeredTransferId,
            peerId: peerId,
            fileName: fileName,
            fileSize: fileSize,
          );
        default:
          reader.skip(field.wireType);
      }
    }
    return _DecodedNetworkEvent(
      eventId: eventId,
      protocolVersion: protocolVersion,
      transferId: transferId,
      bytesTransferred: bytesTransferred,
      totalBytes: totalBytes,
      error: error,
      commandId: commandId,
      commandAccepted: commandAccepted,
      transferCompleted: transferCompleted,
      localPath: localPath,
      incomingOffer: incomingOffer,
      peerId: peerId,
      peerState: peerState,
      activeRoute: activeRoute,
    );
  }

  static String? _decodeNetworkError(Uint8List bytes) {
    final failure = _ProtoReader(bytes);
    String? message;
    while (!failure.isDone) {
      final field = failure.field();
      if (field.number == 2) {
        message = utf8.decode(failure.bytes(field.wireType));
      } else {
        failure.skip(field.wireType);
      }
    }
    return message;
  }
}

class _ProtoWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void varint(int fieldNumber, int value) {
    _writeVarint((fieldNumber << 3) | 0);
    _writeVarint(value);
  }

  void string(int fieldNumber, String value) =>
      message(fieldNumber, Uint8List.fromList(utf8.encode(value)));

  void bytesField(int fieldNumber, Uint8List value) =>
      message(fieldNumber, value);

  void message(int fieldNumber, Uint8List value) {
    _writeVarint((fieldNumber << 3) | 2);
    _writeVarint(value.length);
    _bytes.add(value);
  }

  void _writeVarint(int value) {
    var remaining = value;
    while (remaining >= 0x80) {
      _bytes.addByte((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    _bytes.addByte(remaining);
  }

  Uint8List takeBytes() => _bytes.takeBytes();
}

class _ProtoField {
  const _ProtoField(this.number, this.wireType);

  final int number;
  final int wireType;
}

class _ProtoReader {
  _ProtoReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  bool get isDone => _offset >= _bytes.length;

  _ProtoField field() {
    final key = _readVarint();
    return _ProtoField(key >> 3, key & 7);
  }

  int varint(int wireType) {
    if (wireType != 0) throw const FormatException('Invalid varint wire type.');
    return _readVarint();
  }

  Uint8List bytes(int wireType) {
    if (wireType != 2) throw const FormatException('Invalid bytes wire type.');
    final length = _readVarint();
    final end = _offset + length;
    if (length < 0 || end > _bytes.length) {
      throw const FormatException('Truncated protobuf field.');
    }
    final value = Uint8List.sublistView(_bytes, _offset, end);
    _offset = end;
    return value;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        _readVarint();
      case 1:
        _advance(8);
      case 2:
        _advance(_readVarint());
      case 5:
        _advance(4);
      default:
        throw const FormatException('Unsupported protobuf wire type.');
    }
  }

  int _readVarint() {
    var value = 0;
    for (var shift = 0; shift < 64; shift += 7) {
      if (_offset >= _bytes.length) {
        throw const FormatException('Truncated protobuf varint.');
      }
      final byte = _bytes[_offset++];
      value |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return value;
    }
    throw const FormatException('Protobuf varint is too long.');
  }

  void _advance(int count) {
    final end = _offset + count;
    if (count < 0 || end > _bytes.length) {
      throw const FormatException('Truncated protobuf field.');
    }
    _offset = end;
  }
}
