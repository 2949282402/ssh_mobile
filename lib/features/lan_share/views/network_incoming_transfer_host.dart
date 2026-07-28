import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/app_log_service.dart';
import '../../../services/app_settings.dart';
import '../services/lan_receiver_coordinator.dart';
import '../../../services/network/transfer_transport.dart';

/// Presents one root-level approval dialog at a time for current-protocol
/// QUIC or Relay offers, independently of the selected application route.
class NetworkIncomingTransferHost extends StatefulWidget {
  const NetworkIncomingTransferHost({super.key, required this.child});

  final Widget child;

  @override
  State<NetworkIncomingTransferHost> createState() =>
      _NetworkIncomingTransferHostState();
}

class _NetworkIncomingTransferHostState
    extends State<NetworkIncomingTransferHost> {
  final List<_IncomingApproval> _pending = [];
  StreamSubscription<NativeIncomingTransferOffer>? _nativeSubscription;
  LanReceiverCoordinator? _coordinator;
  bool _showingDialog = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_nativeSubscription != null) return;
    final coordinator = context.read<LanReceiverCoordinator>();
    _coordinator = coordinator;
    _nativeSubscription = coordinator.nativeIncomingTransferOffers.listen((
      offer,
    ) {
      _handleRequest(
        _IncomingApproval(
          sessionId: offer.transferId,
          senderId: offer.peerId,
          fileName: offer.fileName,
          totalBytes: offer.fileSize,
          expiresAt: DateTime.now().add(const Duration(seconds: 25)),
          accept: () => coordinator.acceptNativeIncomingTransfer(offer),
          reject: () => coordinator.rejectNativeIncomingTransfer(offer),
        ),
      );
    });
  }

  void _handleRequest(_IncomingApproval request) {
    if (!mounted ||
        request.isExpired ||
        _pending.any((item) => item.sessionId == request.sessionId)) {
      return;
    }
    _pending.add(request);
    unawaited(_showNext());
  }

  Future<void> _showNext() async {
    if (!mounted || _showingDialog || _pending.isEmpty) return;
    _showingDialog = true;
    final request = _pending.removeAt(0);
    if (request.isExpired) {
      await _rejectExpired(request);
      _showingDialog = false;
      if (mounted) unawaited(_showNext());
      return;
    }
    var dialogVisible = true;
    final dialogFuture = showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final language = dialogContext.watch<AppSettings>().language;
        final strings = AppStrings(language);
        return AlertDialog(
          title: Text(strings.networkIncomingTransferTitle),
          content: Text(
            strings.networkIncomingTransferDescription(
              request.senderId,
              request.fileName,
              _formatByteCount(request.totalBytes),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(strings.reject),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(strings.accept),
            ),
          ],
        );
      },
    );
    final expiresIn = request.expiresAt.difference(DateTime.now());
    final expiryTimer = Timer(
      expiresIn.isNegative ? Duration.zero : expiresIn,
      () {
        if (dialogVisible && mounted) {
          unawaited(Navigator.of(context, rootNavigator: true).maybePop(false));
        }
      },
    );
    final accepted = await dialogFuture;
    dialogVisible = false;
    expiryTimer.cancel();

    if (_coordinator != null) {
      try {
        if (accepted == true && !request.isExpired) {
          await request.accept();
        } else {
          await request.reject();
        }
      } on Object catch (error, stackTrace) {
        AppLogService.instance.warning(
          'Network incoming approval failed',
          details: '$error\n$stackTrace',
        );
      }
    }
    _showingDialog = false;
    if (mounted) unawaited(_showNext());
  }

  Future<void> _rejectExpired(_IncomingApproval request) async {
    try {
      await request.reject();
    } on Object catch (error, stackTrace) {
      AppLogService.instance.warning(
        'Expired network offer rejection failed',
        details: '$error\n$stackTrace',
      );
    }
  }

  @override
  void dispose() {
    _nativeSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _IncomingApproval {
  const _IncomingApproval({
    required this.sessionId,
    required this.senderId,
    required this.fileName,
    required this.totalBytes,
    required this.expiresAt,
    required this.accept,
    required this.reject,
  });

  final String sessionId;
  final String senderId;
  final String fileName;
  final int totalBytes;
  final DateTime expiresAt;
  final Future<void> Function() accept;
  final Future<void> Function() reject;

  bool get isExpired => !DateTime.now().isBefore(expiresAt);
}

String _formatByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 1 : 2)} ${units[unit]}';
}
