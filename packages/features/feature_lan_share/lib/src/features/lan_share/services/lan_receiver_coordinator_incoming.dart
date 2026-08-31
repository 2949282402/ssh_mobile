part of 'lan_receiver_coordinator.dart';

/// Incoming native transfer policy and history coordination.
extension LanReceiverCoordinatorIncoming on LanReceiverCoordinator {
  bool _matchesIncomingOffer(
    LanTransferRecord record,
    IncomingTransferOffer offer,
  ) {
    return record.isIncoming &&
        record.senderId == offer.peerId &&
        record.receiverId == appSettings.lanDeviceId &&
        record.fileName == offer.fileName &&
        record.fileSize == offer.fileSize &&
        record.routeType == offer.routeType.name;
  }

  /// 校验设备配对后接受一个原生传入传输。
  Future<NetworkResult<void>> acceptNativeIncomingTransfer(
    IncomingTransferOffer offer,
  ) async {
    await ensureInitialized();
    await ensureViewModel();
    final nativeTransfer = _nativeTransferCoordinator;
    if (nativeTransfer == null) {
      return _networkFailure(
        NetworkErrorCode.noRoute,
        'native network runtime is unavailable',
        NetworkOperation.respondToIncoming,
      );
    }
    final policyResult = await nativeTransfer.getPeerPolicy(offer.peerId);
    if (policyResult is NetworkFailure<LanPeerPolicySnapshot>) {
      return NetworkFailure<void>(policyResult.error);
    }
    final policy = (policyResult as NetworkSuccess<LanPeerPolicySnapshot>).data;
    if (!policy.isTrusted ||
        policy.runtimeBlocked ||
        policy.revoked ||
        !isIncomingRouteAuthorized(
          policy.trust!.authorization,
          offer.routeType,
        )) {
      final rejectResult = await nativeTransfer.reject(offer);
      if (rejectResult is NetworkFailure<void>) {
        return rejectResult;
      }
      return _networkFailure(
        NetworkErrorCode.authenticationFailed,
        'Incoming transfer peer is no longer trusted or route is unauthorized.',
        NetworkOperation.respondToIncoming,
        peerId: offer.peerId,
      );
    }

    // Persist the connecting record before native acceptance.
    try {
      final existing = await historyRepository.dao.getRecord(offer.transferId);
      if (existing == null) {
        await historyRepository.dao.insertRecord(
          LanTransferRecordsCompanion(
            id: Value(offer.transferId),
            senderId: Value(offer.peerId),
            senderAlias: Value(offer.peerId),
            receiverId: Value(appSettings.lanDeviceId),
            payloadType: Value(
              classifyAttachment(fileName: offer.fileName).toJson(),
            ),
            fileName: Value(offer.fileName),
            fileSize: Value(offer.fileSize),
            status: Value(LanTransferStatus.connecting.toJson()),
            createdAt: Value(DateTime.now().millisecondsSinceEpoch),
            isIncoming: const Value(true),
            isRecalled: const Value(false),
            routeType: Value(offer.routeType.name),
            bytesTotal: Value(offer.fileSize),
            bytesTransferred: const Value(0),
          ),
        );
      } else {
        if (!_matchesIncomingOffer(existing, offer)) {
          await nativeTransfer.reject(offer);
          return _networkFailure(
            NetworkErrorCode.identityConflict,
            'Incoming transfer ID conflicts with existing history record from another peer or metadata mismatch.',
            NetworkOperation.respondToIncoming,
            peerId: offer.peerId,
          );
        }

        if (existing.status != LanTransferStatus.connecting.toJson() &&
            existing.status != LanTransferStatus.pending.toJson()) {
          await nativeTransfer.reject(offer);
          return _networkFailure(
            NetworkErrorCode.invalidState,
            'Incoming transfer ID already has a terminal status: ${existing.status}',
            NetworkOperation.respondToIncoming,
            peerId: offer.peerId,
          );
        }
      }
    } catch (error, stackTrace) {
      logger.warning(
        'Failed to persist incoming transfer history before native accept',
        details: '$error\n$stackTrace',
      );
      return _networkFailure(
        NetworkErrorCode.ioError,
        'Failed to persist incoming transfer history: $error',
        NetworkOperation.respondToIncoming,
        peerId: offer.peerId,
      );
    }

    final nativeResult = await nativeTransfer.accept(offer);
    if (nativeResult is NetworkFailure<void>) {
      if (!isRetryableNetworkError(nativeResult.error.code)) {
        try {
          await historyRepository.dao.updateRecordStatus(
            offer.transferId,
            LanTransferStatus.failed.toJson(),
            failureReason: nativeResult.error.code.name,
          );
        } catch (error, stackTrace) {
          logger.warning(
            'Failed to update transfer status to failed on terminal failure',
            details: '$error\n$stackTrace',
          );
        }
      }
      return nativeResult;
    }

    return nativeResult;
  }

  /// 拒绝一个原生传入传输申请。
  Future<NetworkResult<void>> rejectNativeIncomingTransfer(
    IncomingTransferOffer offer,
  ) async {
    await ensureInitialized();
    final nativeTransfer = _nativeTransferCoordinator;
    if (nativeTransfer == null) {
      return _networkFailure(
        NetworkErrorCode.noRoute,
        'native network runtime is unavailable',
        NetworkOperation.respondToIncoming,
      );
    }
    try {
      final record = await historyRepository.dao.getRecord(offer.transferId);
      if (record != null &&
          _matchesIncomingOffer(record, offer) &&
          (record.status == LanTransferStatus.connecting.toJson() ||
              record.status == LanTransferStatus.pending.toJson())) {
        await historyRepository.dao.deleteRecord(offer.transferId);
      }
    } catch (error, stackTrace) {
      logger.warning(
        'Failed to clean up pending history on reject: ${offer.transferId}',
        details: '$error\n$stackTrace',
      );
    }
    return nativeTransfer.reject(offer);
  }

  NetworkFailure<void> _networkFailure(
    NetworkErrorCode code,
    String message,
    NetworkOperation operation, {
    String? peerId,
  }) => NetworkFailure(
    NetworkError(
      code: code,
      message: message,
      operation: operation,
      peerId: peerId,
    ),
  );
}
