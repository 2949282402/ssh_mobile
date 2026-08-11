// Native v1 Realtime command/event bindings.
//
// The Rust network-protocol crate remains the wire-contract owner. This file
// mirrors only the fields needed by the public native SDK facade and keeps
// protobuf framing, identifiers, and payload sizes bounded at the Dart edge.

import 'dart:convert';
import 'dart:typed_data';

const _protocolVersion = 1;
const _maxCommandIdBytes = 128;
const _maxEventIdBytes = 256;
const _maxPeerIdBytes = 128;
const _maxErrorMessageBytes = 8 * 1024;
const _realtimeIdBytes = 32;
const _maxRealtimePayloadBytes = 256 * 1024;
const _maxIceCandidateBytes = 8 * 1024;
const _maxEventBytes = 384 * 1024;

/// Native WebRTC Realtime session lifecycle states.
enum NativeRealtimeSessionState {
  unspecified(0),
  negotiating(1),
  connected(2),
  restarting(3),
  closed(4),
  failed(5);

  const NativeRealtimeSessionState(this.wireValue);

  /// Protobuf enumeration value used by Rust.
  final int wireValue;

  /// Converts an unknown wire value to [unspecified].
  static NativeRealtimeSessionState fromWire(int value) =>
      NativeRealtimeSessionState.values.firstWhere(
        (state) => state.wireValue == value,
        orElse: () => NativeRealtimeSessionState.unspecified,
      );
}

/// Native WebRTC signaling kinds.
enum NativeRealtimeSignalKind {
  unspecified(0),
  webRtcOffer(1),
  webRtcAnswer(2),
  iceCandidate(3),
  iceRestart(4),
  webRtcClose(5);

  const NativeRealtimeSignalKind(this.wireValue);

  /// Protobuf enumeration value used by Rust.
  final int wireValue;

  /// Converts an unknown wire value to [unspecified].
  static NativeRealtimeSignalKind fromWire(int value) =>
      NativeRealtimeSignalKind.values.firstWhere(
        (kind) => kind.wireValue == value,
        orElse: () => NativeRealtimeSignalKind.unspecified,
      );
}

/// A redacted, typed native network error.
final class NativeNetworkError {
  /// Creates a native network error value.
  const NativeNetworkError({
    required this.code,
    required this.message,
    this.operation,
    this.peerId,
  });

  /// Rust `NetworkErrorCode` wire value.
  final int code;

  /// Human-readable operation error without secret payloads.
  final String message;

  /// Native operation name, when present.
  final String? operation;

  /// Related peer identifier, when present.
  final String? peerId;
}

/// Base class for typed events emitted by [NativeNetworkRuntime.events].
sealed class NativeNetworkEvent {
  /// Creates a typed event envelope.
  const NativeNetworkEvent({
    required this.eventId,
    required this.timestampMs,
    required this.protocolVersion,
  });

  /// Native event identifier.
  final String eventId;

  /// Native event timestamp in Unix milliseconds.
  final int timestampMs;

  /// Protocol version carried by the native event.
  final int protocolVersion;
}

/// Result of a command accepted or rejected by the native worker.
final class NativeCommandResultEvent extends NativeNetworkEvent {
  /// Creates a command result event.
  const NativeCommandResultEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.commandId,
    required this.accepted,
    this.error,
  });

  /// Command identifier supplied in the command envelope.
  final String commandId;

  /// Whether the worker accepted the command for execution.
  final bool accepted;

  /// Structured rejection, when [accepted] is false.
  final NativeNetworkError? error;
}

/// Realtime session state event.
final class NativeRealtimeStateChangedEvent extends NativeNetworkEvent {
  /// Creates a realtime state event.
  const NativeRealtimeStateChangedEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.realtimeId,
    required this.peerId,
    required this.state,
    required this.revision,
    this.error,
  });

  /// Stable 16-byte lowercase hexadecimal realtime session identifier.
  final String realtimeId;

  /// Remote peer identifier.
  final String peerId;

  /// Current native realtime state.
  final NativeRealtimeSessionState state;

  /// Signaling revision associated with this state.
  final int revision;

  /// Structured failure, when [state] is failed.
  final NativeNetworkError? error;
}

/// Realtime signaling event containing bounded SDP/ICE opaque bytes.
final class NativeRealtimeSignalEvent extends NativeNetworkEvent {
  /// Creates a realtime signaling event.
  NativeRealtimeSignalEvent({
    required super.eventId,
    required super.timestampMs,
    required super.protocolVersion,
    required this.realtimeId,
    required this.peerId,
    required this.kind,
    required this.revision,
    required Uint8List payload,
  }) : payload = Uint8List.fromList(payload);

  /// Stable 16-byte lowercase hexadecimal realtime session identifier.
  final String realtimeId;

  /// Remote peer identifier.
  final String peerId;

  /// Signaling message kind.
  final NativeRealtimeSignalKind kind;

  /// Signaling revision associated with the message.
  final int revision;

  /// SDP, ICE, or close control bytes. Never a media/file data frame.
  final Uint8List payload;
}

/// Bounded Protobuf command/event codec for the native Realtime API.
final class NativeNetworkProtocol {
  /// Current native protocol version.
  static const int protocolVersion = _protocolVersion;

  const NativeNetworkProtocol._();

  /// Encodes `StartRealtimeSession` into the v1 command envelope.
  static Uint8List startRealtimeSessionCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
  }) {
    _validateCommandId(commandId);
    _validateRealtimeId(realtimeId);
    _validatePeerId(peerId);
    return _command(
      commandId,
      21,
      (_ProtoWriter()
            ..string(1, realtimeId)
            ..string(2, peerId))
          .takeBytes(),
    );
  }

  /// Encodes `StopRealtimeSession` into the v1 command envelope.
  static Uint8List stopRealtimeSessionCommand({
    required String commandId,
    required String realtimeId,
  }) {
    _validateCommandId(commandId);
    _validateRealtimeId(realtimeId);
    return _command(
      commandId,
      22,
      (_ProtoWriter()..string(1, realtimeId)).takeBytes(),
    );
  }

  /// Encodes `SendRealtimeSignal` into the v1 command envelope.
  static Uint8List sendRealtimeSignalCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
    required NativeRealtimeSignalKind kind,
    required int revision,
    required Uint8List payload,
  }) {
    _validateCommandId(commandId);
    _validateRealtimeId(realtimeId);
    _validatePeerId(peerId);
    if (kind == NativeRealtimeSignalKind.unspecified) {
      throw ArgumentError.value(
        kind,
        'kind',
        'A concrete signal kind is required.',
      );
    }
    if (revision <= 0) {
      throw ArgumentError.value(revision, 'revision', 'Must be positive.');
    }
    _validateSignalPayload(kind, payload);
    return _command(
      commandId,
      23,
      (_ProtoWriter()
            ..string(1, realtimeId)
            ..string(2, peerId)
            ..varint(3, kind.wireValue)
            ..varint(4, revision)
            ..bytesField(5, payload))
          .takeBytes(),
    );
  }

  /// Decodes a native event. Unknown event payloads return null so a newer
  /// Rust event cannot terminate the public typed stream.
  static NativeNetworkEvent? decodeEvent(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > _maxEventBytes) {
      throw const FormatException('Native event is outside size bounds.');
    }
    final reader = _ProtoReader(bytes);
    var eventId = '';
    var timestampMs = 0;
    var protocolVersion = 0;
    int? payloadField;
    Uint8List? payload;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          eventId = reader.string(field.wireType, _maxEventIdBytes);
        case 2:
          timestampMs = reader.varint(field.wireType);
        case 3:
          protocolVersion = reader.varint(field.wireType);
        case 13:
        case 21:
        case 22:
          payloadField = field.number;
          payload = reader.bytes(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    if (eventId.isEmpty) {
      throw const FormatException('Native event has no event ID.');
    }
    if (protocolVersion != _protocolVersion) {
      throw FormatException(
        'Unsupported native protocol version: $protocolVersion.',
      );
    }
    final eventPayload = payload;
    final fieldNumber = payloadField;
    if (eventPayload == null || fieldNumber == null) return null;
    return switch (fieldNumber) {
      13 => _decodeCommandResult(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      21 => _decodeRealtimeState(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      22 => _decodeRealtimeSignal(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      _ => null,
    };
  }

  static Uint8List _command(String commandId, int field, Uint8List payload) =>
      (_ProtoWriter()
            ..string(1, commandId)
            ..varint(2, _protocolVersion)
            ..message(field, payload))
          .takeBytes();

  static NativeCommandResultEvent _decodeCommandResult(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var commandId = '';
    var accepted = false;
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          commandId = reader.string(field.wireType, _maxCommandIdBytes);
        case 2:
          accepted = reader.varint(field.wireType) != 0;
        case 3:
          error = _decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    if (commandId.isEmpty) {
      throw const FormatException('Native command result has no command ID.');
    }
    return NativeCommandResultEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      commandId: commandId,
      accepted: accepted,
      error: error,
    );
  }

  static NativeRealtimeStateChangedEvent _decodeRealtimeState(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var realtimeId = '';
    var peerId = '';
    var state = 0;
    var revision = 0;
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          realtimeId = reader.string(field.wireType, _realtimeIdBytes);
        case 2:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          state = reader.varint(field.wireType);
        case 4:
          revision = reader.varint(field.wireType);
        case 5:
          error = _decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedRealtimeId(realtimeId);
    _validateDecodedPeerId(peerId);
    return NativeRealtimeStateChangedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      realtimeId: realtimeId,
      peerId: peerId,
      state: NativeRealtimeSessionState.fromWire(state),
      revision: revision,
      error: error,
    );
  }

  static NativeRealtimeSignalEvent _decodeRealtimeSignal(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var realtimeId = '';
    var peerId = '';
    var kind = 0;
    var revision = 0;
    var payload = Uint8List(0);
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          realtimeId = reader.string(field.wireType, _realtimeIdBytes);
        case 2:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          kind = reader.varint(field.wireType);
        case 4:
          revision = reader.varint(field.wireType);
        case 5:
          payload = reader.bytes(field.wireType, _maxRealtimePayloadBytes);
        default:
          reader.skip(field.wireType);
      }
    }
    _validateDecodedRealtimeId(realtimeId);
    _validateDecodedPeerId(peerId);
    try {
      _validateSignalPayload(NativeRealtimeSignalKind.fromWire(kind), payload);
    } on ArgumentError catch (error) {
      throw FormatException(error.message);
    }
    if (revision <= 0) {
      throw const FormatException('Realtime signal revision must be positive.');
    }
    return NativeRealtimeSignalEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      realtimeId: realtimeId,
      peerId: peerId,
      kind: NativeRealtimeSignalKind.fromWire(kind),
      revision: revision,
      payload: payload,
    );
  }

  static NativeNetworkError _decodeError(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    var code = 0;
    var message = '';
    String? operation;
    String? peerId;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          code = reader.varint(field.wireType);
        case 2:
          message = reader.string(field.wireType, _maxErrorMessageBytes);
        case 3:
          operation = reader.string(field.wireType, _maxCommandIdBytes);
        case 4:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        default:
          reader.skip(field.wireType);
      }
    }
    return NativeNetworkError(
      code: code,
      message: message,
      operation: operation?.isEmpty == true ? null : operation,
      peerId: peerId?.isEmpty == true ? null : peerId,
    );
  }

  static void _validateCommandId(String value) {
    if (value.isEmpty || _utf8ByteLength(value) > _maxCommandIdBytes) {
      throw ArgumentError.value(
        value,
        'commandId',
        'Must contain 1-128 bytes.',
      );
    }
  }

  static void _validatePeerId(String value) {
    if (value.isEmpty || _utf8ByteLength(value) > _maxPeerIdBytes) {
      throw ArgumentError.value(value, 'peerId', 'Must contain 1-128 bytes.');
    }
  }

  static void _validateRealtimeId(String value) {
    if (value.length != _realtimeIdBytes ||
        value != value.toLowerCase() ||
        !_isLowerHex(value)) {
      throw ArgumentError.value(
        value,
        'realtimeId',
        'Must be 32 lowercase hexadecimal characters.',
      );
    }
  }

  static void _validateDecodedRealtimeId(String value) {
    try {
      _validateRealtimeId(value);
    } on ArgumentError catch (error) {
      throw FormatException(error.message);
    }
  }

  static void _validateDecodedPeerId(String value) {
    if (value.isEmpty || _utf8ByteLength(value) > _maxPeerIdBytes) {
      throw const FormatException('Realtime peer ID is outside bounds.');
    }
  }

  static int _utf8ByteLength(String value) => utf8.encode(value).length;

  static bool _isLowerHex(String value) => value.codeUnits.every((code) {
    return (code >= 0x30 && code <= 0x39) || (code >= 0x61 && code <= 0x66);
  });

  static void _validateSignalPayload(
    NativeRealtimeSignalKind kind,
    Uint8List payload,
  ) {
    if (kind == NativeRealtimeSignalKind.unspecified) {
      throw ArgumentError.value(kind, 'kind', 'Unknown signal kind.');
    }
    if (payload.length > _maxRealtimePayloadBytes) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'Payload is too large.',
      );
    }
    if (kind == NativeRealtimeSignalKind.iceCandidate &&
        payload.length > _maxIceCandidateBytes) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'ICE candidate payload is too large.',
      );
    }
    if (kind != NativeRealtimeSignalKind.webRtcClose &&
        kind != NativeRealtimeSignalKind.iceRestart &&
        kind != NativeRealtimeSignalKind.iceCandidate &&
        payload.isEmpty) {
      throw ArgumentError.value(
        payload,
        'payload',
        'Payload must not be empty.',
      );
    }
  }
}

final class _ProtoWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void varint(int fieldNumber, int value) {
    _writeVarint(fieldNumber << 3);
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

final class _ProtoField {
  const _ProtoField(this.number, this.wireType);

  final int number;
  final int wireType;
}

final class _ProtoReader {
  _ProtoReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  bool get isDone => _offset >= _bytes.length;

  _ProtoField field() {
    final key = _readVarint();
    if (key < 8) throw const FormatException('Invalid protobuf field key.');
    return _ProtoField(key >> 3, key & 7);
  }

  int varint(int wireType) {
    if (wireType != 0) throw const FormatException('Invalid varint wire type.');
    return _readVarint();
  }

  String string(int wireType, int maxBytes) =>
      utf8.decode(bytes(wireType, maxBytes));

  Uint8List bytes(int wireType, [int maxBytes = _maxEventBytes]) {
    if (wireType != 2) throw const FormatException('Invalid bytes wire type.');
    final length = _readVarint();
    if (length > maxBytes || length > _bytes.length - _offset) {
      throw const FormatException('Protobuf bytes are outside bounds.');
    }
    final value = _bytes.sublist(_offset, _offset + length);
    _offset += length;
    return Uint8List.fromList(value);
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        _readVarint();
      case 1:
        _advance(8);
      case 2:
        final length = _readVarint();
        _advance(length);
      case 5:
        _advance(4);
      default:
        throw const FormatException('Unsupported protobuf wire type.');
    }
  }

  int _readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_offset >= _bytes.length || shift > 63) {
        throw const FormatException('Truncated protobuf varint.');
      }
      final byte = _bytes[_offset++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
    }
  }

  void _advance(int length) {
    if (length < 0 || length > _bytes.length - _offset) {
      throw const FormatException('Truncated protobuf field.');
    }
    _offset += length;
  }
}
