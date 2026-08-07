import 'dart:typed_data';

class File {
  final String path;
  File(this.path);

  Future<bool> exists() async => false;
  bool existsSync() => false;
  Future<String> readAsString() async => '';
  String readAsStringSync() => '';
  Future<void> writeAsString(String content) async {}
  Future<void> delete() async {}
  Future<int> length() async => 0;
  Future<Uint8List> readAsBytes() async => Uint8List(0);
  Future<void> writeAsBytes(Uint8List bytes) async {}
}
