// 将类型化原生传入传输申请呈现给 Flutter UI 的 v1 宿主。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/app_log_service.dart';
import '../../../services/app_settings.dart';
import '../../../services/network/network_models.dart';
import '../services/lan_receiver_coordinator.dart';

/// Presents one root-level approval dialog at a time for current-protocol
/// QUIC or Relay offers, independently of the selected application route.
class NetworkIncomingTransferHost extends StatefulWidget {
  /// 在 [child] 外创建根宿主。
  const NetworkIncomingTransferHost({super.key, required this.child});

  final Widget child;

  /// 创建根级传入申请状态。
  @override
  State<NetworkIncomingTransferHost> createState() =>
      _NetworkIncomingTransferHostState();
}

class _NetworkIncomingTransferHostState
    extends State<NetworkIncomingTransferHost> {
  final List<_IncomingApproval> _pending = [];
  StreamSubscription<IncomingTransferOfferEvent>? _nativeSubscription;
  LanReceiverCoordinator? _coordinator;
  bool _showingDialog = false;

  /// 订阅协调器的类型化传入申请流。
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
          accept: () async {
            await coordinator.acceptNativeIncomingTransfer(offer);
          },
          reject: () async {
            await coordinator.rejectNativeIncomingTransfer(offer);
          },
        ),
      );
    });
  }

  /// 将不重复的传入审批请求加入队列。
  void _handleRequest(_IncomingApproval request) {
    if (!mounted ||
        request.isExpired ||
        _pending.any((item) => item.sessionId == request.sessionId)) {
      return;
    }
    _pending.add(request);
    unawaited(_showNext());
  }

  /// 显示下一个审批对话框并应用用户决定。
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

  /// 拒绝在对话框显示前已过期的申请。
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

  /// 取消协调器申请订阅。
  @override
  void dispose() {
    _nativeSubscription?.cancel();
    super.dispose();
  }

  /// 构建被包装的应用子树。
  @override
  Widget build(BuildContext context) => widget.child;
}

/// 保存一个传入申请及其审批回调。
class _IncomingApproval {
  /// 创建带过期时间的传入审批请求。
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

  /// 此审批请求是否已过期。
  bool get isExpired => !DateTime.now().isBefore(expiresAt);
}

/// 为传入传输对话框格式化字节数量。
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
