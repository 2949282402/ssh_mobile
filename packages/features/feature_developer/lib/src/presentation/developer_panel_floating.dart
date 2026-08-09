import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/developer_ports.dart';
import 'developer_panel_screen.dart';
import 'developer_panel_viewmodel.dart';

/// 全局开发者面板悬浮层；只消费设置和 diagnostics 公共契约。
///
/// 当开发者模式和悬浮开关同时开启时显示可拖拽按钮。
///
/// 它挂在 App Shell 的 Navigator 上方，因此终端、SFTP、AI 等页面切换时
/// 仍能保持可见；ViewModel 生命周期由该 Host 独占。
class DeveloperPanelFloatingHost extends StatefulWidget {
  final Widget child;

  const DeveloperPanelFloatingHost({super.key, required this.child});

  @override
  State<DeveloperPanelFloatingHost> createState() =>
      _DeveloperPanelFloatingHostState();
}

class _DeveloperPanelFloatingHostState
    extends State<DeveloperPanelFloatingHost> {
  static const double _ballSize = 56;
  static const double _margin = 16;

  DeveloperPanelViewModel? _vm;
  bool _panelOpen = false;
  Offset? _ballOffset;
  Offset? _panelOffset;

  void _syncViewModel(bool enabled) {
    if (enabled && _vm == null) {
      _vm = DeveloperPanelViewModel(
        diagnostics: context.read<DeveloperDiagnosticsPort>(),
      )..start();
    } else if (!enabled && _vm != null) {
      _panelOpen = false;
      _panelOffset = null;
      _vm!.dispose();
      _vm = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 首次挂载时同步状态；运行时切换由 build 中的 select 触发。
    final settings = context.read<DeveloperSettingsPort>();
    _syncViewModel(settings.developerMode && settings.floatingPanelEnabled);
  }

  @override
  void dispose() {
    _vm?.dispose();
    _vm = null;
    super.dispose();
  }

  Offset _defaultBallOffset(Size size, EdgeInsets insets) => Offset(
    size.width - _ballSize - _margin,
    size.height - insets.bottom - _ballSize - _margin,
  );

  Offset _clampBall(Offset offset, Size size, EdgeInsets insets) {
    final minX = _margin;
    final maxX = size.width - _ballSize - _margin;
    final minY = insets.top + _margin;
    final maxY = size.height - insets.bottom - _ballSize - _margin;
    return Offset(offset.dx.clamp(minX, maxX), offset.dy.clamp(minY, maxY));
  }

  Offset _clampPanel(Offset offset, Size size, EdgeInsets insets, Size panel) {
    final minX = _margin;
    final maxX = size.width - panel.width - _margin;
    final minY = insets.top + _margin;
    final maxY = size.height - insets.bottom - panel.height - _margin;
    return Offset(offset.dx.clamp(minX, maxX), offset.dy.clamp(minY, maxY));
  }

  @override
  Widget build(BuildContext context) {
    final enabled = context.select<DeveloperSettingsPort, bool>(
      (settings) => settings.developerMode && settings.floatingPanelEnabled,
    );
    // select 在设置变化时重新执行，确保运行时切换能创建/释放 ViewModel。
    // 该操作幂等，不主动安排额外重建。
    _syncViewModel(enabled);

    return Stack(
      children: [
        widget.child,
        if (enabled && _vm != null)
          LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              final insets = MediaQuery.of(context).padding;
              final ballPos = _clampBall(
                _ballOffset ?? _defaultBallOffset(size, insets),
                size,
                insets,
              );

              final panelWidth = (size.width - _margin * 2)
                  .clamp(300.0, 400.0)
                  .toDouble();
              final panelHeight = (size.height * 0.6)
                  .clamp(320.0, size.height - insets.top - insets.bottom - 32)
                  .toDouble();
              final panelSize = Size(panelWidth, panelHeight);
              final panelPos = _clampPanel(
                _panelOffset ??
                    Offset(
                      size.width - panelWidth - _margin,
                      insets.top + _margin,
                    ),
                size,
                insets,
                panelSize,
              );

              return Stack(
                children: [
                  if (_panelOpen)
                    Positioned(
                      left: panelPos.dx,
                      top: panelPos.dy,
                      width: panelSize.width,
                      height: panelSize.height,
                      child: _buildPanel(context, panelSize),
                    ),
                  Positioned(
                    left: ballPos.dx,
                    top: ballPos.dy,
                    width: _ballSize,
                    height: _ballSize,
                    child: _buildBall(context, size, insets),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _buildBall(BuildContext context, Size size, EdgeInsets insets) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => setState(() => _panelOpen = !_panelOpen),
      onPanUpdate: (details) {
        final newOffset = _clampBall(
          (_ballOffset ?? _defaultBallOffset(size, insets)) + details.delta,
          size,
          insets,
        );
        if (newOffset != _ballOffset) {
          setState(() => _ballOffset = newOffset);
        }
      },
      child: Material(
        elevation: 6,
        shape: const CircleBorder(),
        color: colorScheme.primaryContainer,
        child: Icon(
          Icons.bug_report_outlined,
          size: 26,
          color: colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }

  Widget _buildPanel(BuildContext context, Size panelSize) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      color: colorScheme.surface,
      child: Column(
        children: [
          _PanelDragHandle(
            onPanUpdate: (delta) {
              final size = MediaQuery.of(context).size;
              final insets = MediaQuery.of(context).padding;
              final newOffset = _clampPanel(
                (_panelOffset ??
                        Offset(
                          size.width - panelSize.width - 16,
                          insets.top + 16,
                        )) +
                    delta,
                size,
                insets,
                panelSize,
              );
              if (newOffset != _panelOffset) {
                setState(() => _panelOffset = newOffset);
              }
            },
            onClose: () => setState(() => _panelOpen = false),
          ),
          Expanded(
            child: ChangeNotifierProvider<DeveloperPanelViewModel>.value(
              value: _vm!,
              child: DeveloperPanelContent(vm: _vm!),
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelDragHandle extends StatelessWidget {
  final void Function(Offset delta) onPanUpdate;
  final VoidCallback onClose;

  const _PanelDragHandle({required this.onPanUpdate, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onPanUpdate: (details) => onPanUpdate(details.delta),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Row(
          children: [
            const Icon(Icons.drag_handle_rounded, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Developer Panel',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
