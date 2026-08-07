// SFTP 路径数据库与 Repository 测试。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_sftp/feature_sftp.dart';

void main() {
  test(
    'recent paths are bounded and favorites are connection-scoped',
    () async {
      final database = SftpDatabase.forTesting(NativeDatabase.memory());
      final repository = DriftSftpPathHistoryRepository(database);
      addTearDown(database.dispose);

      for (var index = 0; index < 35; index++) {
        await repository.recordVisitedPath('connection-1', '/path/$index');
      }
      final recent = await repository.loadRecentPaths('connection-1');
      expect(recent, hasLength(30));

      final favorite = await repository.addFavoritePath(
        'connection-1',
        '/srv/app',
        'Application',
      );
      final updated = await repository.addFavoritePath(
        'connection-1',
        '/srv/app',
        'App',
      );
      expect(updated.id, favorite.id);
      expect(
        (await repository.loadFavoritePaths('connection-1')),
        hasLength(1),
      );
      expect(
        (await repository.findFavoritePath('connection-1', '/srv/app'))?.name,
        'App',
      );

      await repository.renameFavoritePath(favorite.id, 'Renamed app');
      expect(
        (await repository.findFavoritePath('connection-1', '/srv/app'))?.name,
        'Renamed app',
      );
      expect(await repository.loadFavoritePaths('connection-2'), isEmpty);

      await repository.removeFavoritePath(favorite.id);
      expect(
        await repository.findFavoritePath('connection-1', '/srv/app'),
        isNull,
      );
    },
  );
}
