import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/main.dart';

void main() {
  testWidgets('app widget can be constructed', (WidgetTester tester) async {
    expect(const SshMobileApp(), isA<SshMobileApp>());
  });
}
