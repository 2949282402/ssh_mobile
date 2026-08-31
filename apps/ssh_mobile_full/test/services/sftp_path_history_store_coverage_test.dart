import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/services/sftp_path_history_store.dart';

void main() {
  test('normalizes recent paths, deduplicates, and caps history', () async {
    final store = InMemorySftpPathHistoryStore();
    await store.recordVisitedPath('  connection-1  ', '  /srv  ');
    await store.recordVisitedPath('connection-1', '/tmp');
    await store.recordVisitedPath('connection-1', '/srv');
    await store.recordVisitedPath('', '/ignored');

    final recent = await store.loadRecentPaths('connection-1', limit: 2);
    expect(recent.map((record) => record.path), ['/srv', '/tmp']);
    expect(
      recent.every((record) => record.connectionId == 'connection-1'),
      isTrue,
    );
    expect(await store.loadRecentPaths('missing'), isEmpty);
    expect(await store.loadRecentPaths('connection-1', limit: 0), hasLength(1));

    for (var i = 0; i < 35; i++) {
      await store.recordVisitedPath('connection-1', '/path-$i');
    }
    expect(
      await store.loadRecentPaths('connection-1', limit: 100),
      hasLength(30),
    );
  });

  test('creates, updates, sorts, renames, and removes favorites', () async {
    final store = InMemorySftpPathHistoryStore();
    final root = await store.addFavoritePath('connection-1', '/', '');
    expect(root.name, '/');
    final nested = await store.addFavoritePath('connection-1', '/srv/logs', '');
    expect(nested.name, 'logs');
    final updated = await store.addFavoritePath(
      'connection-1',
      '/srv/logs',
      '  Logs  ',
    );
    expect(updated.id, nested.id);
    expect(updated.name, 'Logs');

    final other = await store.addFavoritePath('connection-1', '/aaa', 'AAA');
    await store.addFavoritePath('connection-2', '/other', 'Other');
    expect(
      (await store.loadFavoritePaths(
        'connection-1',
      )).map((record) => record.id),
      [root.id, other.id, nested.id],
    );
    expect(
      await store.findFavoritePath('connection-1', ' /srv/logs '),
      isNotNull,
    );
    expect(await store.findFavoritePath('connection-1', '/none'), isNull);

    await store.renameFavoritePath(nested.id, '  Renamed  ');
    expect(
      (await store.findFavoritePath('connection-1', '/srv/logs'))!.name,
      'Renamed',
    );
    await store.renameFavoritePath('missing', 'ignored');
    await store.renameFavoritePath(root.id, '   ');
    expect((await store.findFavoritePath('connection-1', '/'))!.name, '/');

    await store.removeFavoritePath(other.id);
    expect(await store.findFavoritePath('connection-1', '/aaa'), isNull);
    await store.removeFavoritePath('missing');

    final copied = updated.copyWith(name: 'Copy');
    expect(copied.id, updated.id);
    expect(copied.name, 'Copy');
    expect(copied.createdAt, updated.createdAt);
  });
}
