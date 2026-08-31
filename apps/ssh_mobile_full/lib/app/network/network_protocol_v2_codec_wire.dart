part of '../../services/network/network_protocol_v2_codec.dart';

/// 用于 Network Protocol V2 命令字段的最小 Protobuf 写入器。
final class _ProtoWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  /// 写入 varint 字段。
  void varint(int fieldNumber, int value) {
    _writeVarint((fieldNumber << 3));
    _writeVarint(value);
  }

  /// 写入 UTF-8 字符串字段。
  void string(int fieldNumber, String value) =>
      message(fieldNumber, Uint8List.fromList(utf8.encode(value)));

  /// 写入长度分隔的字节字段。
  void bytesField(int fieldNumber, Uint8List value) =>
      message(fieldNumber, value);

  /// 写入长度分隔的嵌套消息。
  void message(int fieldNumber, Uint8List value) {
    _writeVarint((fieldNumber << 3) | 2);
    _writeVarint(value.length);
    _bytes.add(value);
  }

  /// 写入原始 Protobuf varint。
  void _writeVarint(int value) {
    var remaining = value;
    while (remaining >= 0x80) {
      _bytes.addByte((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    _bytes.addByte(remaining);
  }

  /// 返回已写入的全部字节，并重置构建器。
  Uint8List takeBytes() => _bytes.takeBytes();
}

/// 已解析的 Protobuf 字段 key 与 wire type。
final class _ProtoField {
  /// 创建已解析的字段描述。
  const _ProtoField(this.number, this.wireType);

  final int number;
  final int wireType;
}

/// 用于 Network Protocol V2 事件字段的最小 Protobuf 读取器。
final class _ProtoReader {
  /// 创建读取 [bytes] 的读取器。
  _ProtoReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  /// 输入字节是否已经全部读取。
  bool get isDone => _offset >= _bytes.length;

  /// 读取下一个 Protobuf 字段 key。
  _ProtoField field() {
    final key = _readVarint();
    return _ProtoField(key >> 3, key & 7);
  }

  /// 校验 wire type 后读取 varint 字段。
  int varint(int wireType) {
    if (wireType != 0) throw const FormatException('Invalid varint wire type.');
    return _readVarint();
  }

  /// 校验 wire type 后读取长度分隔字段。
  Uint8List bytes(int wireType) {
    if (wireType != 2) throw const FormatException('Invalid bytes wire type.');
    final length = _readVarint();
    final end = _offset + length;
    if (end > _bytes.length) {
      throw const FormatException('Truncated protobuf field.');
    }
    final value = Uint8List.sublistView(_bytes, _offset, end);
    _offset = end;
    return value;
  }

  /// 跳过未知 Protobuf 字段，同时保持流对齐。
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

  /// 读取一个原始 Protobuf varint。
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

  /// 前进 [count] 个字节，并拒绝被截断的输入。
  void _advance(int count) {
    final end = _offset + count;
    if (end > _bytes.length) {
      throw const FormatException('Truncated protobuf field.');
    }
    _offset = end;
  }
}
