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

  test(
    'formats all size units, root paths, links, and unknown metadata',
    () async {
      final entries = await SftpEntryParser.parse(
        connectionId: 'conn-2',
        targetFingerprint: 'target-fingerprint-2',
        absolutePath: '/',
        names: [
          SftpName(
            filename: 'bytes',
            longname: '',
            attr: SftpFileAttrs(size: 1),
          ),
          SftpName(
            filename: 'kilobytes',
            longname: '',
            attr: SftpFileAttrs(size: 10 * 1024),
          ),
          SftpName(
            filename: 'megabytes',
            longname: '',
            attr: SftpFileAttrs(size: 2 * 1024 * 1024),
          ),
          SftpName(
            filename: 'gigabytes',
            longname: '',
            attr: SftpFileAttrs(size: 10 * 1024 * 1024 * 1024),
          ),
          SftpName(filename: 'unknown', longname: '', attr: SftpFileAttrs()),
          SftpName(
            filename: 'link',
            longname: '',
            attr: SftpFileAttrs(
              mode: const SftpFileMode.value((1 << 15) + (1 << 13)),
            ),
          ),
          SftpName(filename: '..', longname: '', attr: SftpFileAttrs()),
        ],
      );

      final byName = <String, SftpEntry>{
        for (final entry in entries) entry.name: entry,
      };
      expect(byName['bytes']!.path, '/bytes');
      expect(byName['bytes']!.sizeLabel, '1 B');
      expect(byName['kilobytes']!.sizeLabel, '10 KB');
      expect(byName['megabytes']!.sizeLabel, '2.0 MB');
      expect(byName['gigabytes']!.sizeLabel, '10 GB');
      expect(byName['unknown']!.sizeLabel, '-');
      expect(byName['unknown']!.modifiedAt, isNull);
      expect(byName['link']!.isLink, isTrue);
      expect(byName['link']!.path, '/link');
    },
  );

  test(
    'joins an empty base path and preserves directory-first sorting',
    () async {
      final entries = await SftpEntryParser.parse(
        connectionId: 'conn-3',
        targetFingerprint: 'target-fingerprint-3',
        absolutePath: '',
        names: [
          SftpName(
            filename: 'file',
            longname: '',
            attr: SftpFileAttrs(size: 0),
          ),
          SftpName(
            filename: 'Folder',
            longname: '',
            attr: SftpFileAttrs(mode: const SftpFileMode.value(1 << 14)),
          ),
        ],
      );

      expect(entries.map((entry) => entry.name), ['Folder', 'file']);
      expect(entries.first.path, '/Folder');
      expect(entries.first.isDirectory, isTrue);
      expect(entries.last.sizeLabel, '0 B');
    },
  );
}
