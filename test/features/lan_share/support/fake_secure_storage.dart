import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Per-instance secure storage used by multi-device LAN tests.
///
/// Real devices have isolated keychains. Keeping a separate map for each fake
/// prevents concurrent read-modify-write operations from one simulated device
/// from overwriting the other device's credentials.
class FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _data = {};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) {
      final key = invocation.namedArguments[#key] as String;
      return Future<String?>.value(_data[key]);
    }
    if (invocation.memberName == #write) {
      final key = invocation.namedArguments[#key] as String;
      final value = invocation.namedArguments[#value] as String?;
      if (value == null) {
        _data.remove(key);
      } else {
        _data[key] = value;
      }
      return Future<void>.value();
    }
    if (invocation.memberName == #delete) {
      final key = invocation.namedArguments[#key] as String;
      _data.remove(key);
      return Future<void>.value();
    }
    throw UnimplementedError('FakeSecureStorage: ${invocation.memberName}');
  }
}
