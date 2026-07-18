import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/lan_share/lan_security_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_share_models.dart';
import 'package:ssh_mobile/services/lan_share/lan_storage_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_transfer_service.dart';

import 'support/fake_secure_storage.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _TwoPartyBarrier {
  final Completer<void> _release = Completer<void>();
  int _arrivals = 0;

  Future<void> arrive() {
    _arrivals++;
    if (_arrivals == 2 && !_release.isCompleted) {
      _release.complete();
    }
    return _release.future;
  }
}

class _BarrierLanSecurityService extends LanSecurityService {
  final _TwoPartyBarrier barrier;
  bool _holdFirstReciprocalCheck = true;

  _BarrierLanSecurityService({
    required FakeSecureStorage secureStorage,
    required this.barrier,
  }) : super(secureStorage: secureStorage);

  @override
  Future<bool> hasCompleteOutboundPairCredential(String deviceId) async {
    if (_holdFirstReciprocalCheck) {
      _holdFirstReciprocalCheck = false;
      await barrier.arrive();
      return false;
    }
    return super.hasCompleteOutboundPairCredential(deviceId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final responderSubmitsFirst in [false, true]) {
    test(
      'real HTTPS reciprocal pairing works when '
      '${responderSubmitsFirst ? 'responder' : 'initiator'} submits first',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final securityA = LanSecurityService(
            secureStorage: FakeSecureStorage(),
          );
          final securityB = LanSecurityService(
            secureStorage: FakeSecureStorage(),
          );
          final transferA = LanTransferService(
            currentDeviceId: 'device-a',
            securityService: securityA,
            storageService: LanStorageService(),
          );
          final transferB = LanTransferService(
            currentDeviceId: 'device-b',
            securityService: securityB,
            storageService: LanStorageService(),
          );
          addTearDown(() async {
            await transferA.stopListening();
            await transferB.stopListening();
            await transferA.closeConnections();
            await transferB.closeConnections();
            transferA.dispose();
            transferB.dispose();
          });

          final portA = await transferA.startListening(port: 0);
          final portB = await transferB.startListening(port: 0);
          final deviceA = LanDevice(
            id: 'device-a',
            alias: 'Device A',
            ip: InternetAddress.loopbackIPv4.address,
            port: portA,
            deviceType: LanDeviceType.desktop,
            osName: 'windows',
            lastSeen: DateTime.now(),
          );
          final deviceB = LanDevice(
            id: 'device-b',
            alias: 'Device B',
            ip: InternetAddress.loopbackIPv4.address,
            port: portB,
            deviceType: LanDeviceType.mobile,
            osName: 'android',
            lastSeen: DateTime.now(),
          );
          final pinA = securityA.generate6DigitPin();
          final pinB = securityB.generate6DigitPin();

          late final HandshakeResult first;
          late final HandshakeResult second;
          if (responderSubmitsFirst) {
            first = await transferB.sendHandshake(
              deviceA,
              pinA,
              'Device B',
              isInitiator: false,
            );
            second = await transferA.sendHandshake(
              deviceB,
              pinB,
              'Device A',
              isInitiator: true,
            );
            if (second.success && !second.pendingRemote) {
              await securityA.confirmDevicePairing(deviceB.id);
            }
          } else {
            first = await transferA.sendHandshake(
              deviceB,
              pinB,
              'Device A',
              isInitiator: true,
            );
            second = await transferB.sendHandshake(
              deviceA,
              pinA,
              'Device B',
              isInitiator: false,
            );
            if (second.success && !second.pendingRemote) {
              await securityB.confirmDevicePairing(deviceA.id);
            }
          }

          expect(first.success, isTrue);
          expect(first.pendingRemote, isTrue);
          expect(second.success, isTrue);
          expect(second.pendingRemote, isFalse);
          expect(await securityA.isDevicePaired(deviceB.id), isTrue);
          expect(await securityB.isDevicePaired(deviceA.id), isTrue);

          final incoming = transferB.incomingMessageStream.first;
          final sent = await transferA.sendMeta(
            deviceB,
            LanMessage(
              id: 'loopback-message',
              senderId: deviceA.id,
              senderAlias: deviceA.alias,
              receiverId: deviceB.id,
              payloadType: LanPayloadType.text,
              textContent: 'paired transport works',
              status: LanTransferStatus.transferring,
              createdAt: DateTime.now(),
              isIncoming: false,
            ),
          );

          expect(sent, isTrue);
          expect(
            (await incoming.timeout(const Duration(seconds: 3))).textContent,
            'paired transport works',
          );
        }, _RealHttpOverrides());
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  test(
    'simultaneous PIN submissions converge to reciprocal pairing',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final barrier = _TwoPartyBarrier();
        final securityA = _BarrierLanSecurityService(
          secureStorage: FakeSecureStorage(),
          barrier: barrier,
        );
        final securityB = _BarrierLanSecurityService(
          secureStorage: FakeSecureStorage(),
          barrier: barrier,
        );
        final transferA = LanTransferService(
          currentDeviceId: 'simultaneous-device-a',
          securityService: securityA,
          storageService: LanStorageService(),
        );
        final transferB = LanTransferService(
          currentDeviceId: 'simultaneous-device-b',
          securityService: securityB,
          storageService: LanStorageService(),
        );
        addTearDown(() async {
          await transferA.stopListening();
          await transferB.stopListening();
          await transferA.closeConnections();
          await transferB.closeConnections();
          transferA.dispose();
          transferB.dispose();
        });

        final portA = await transferA.startListening(port: 0);
        final portB = await transferB.startListening(port: 0);
        final deviceA = LanDevice(
          id: 'simultaneous-device-a',
          alias: 'Simultaneous Device A',
          ip: InternetAddress.loopbackIPv4.address,
          port: portA,
          deviceType: LanDeviceType.desktop,
          osName: 'windows',
          lastSeen: DateTime.now(),
        );
        final deviceB = LanDevice(
          id: 'simultaneous-device-b',
          alias: 'Simultaneous Device B',
          ip: InternetAddress.loopbackIPv4.address,
          port: portB,
          deviceType: LanDeviceType.mobile,
          osName: 'android',
          lastSeen: DateTime.now(),
        );
        final pinA = securityA.generate6DigitPin();
        final pinB = securityB.generate6DigitPin();

        final results = await Future.wait([
          transferA.sendHandshake(
            deviceB,
            pinB,
            deviceA.alias,
            isInitiator: true,
          ),
          transferB.sendHandshake(
            deviceA,
            pinA,
            deviceB.alias,
            isInitiator: false,
          ),
        ]);

        expect(results, hasLength(2));
        expect(results.every((result) => result.success), isTrue);
        expect(results.every((result) => !result.pendingRemote), isTrue);
        expect(await securityA.isDevicePaired(deviceB.id), isTrue);
        expect(await securityB.isDevicePaired(deviceA.id), isTrue);

        final incomingAtB = transferB.incomingMessageStream.firstWhere(
          (message) => message.id == 'simultaneous-a-to-b',
        );
        final sentToB = await transferA.sendMeta(
          deviceB,
          LanMessage(
            id: 'simultaneous-a-to-b',
            senderId: deviceA.id,
            senderAlias: deviceA.alias,
            receiverId: deviceB.id,
            payloadType: LanPayloadType.text,
            textContent: 'A to B authenticated',
            status: LanTransferStatus.transferring,
            createdAt: DateTime.now(),
            isIncoming: false,
          ),
        );
        expect(sentToB, isTrue);
        expect(
          (await incomingAtB.timeout(const Duration(seconds: 3))).textContent,
          'A to B authenticated',
        );

        final incomingAtA = transferA.incomingMessageStream.firstWhere(
          (message) => message.id == 'simultaneous-b-to-a',
        );
        final sentToA = await transferB.sendMeta(
          deviceA,
          LanMessage(
            id: 'simultaneous-b-to-a',
            senderId: deviceB.id,
            senderAlias: deviceB.alias,
            receiverId: deviceA.id,
            payloadType: LanPayloadType.text,
            textContent: 'B to A authenticated',
            status: LanTransferStatus.transferring,
            createdAt: DateTime.now(),
            isIncoming: false,
          ),
        );
        expect(sentToA, isTrue);
        expect(
          (await incomingAtA.timeout(const Duration(seconds: 3))).textContent,
          'B to A authenticated',
        );
      }, _RealHttpOverrides());
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'interrupted native upload reports failed and consumes its reservation',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final sandbox = await Directory.systemTemp.createTemp(
          'ssh_mobile_native_upload_',
        );
        final storageA = LanStorageService(
          sandboxDirectoryProvider: () async =>
              Directory('${sandbox.path}${Platform.pathSeparator}a'),
        );
        final storageB = LanStorageService(
          sandboxDirectoryProvider: () async =>
              Directory('${sandbox.path}${Platform.pathSeparator}b'),
        );
        final securityA = LanSecurityService(
          secureStorage: FakeSecureStorage(),
        );
        final securityB = LanSecurityService(
          secureStorage: FakeSecureStorage(),
        );
        final transferA = LanTransferService(
          currentDeviceId: 'upload-device-a',
          securityService: securityA,
          storageService: storageA,
        );
        final transferB = LanTransferService(
          currentDeviceId: 'upload-device-b',
          securityService: securityB,
          storageService: storageB,
        );
        addTearDown(() async {
          await transferA.stopListening();
          await transferB.stopListening();
          await transferA.closeConnections();
          await transferB.closeConnections();
          transferA.dispose();
          transferB.dispose();
          if (await sandbox.exists()) {
            await sandbox.delete(recursive: true);
          }
        });

        final portA = await transferA.startListening(port: 0);
        final portB = await transferB.startListening(port: 0);
        final deviceA = LanDevice(
          id: 'upload-device-a',
          alias: 'Upload Device A',
          ip: InternetAddress.loopbackIPv4.address,
          port: portA,
          deviceType: LanDeviceType.desktop,
          osName: 'windows',
          lastSeen: DateTime.now(),
        );
        final deviceB = LanDevice(
          id: 'upload-device-b',
          alias: 'Upload Device B',
          ip: InternetAddress.loopbackIPv4.address,
          port: portB,
          deviceType: LanDeviceType.mobile,
          osName: 'android',
          lastSeen: DateTime.now(),
        );

        final first = await transferA.sendHandshake(
          deviceB,
          securityB.generate6DigitPin(),
          deviceA.alias,
        );
        final second = await transferB.sendHandshake(
          deviceA,
          securityA.generate6DigitPin(),
          deviceB.alias,
          isInitiator: false,
        );
        expect(first.success, isTrue);
        expect(first.pendingRemote, isTrue);
        expect(second.success, isTrue);
        expect(second.pendingRemote, isFalse);
        await securityB.confirmDevicePairing(deviceA.id);

        const messageId = 'native-interrupted-upload';
        const fileName = 'partial.bin';
        final accepted = await transferA.sendMeta(
          deviceB,
          LanMessage(
            id: messageId,
            senderId: deviceA.id,
            senderAlias: deviceA.alias,
            receiverId: deviceB.id,
            payloadType: LanPayloadType.file,
            fileName: fileName,
            fileSize: 3,
            status: LanTransferStatus.transferring,
            createdAt: DateTime.now(),
            isIncoming: false,
          ),
        );
        expect(accepted, isTrue);

        final failedProgress = transferB.messageProgressStream
            .firstWhere(
              (message) =>
                  message.id == messageId &&
                  message.status == LanTransferStatus.failed,
            )
            .timeout(const Duration(seconds: 3));
        final token = await securityA.getOutboundAccessToken(deviceB.id);
        expect(token, isNotNull);

        final oversizedClient = HttpClient(
          context: SecurityContext(withTrustedRoots: false),
        )..badCertificateCallback = (_, _, _) => true;
        int? oversizedStatus;
        Object? oversizedError;
        try {
          final request = await oversizedClient.postUrl(
            Uri.parse('https://${deviceB.ip}:${deviceB.port}/api/lan/upload'),
          );
          request.headers.set('x-device-id', deviceA.id);
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
          request.headers.set('x-message-id', messageId);
          request.headers.set('x-file-name', Uri.encodeComponent(fileName));
          request.add(const [1, 2, 3, 4]);
          final response = await request.close();
          oversizedStatus = response.statusCode;
          await response.drain<void>();
        } on HttpException catch (error) {
          oversizedError = error;
        } finally {
          oversizedClient.close(force: true);
        }

        expect(
          oversizedStatus == HttpStatus.requestEntityTooLarge ||
              oversizedError is HttpException,
          isTrue,
        );
        final failedMessage = await failedProgress;
        expect(failedMessage.isIncoming, isTrue);
        expect(failedMessage.fileSize, 3);
        expect(failedMessage.bytesTransferred, greaterThan(3));
        expect(failedMessage.localPath, isNull);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        final receiverSandbox = await storageB.getSandboxDirectory();
        expect(await receiverSandbox.list().toList(), isEmpty);

        final retryClient = HttpClient(
          context: SecurityContext(withTrustedRoots: false),
        )..badCertificateCallback = (_, _, _) => true;
        try {
          final request = await retryClient.postUrl(
            Uri.parse('https://${deviceB.ip}:${deviceB.port}/api/lan/upload'),
          );
          request.headers.set('x-device-id', deviceA.id);
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
          request.headers.set('x-message-id', messageId);
          request.headers.set('x-file-name', Uri.encodeComponent(fileName));
          request.contentLength = 0;
          final response = await request.close();
          expect(response.statusCode, HttpStatus.forbidden);
          await response.drain<void>();
        } finally {
          retryClient.close(force: true);
        }

        expect(await receiverSandbox.list().toList(), isEmpty);
      }, _RealHttpOverrides());
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
