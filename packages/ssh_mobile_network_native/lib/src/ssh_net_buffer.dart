import 'dart:ffi';

/// 表示由 Rust FFI 分配的字节缓冲区的 FFI 结构体。
final class SshNetBuffer extends Struct {
  external Pointer<Uint8> ptr;

  @Size()
  external int len;
}
