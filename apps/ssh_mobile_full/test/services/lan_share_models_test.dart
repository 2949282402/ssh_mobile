import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

void main() {
  group('LAN Share Models Test', () {
    test('LanDevice JSON serialization and deserialization', () {
      final now = DateTime.now();
      final device = LanDevice(
        id: 'dev-123',
        alias: 'Test Phone',
        ip: '192.168.1.50',
        port: 53317,
        deviceType: LanDeviceType.mobile,
        osName: 'Android 14',
        certFingerprint: 'abc123sha256',
        isTrusted: true,
        lastSeen: now,
      );

      final json = device.toJson();
      final restored = LanDevice.fromJson(json);

      expect(restored.id, equals('dev-123'));
      expect(restored.alias, equals('Test Phone'));
      expect(restored.ip, equals('192.168.1.50'));
      expect(restored.port, equals(53317));
      expect(restored.deviceType, equals(LanDeviceType.mobile));
      expect(restored.osName, equals('Android 14'));
      expect(restored.certFingerprint, equals('abc123sha256'));
      expect(restored.isTrusted, isTrue);
    });

    test('FileManifest JSON encode/decode', () {
      const manifest = FileManifest(
        totalFiles: 2,
        totalSize: 1024,
        entries: [
          FileManifestEntry(relativePath: 'doc.pdf', size: 512),
          FileManifestEntry(relativePath: 'img.png', size: 512),
        ],
      );

      final encoded = manifest.encodeJson();
      final decoded = FileManifest.decodeJson(encoded);

      expect(decoded.totalFiles, equals(2));
      expect(decoded.totalSize, equals(1024));
      expect(decoded.entries.length, equals(2));
      expect(decoded.entries.first.relativePath, equals('doc.pdf'));
    });

    test('LanMessage JSON serialization', () {
      final now = DateTime.now();
      final msg = LanMessage(
        id: 'msg-999',
        senderId: 's1',
        senderAlias: 'Sender',
        receiverId: 'r1',
        payloadType: LanPayloadType.image,
        fileName: 'photo.jpg',
        fileSize: 2048,
        createdAt: now,
        isIncoming: true,
      );

      final json = msg.toJson();
      final restored = LanMessage.fromJson(json);

      expect(restored.id, equals('msg-999'));
      expect(restored.payloadType, equals(LanPayloadType.image));
      expect(restored.fileName, equals('photo.jpg'));
      expect(restored.fileSize, equals(2048));
      expect(restored.isIncoming, isTrue);
    });
  });
}
