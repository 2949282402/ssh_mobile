import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/app/sftp_backend_adapters.dart';

void main() {
  test('SFTP entries are built and sorted in a background isolate', () async {
    final entries = await SftpEntryParser.parse(
      connectionId: 'conn-1',
      targetFingerprint: 'target-fingerprint-1',
      absolutePath: '/srv',
      names: [
        SftpName(
          filename: 'zeta.txt',
          longname: '',
          attr: SftpFileAttrs(size: 2048, modifyTime: 1700000000),
        ),
        SftpName(
          filename: 'Alpha',
          longname: '',
          attr: SftpFileAttrs(mode: const SftpFileMode.value(1 << 14)),
        ),
        SftpName(filename: '.', longname: '', attr: SftpFileAttrs()),
      ],
    );

    expect(entries.map((entry) => entry.name), ['Alpha', 'zeta.txt']);
    expect(
      entries.every(
        (entry) => entry.targetFingerprint == 'target-fingerprint-1',
      ),
      isTrue,
    );
    expect(entries.first.isDirectory, isTrue);
    expect(entries.last.path, '/srv/zeta.txt');
    expect(entries.last.sizeLabel, '2.0 KB');
    expect(entries.last.modifiedLabel, isNotNull);
  });
}
