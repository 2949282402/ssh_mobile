part of 'native_realtime_protocol.dart';

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
