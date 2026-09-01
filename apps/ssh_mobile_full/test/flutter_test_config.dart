import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

typedef _DlopenNative =
    Pointer<Void> Function(Pointer<Uint8> filename, Int32 flags);
typedef _DlopenDart =
    Pointer<Void> Function(Pointer<Uint8> filename, int flags);

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (Platform.isLinux) {
    try {
      const rtldNow = 2;
      const rtldGlobal = 256;
      final process = DynamicLibrary.process();
      final dlopen = process.lookupFunction<_DlopenNative, _DlopenDart>(
        'dlopen',
      );
      final malloc = process
          .lookupFunction<
            Pointer<Uint8> Function(IntPtr),
            Pointer<Uint8> Function(int)
          >('malloc');
      final free = process
          .lookupFunction<Void Function(Pointer), void Function(Pointer)>(
            'free',
          );

      for (final name in ['libsqlite3.so.0', 'libsqlite3.so']) {
        final encoded = utf8.encode(name);
        final ptr = malloc(encoded.length + 1);
        if (ptr.address == 0) continue;
        for (var i = 0; i < encoded.length; i++) {
          ptr[i] = encoded[i];
        }
        ptr[encoded.length] = 0;
        final handle = dlopen(ptr, rtldNow | rtldGlobal);
        free(ptr);
        if (handle.address != 0) break;
      }
    } catch (_) {}
  }
  await testMain();
}
