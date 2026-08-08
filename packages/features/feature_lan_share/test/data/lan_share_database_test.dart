// LAN Share 独立数据库测试。
//
// 验证传输历史和非敏感配对元数据可以独立读写，避免误把密钥、PIN 或
// Relay Token 作为数据库字段的一部分。

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feature_lan_share/src/data/database/lan_share_database.dart';

void main() {
  late LanShareDatabase database;

  setUp(() {
    database = LanShareDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.dispose();
  });

  test('stores transfer history and pairing display metadata', () async {
    await database.lanHistoryDao.insertRecord(
      LanTransferRecordsCompanion.insert(
        id: 'transfer-1',
        senderId: 'sender-1',
        senderAlias: 'Sender',
        receiverId: 'receiver-1',
        payloadType: 'text',
        textContent: const Value('encrypted-history'),
        status: 'completed',
        createdAt: 100,
      ),
    );
    await database.lanPairingMetadataDao.upsert(
      LanPairingMetadataCompanion.insert(
        deviceId: 'peer-1',
        alias: 'Peer',
        ip: const Value('192.168.1.20'),
        port: const Value(53317),
        lastSeen: 200,
      ),
    );

    final history = await database.lanHistoryDao.getRecord('transfer-1');
    final peers = await database.lanPairingMetadataDao.getAll();
    expect(history?.textContent, 'encrypted-history');
    expect(peers.single.deviceId, 'peer-1');
    expect(peers.single.ip, '192.168.1.20');
  });
}
