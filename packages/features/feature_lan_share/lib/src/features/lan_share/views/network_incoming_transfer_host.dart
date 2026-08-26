// 将类型化原生传入传输申请呈现给 Flutter UI 的 V2 宿主。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/lan_share_ports.dart';
import 'package:network_sdk/network_sdk.dart';
import '../services/lan_receiver_coordinator.dart';

/// UI state for the incoming transfer approval dialog.
enum IncomingApprovalUiState { idle, accepting, rejecting, retryableFailure }

bool _isRetryableNetworkError(NetworkErrorCode code) => switch (code) {
  NetworkErrorCode.ioError ||
  NetworkErrorCode.timeout ||
  NetworkErrorCode.quicError ||
  NetworkErrorCode.pathLost ||
  NetworkErrorCode.peerOffline ||
  NetworkErrorCode.noRoute => true,
  _ => false,
};

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
  final List<IncomingApprovalRequest> _pending = [];
  StreamSubscription<IncomingTransferOffer>? _nativeSubscription;
  bool _showingDialog = false;

  /// 订阅协调器的类型化传入申请流。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_nativeSubscription != null) return;
    final coordinator = context.read<LanReceiverCoordinator>();
    _nativeSubscription = coordinator.nativeIncomingTransferOffers.listen((
      offer,
    ) {
      _handleRequest(
        IncomingApprovalRequest(
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

  /// 将不重复的传入审批请求加入队列。
  void _handleRequest(IncomingApprovalRequest request) {
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

    if (!mounted) {
      _showingDialog = false;
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => IncomingApprovalDialog(request: request),
    );

    _showingDialog = false;
    if (mounted) unawaited(_showNext());
  }

  /// 拒绝在对话框显示前已过期的申请。
  Future<void> _rejectExpired(IncomingApprovalRequest request) async {
    final logger = context.read<LanShareLoggerPort>();
    try {
      final result = await request.reject();
      if (result is NetworkFailure<void>) {
        logger.warning(
          'Expired network offer rejection returned failure',
          details: result.error.toString(),
        );
      }
    } on Object catch (error, stackTrace) {
      logger.warning(
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

/// Dialog presenting one incoming transfer request with retry and error states.
class IncomingApprovalDialog extends StatefulWidget {
  const IncomingApprovalDialog({super.key, required this.request});

  final IncomingApprovalRequest request;

  @override
  State<IncomingApprovalDialog> createState() => _IncomingApprovalDialogState();
}

class _IncomingApprovalDialogState extends State<IncomingApprovalDialog> {
  IncomingApprovalUiState _state = IncomingApprovalUiState.idle;
  String? _errorMessage;
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    final expiresIn = widget.request.expiresAt.difference(DateTime.now());
    _expiryTimer = Timer(
      expiresIn.isNegative ? Duration.zero : expiresIn,
      _handleTimeout,
    );
  }

  void _handleTimeout() {
    if (!mounted) return;
    if (_state == IncomingApprovalUiState.accepting ||
        _state == IncomingApprovalUiState.rejecting) {
      return;
    }
    unawaited(_reject(isTimeout: true));
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  Future<void> _accept() async {
    if (_state == IncomingApprovalUiState.accepting ||
        _state == IncomingApprovalUiState.rejecting) {
      return;
    }
    setState(() {
      _state = IncomingApprovalUiState.accepting;
      _errorMessage = null;
    });

    final logger = context.read<LanShareLoggerPort>();
    try {
      final result = await widget.request.accept();
      if (!mounted) return;
      if (result is NetworkSuccess<void>) {
        Navigator.of(context).pop();
        return;
      }

      final failure = result as NetworkFailure<void>;
      if (_isRetryableNetworkError(failure.error.code)) {
        setState(() {
          _state = IncomingApprovalUiState.retryableFailure;
          _errorMessage = failure.error.message;
        });
      } else {
        final messenger = ScaffoldMessenger.of(context);
        final strings = context.read<AppSettings>().strings;
        Navigator.of(context).pop();
        _showTerminalFailureSnackBar(messenger, strings, failure.error);
      }
    } on Object catch (error, stackTrace) {
      logger.warning(
        'Incoming transfer approval failed',
        details: '$error\n$stackTrace',
      );
      if (mounted) {
        setState(() {
          _state = IncomingApprovalUiState.retryableFailure;
          _errorMessage = error.toString();
        });
      }
    }
  }

  Future<void> _reject({bool isTimeout = false}) async {
    if (_state == IncomingApprovalUiState.rejecting) return;
    setState(() {
      _state = IncomingApprovalUiState.rejecting;
    });

    final logger = context.read<LanShareLoggerPort>();
    try {
      final result = await widget.request.reject();
      if (result is NetworkFailure<void>) {
        logger.warning(
          'Incoming transfer rejection returned failure',
          details: result.error.toString(),
        );
      }
    } on Object catch (error, stackTrace) {
      logger.warning(
        'Incoming transfer rejection failed',
        details: '$error\n$stackTrace',
      );
    } finally {
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  void _showTerminalFailureSnackBar(
    ScaffoldMessengerState messenger,
    LanShareStrings strings,
    NetworkError error,
  ) {
    final message = switch (error.code) {
      NetworkErrorCode.resourceLimit =>
        strings.isEnglish
            ? 'Insufficient storage space for incoming transfer.'
            : '存储空间不足，无法接收文件。',
      NetworkErrorCode.authenticationFailed =>
        strings.isEnglish
            ? 'Transfer peer is not trusted or route unauthorized.'
            : '设备未通过信任校验或未授权传输路由。',
      _ =>
        strings.isEnglish
            ? 'Incoming transfer failed: ${error.message}'
            : '接收文件失败：${error.message}',
    };
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.watch<AppSettings>().strings;
    final theme = Theme.of(context);
    final inProgress =
        _state == IncomingApprovalUiState.accepting ||
        _state == IncomingApprovalUiState.rejecting;

    return AlertDialog(
      title: Text(strings.networkIncomingTransferTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.networkIncomingTransferDescription(
              widget.request.senderId,
              widget.request.fileName,
              _formatByteCount(widget.request.totalBytes),
            ),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
            ),
          ],
          if (inProgress) ...[
            const SizedBox(height: 12),
            const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: inProgress ? null : () => _reject(),
          child: Text(strings.reject),
        ),
        if (_state == IncomingApprovalUiState.retryableFailure)
          FilledButton(
            onPressed: inProgress ? null : _accept,
            child: Text(strings.isEnglish ? 'Retry' : '重试'),
          )
        else
          FilledButton(
            onPressed: inProgress ? null : _accept,
            child: Text(strings.accept),
          ),
      ],
    );
  }
}

/// 保存一个传入申请及其审批回调。
class IncomingApprovalRequest {
  /// 创建带过期时间的传入审批请求。
  const IncomingApprovalRequest({
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
  final Future<NetworkResult<void>> Function() accept;
  final Future<NetworkResult<void>> Function() reject;

  /// 此审批请求是否已过期。
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

String _formatByteCount(int bytes) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  double doubleBytes = bytes.toDouble();
  while (doubleBytes >= 1024 && i < suffixes.length - 1) {
    doubleBytes /= 1024;
    i++;
  }
  return '${doubleBytes.toStringAsFixed(1)} ${suffixes[i]}';
}
