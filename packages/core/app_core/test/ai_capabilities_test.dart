import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI capability request types preserve bounded defaults', () {
    const command = RemoteCommandRequest(
      connectionId: 'server-1',
      command: 'uname -a',
    );
    const transfer = FileTransferRequest(
      operation: FileTransferOperation.readText,
      connectionId: 'server-1',
      path: '/var/log/app.log',
    );
    const rag = RagQuery(query: 'ssh timeout');

    expect(command.timeout, const Duration(seconds: 15));
    expect(transfer.operation, FileTransferOperation.readText);
    expect(rag.limit, 3);
    expect(AppLanguage.zh.name, 'zh');
  });
}
