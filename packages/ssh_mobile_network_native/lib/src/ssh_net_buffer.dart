import 'dart:ffi';

/// FFI struct representing a byte buffer allocated by Rust FFI.
final class SshNetBuffer extends Struct {
  external Pointer<Uint8> ptr;

  @Size()
  external int len;
}
