import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/services/sftp_path_history_store.dart';

void main() {
  test(
    'normalizes empty paths and caps recent history per connection',
    () async {
      final store = InMemorySftpPathHistoryStore();
      await store.recordVisitedPath('  c1 ', '   ');
      expect((await store.loadRecentPaths('c1')).single.path, '.');
      expect(await store.loadRecentPaths('c1', limit: -10), hasLength(1));
      expect(await store.loadRecentPaths('unknown', limit: 0), isEmpty);

      for (var i = 0; i < 31; i++) {
        await store.recordVisitedPath('c1', '/same');
      }
      expect(await store.loadRecentPaths('c1'), hasLength(2));
      for (var i = 0; i < 31; i++) {
        await store.recordVisitedPath('c1', '/path-$i');
      }
      final recent = await store.loadRecentPaths('c1', limit: 100);
      expect(recent, hasLength(30));
      expect(recent.first.path, '/path-30');
      expect(recent.last.path, '/path-1');
    },
  );

  test(
    'uses path-derived favorite names and keeps favorite views immutable',
    () async {
      final store = InMemorySftpPathHistoryStore();
      final root = await store.addFavoritePath('c', '.', '');
      final trailing = await store.addFavoritePath('c', '/var/log/', '');
      expect(root.name, '.');
      expect(trailing.name, '/var/log/');

      final a = await store.addFavoritePath('c', '/z', 'same');
      final b = await store.addFavoritePath('c', '/a', 'same');
      expect((await store.loadFavoritePaths('c')).map((entry) => entry.path), [
        '.',
        '/var/log/',
        '/a',
        '/z',
      ]);
      final listed = await store.loadFavoritePaths('c');
      expect(() => listed.add(a), throwsUnsupportedError);
      await store.renameFavoritePath(a.id, '  renamed  ');
      expect((await store.findFavoritePath('c', '/z'))!.name, 'renamed');
      await store.renameFavoritePath(b.id, '   ');
      await store.removeFavoritePath(a.id);
      expect(await store.findFavoritePath('c', '/z'), isNull);
    },
  );
}
